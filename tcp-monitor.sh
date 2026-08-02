#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tcp-monitor.sh - kontinuierliches TCP-Erreichbarkeits-Monitoring
# Modi:  (ohne Argument) = interaktives Menü
#        --check         = einmaliger Durchlauf aller aktiven Ziele (für cron)
#        --status        = Kurzstatus auf stdout
set -euo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/tcp-monitor.conf"
CRON_FILE=/etc/cron.d/tcp-monitor

# ---------------------------------------------------------------------------
# Konfiguration laden / Defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5
RETENTION_DAYS=30
DEFAULT_TIMEOUT=5
ALERT_WEBHOOK=""
ALERT_MAIL=""

[[ -f "$CONF" ]] && . "$CONF"

TARGETS_DIR="$DATA_DIR/targets.d"
RESULTS_DIR="$DATA_DIR/results"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
ALERT_LOG="$LOG_DIR/alerts.log"

pause() { read -rp "Weiter mit Enter..." _; }

# confirm "Frage" [J]   -> Default J statt N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

# make_backup <name> <pfad>...   -> <root|HOME>/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p dir
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then dir=/root; else dir="$HOME"; fi
    mkdir -p "$dir" 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="${dir}/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" && -d "$TARGETS_DIR" ]]; }

save_conf() {
    cat > "$CONF" <<EOF
# tcp-monitor Konfiguration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
RETENTION_DAYS=${RETENTION_DAYS}
DEFAULT_TIMEOUT=${DEFAULT_TIMEOUT}
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
ALERT_MAIL="${ALERT_MAIL}"
EOF
}

make_dirs() {
    mkdir -p "$TARGETS_DIR" "$RESULTS_DIR" "$STATE_DIR" "$LOG_DIR"
}

write_cron() {
    if [[ $EUID -ne 0 ]]; then
        echo "Cron-Eintrag benötigt root. Manuell eintragen:"
        echo "*/${INTERVAL_MIN} * * * * root ${SELF} --check"
        return
    fi
    cat > "$CRON_FILE" <<EOF
# tcp-monitor - kontinuierliche TCP-Prüfung
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Ersteinrichtung
# ---------------------------------------------------------------------------
setup() {
    echo ">>> Ersteinrichtung tcp-monitor"
    echo

    read -rp "Datenverzeichnis [${DATA_DIR}]: " D
    DATA_DIR=${D:-$DATA_DIR}

    read -rp "Prüfintervall in Minuten [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    read -rp "Standard-Timeout pro Verbindung in Sekunden [${DEFAULT_TIMEOUT}]: " T
    DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}

    read -rp "Aufbewahrung der Messdaten in Tagen [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    read -rp "Webhook-URL bei Statuswechsel (leer = keine): " ALERT_WEBHOOK
    read -rp "E-Mail-Adresse bei Statuswechsel (leer = keine, benötigt 'mail'): " ALERT_MAIL

    TARGETS_DIR="$DATA_DIR/targets.d"
    RESULTS_DIR="$DATA_DIR/results"
    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    ALERT_LOG="$LOG_DIR/alerts.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Datenverzeichnis: $DATA_DIR"
    echo "Cron:             */${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Einrichtung abgeschlossen."
    pause
}

edit_settings() {
    echo "--- Aktuelle Einstellungen ---"
    echo "Datenverzeichnis:  $DATA_DIR"
    echo "Intervall:         ${INTERVAL_MIN} min"
    echo "Timeout (default): ${DEFAULT_TIMEOUT}s"
    echo "Aufbewahrung:      ${RETENTION_DAYS} Tage"
    echo "Webhook:           ${ALERT_WEBHOOK:-(keiner)}"
    echo "E-Mail:            ${ALERT_MAIL:-(keine)}"
    echo

    read -rp "Intervall in Minuten [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}
    read -rp "Standard-Timeout [${DEFAULT_TIMEOUT}]: " T; DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}
    read -rp "Aufbewahrung Tage [${RETENTION_DAYS}]: " R; RETENTION_DAYS=${R:-$RETENTION_DAYS}
    read -rp "Webhook-URL [${ALERT_WEBHOOK}]: " W; ALERT_WEBHOOK=${W:-$ALERT_WEBHOOK}
    read -rp "E-Mail [${ALERT_MAIL}]: " M; ALERT_MAIL=${M:-$ALERT_MAIL}

    save_conf
    write_cron
    echo "Gespeichert."
    pause
}

# ---------------------------------------------------------------------------
# Ziele (CRUD)
# ---------------------------------------------------------------------------
target_file() { echo "$TARGETS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

list_targets() {
    if [[ ! -d "$TARGETS_DIR" ]] || ! ls "$TARGETS_DIR"/*.conf &>/dev/null; then
        echo "(keine Ziele angelegt)"
        return
    fi
    printf "%-20s %-28s %-6s %-8s %s\n" "NAME" "ZIEL" "AKTIV" "STATUS" "LETZTE PRÜFUNG"
    printf "%-20s %-28s %-6s %-8s %s\n" "--------------------" "----------------------------" "------" "--------" "--------------------"
    for f in "$TARGETS_DIR"/*.conf; do
        ( . "$f"
          local st ts
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              st=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
              ts=$(cut -d'|' -f2 "$STATE_DIR/${NAME}.state")
          else
              st="-"; ts="-"
          fi
          printf "%-20s %-28s %-6s %-8s %s\n" \
              "$NAME" "${HOST}:${PORT}" \
              "$([[ "$ENABLED" == "1" ]] && echo ja || echo nein)" \
              "$st" "$ts"
        )
    done
}

create_target() {
    echo "--- Vorhandene Ziele ---"; list_targets; echo
    read -rp "Name: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(target_file "$NAME")" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Name: " NAME
    done

    read -rp "Host/IP: " HOST
    while [[ -z "$HOST" ]]; do read -rp "  -> Pflichtfeld: " HOST; done

    read -rp "Port: " PORT
    while [[ ! "$PORT" =~ ^[0-9]+$ ]]; do read -rp "  -> Zahl erwartet: " PORT; done

    read -rp "Timeout in Sekunden [${DEFAULT_TIMEOUT}]: " TMO; TMO=${TMO:-$DEFAULT_TIMEOUT}
    read -rp "Notiz (optional): " NOTE

    cat > "$(target_file "$NAME")" <<EOF
NAME="${NAME}"
HOST="${HOST}"
PORT="${PORT}"
TIMEOUT="${TMO}"
ENABLED="1"
NOTE="${NOTE}"
EOF

    echo
    echo "Sofort-Test:"
    check_one "$(target_file "$NAME")" verbose
    pause
}

edit_target() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name zum Bearbeiten: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    . "$f"
    read -rp "Host [${HOST}]: " H; H=${H:-$HOST}
    read -rp "Port [${PORT}]: " P; P=${P:-$PORT}
    read -rp "Timeout [${TIMEOUT}]: " T; T=${T:-$TIMEOUT}
    read -rp "Aktiv (1/0) [${ENABLED}]: " E; E=${E:-$ENABLED}
    read -rp "Notiz [${NOTE}]: " O; O=${O:-$NOTE}

    cat > "$f" <<EOF
NAME="${NAME}"
HOST="${H}"
PORT="${P}"
TIMEOUT="${T}"
ENABLED="${E}"
NOTE="${O}"
EOF
    echo "Aktualisiert."
    pause
}

delete_target() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name zum Löschen: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    read -rp "'$N' wirklich löschen? [j/N]: " C
    if [[ "$C" =~ ^[Jj]$ ]]; then
        rm -f "$f" "$STATE_DIR/${N}.state"
        read -rp "Auch Messdaten (${RESULTS_DIR}/${N}.csv) löschen? [j/N]: " D
        [[ "$D" =~ ^[Jj]$ ]] && rm -f "$RESULTS_DIR/${N}.csv"
        echo "Gelöscht."
    else
        echo "Abgebrochen."
    fi
    pause
}

target_menu() {
    while true; do
        clear
        echo "=== Ziele verwalten ==="
        list_targets
        echo
        echo "1) Ziel erstellen"
        echo "2) Ziel bearbeiten"
        echo "3) Ziel löschen"
        echo "4) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) create_target ;;
            2) edit_target ;;
            3) delete_target ;;
            4) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prüflogik
# ---------------------------------------------------------------------------
notify() {
    local name=$1 old=$2 new=$3 detail=$4
    local msg="[tcp-monitor] ${name}: ${old} -> ${new} (${detail})"
    echo "$(date '+%F %T') ${msg}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":\"${msg}\"}" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_MAIL" ]] && command -v mail &>/dev/null; then
        echo "$msg" | mail -s "tcp-monitor: ${name} ${new}" "$ALERT_MAIL" || true
    fi
}

check_one() {
    local f=$1 verbose=${2:-}
    # shellcheck disable=SC1090
    ( . "$f"

      [[ "$ENABLED" == "1" || -n "$verbose" ]] || exit 0

      local start end ms status detail
      start=$(date +%s%N)
      if timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
          end=$(date +%s%N)
          ms=$(( (end - start) / 1000000 ))
          status="UP"; detail="${ms}ms"
      else
          end=$(date +%s%N)
          ms=$(( (end - start) / 1000000 ))
          status="DOWN"; detail="timeout/refused nach ${ms}ms"
      fi

      local now; now=$(date '+%F %T')
      mkdir -p "$RESULTS_DIR" "$STATE_DIR"
      [[ -f "$RESULTS_DIR/${NAME}.csv" ]] || echo "timestamp,status,latency_ms" > "$RESULTS_DIR/${NAME}.csv"
      echo "${now},${status},${ms}" >> "$RESULTS_DIR/${NAME}.csv"

      local prev="-"
      [[ -f "$STATE_DIR/${NAME}.state" ]] && prev=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
      echo "${status}|${now}|${ms}" > "$STATE_DIR/${NAME}.state"

      if [[ "$prev" != "-" && "$prev" != "$status" ]]; then
          notify "$NAME" "$prev" "$status" "$detail"
      fi

      [[ -n "$verbose" ]] && printf "%-20s %-24s %-6s %s\n" "$NAME" "${HOST}:${PORT}" "$status" "$detail"
      exit 0
    )
}

prune_old() {
    local cutoff
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    for f in "$RESULTS_DIR"/*.csv; do
        [[ -e "$f" ]] || continue
        awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
}

run_check() {
    is_setup || { echo "Nicht eingerichtet. Erst Setup ausführen." >&2; exit 1; }
    make_dirs
    for f in "$TARGETS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        check_one "$f" "${1:-}"
    done
    prune_old
}

show_results() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name (leer = alle Alerts anzeigen): " N
    if [[ -z "$N" ]]; then
        echo
        echo "--- Letzte Statuswechsel ---"
        tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(keine)"
        pause
        return
    fi

    local csv="$RESULTS_DIR/${N}.csv"
    [[ -f "$csv" ]] || { echo "Keine Messdaten."; pause; return; }

    local total up
    total=$(( $(wc -l < "$csv") - 1 ))
    up=$(grep -c ',UP,' "$csv" || true)
    echo
    echo "Messungen: $total   davon UP: $up"
    if (( total > 0 )); then
        awk -F, -v t="$total" 'BEGIN{OFS=""} END{}' /dev/null
        echo "Verfügbarkeit: $(awk -v u="$up" -v t="$total" 'BEGIN{printf "%.2f%%", (u/t)*100}')"
        echo "Ø Latenz (UP): $(awk -F, '$2=="UP"{s+=$3;n++} END{if(n)printf "%.1f ms", s/n; else print "-"}' "$csv")"
        echo "Max Latenz:    $(awk -F, '$2=="UP"{if($3>m)m=$3} END{if(m)printf "%d ms", m; else print "-"}' "$csv")"
    fi
    echo
    echo "--- Letzte 20 Messungen ---"
    tail -n 20 "$csv"
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation tcp-monitor"
    echo

    local n=0
    [[ -d "$TARGETS_DIR" ]] && n=$(find "$TARGETS_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "Folgendes wird entfernt:"
    [[ -f "$CRON_FILE" ]] && echo "  - Cron-Eintrag $CRON_FILE (alle ${INTERVAL_MIN} min)" || true
    [[ -f "$CONF" ]]      && echo "  - Konfiguration $CONF" || true
    [[ -d "$DATA_DIR" ]]  && echo "  - Datenverzeichnis $DATA_DIR (${n} Ziele, Messdaten, Alert-Log)   [Rückfrage]" || true
    echo
    echo "Es wurden keine Pakete installiert, es bleibt nichts zurück."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup tcp-monitor "$CONF" "$DATA_DIR" || { pause; return; }

    if [[ -f "$CRON_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo "!!! Kein root - Cron-Eintrag bitte manuell entfernen:"
            echo "    rm -f $CRON_FILE"
        else
            rm -f "$CRON_FILE"
            echo "Cron-Eintrag entfernt."
        fi
    fi

    rm -f "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Ziele und Messdaten in $DATA_DIR ebenfalls löschen?"; then
        rm -rf "$DATA_DIR"
        echo "Datenverzeichnis gelöscht."
    fi

    echo
    echo "Entfernt."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " TCP-Monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Daten:  $DATA_DIR"
            echo "Cron:   $([[ -f "$CRON_FILE" ]] && echo "alle ${INTERVAL_MIN} min" || echo "nicht installiert")"
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        is_setup && { list_targets; echo; }
        echo "1) Ziele verwalten"
        echo "2) Jetzt alle Ziele prüfen"
        echo "3) Ergebnisse / Statistik"
        echo "4) Einstellungen (Intervall, Alerts, Aufbewahrung)"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) is_setup || setup; target_menu ;;
            2) is_setup || setup; echo; run_check verbose; echo; pause ;;
            3) is_setup || setup; show_results ;;
            4) is_setup || setup; edit_settings ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --status)    is_setup && list_targets ;;
    --uninstall) uninstall ;;
    "")          is_setup || setup; main_menu ;;
    *)           echo "Verwendung: $0 [--check|--status|--uninstall|--version]"; exit 1 ;;
esac
