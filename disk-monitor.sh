#!/usr/bin/env bash
# disk-monitor.sh - Speicherplatz überwachen und bei Zustandswechsel alarmieren
# Modi:  (ohne Argument) = interaktives Menü
#        --check         = einmaliger Durchlauf (für cron)
#        --status        = Belegung auf stdout
#        --uninstall     = Deinstallation
#
# Bewusst ohne 'set -e': der Runner sammelt Fehler und meldet sie am Ende.
set -uo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/disk-monitor.conf"
CRON_FILE=/etc/cron.d/disk-monitor

# ---------------------------------------------------------------------------
# Konfiguration laden / Defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=60          # Prüfabstand in Minuten
WARN_PCT=85
CRIT_PCT=95
INODE_WARN=90
MIN_FREE_GB=0            # 0 = Prüfung aus
EXCLUDE=""               # Mountpoints, space-getrennt
RETENTION_DAYS=90
TOP_DIRS=1               # größte Verzeichnisse in den Alert schreiben
ALERT_MODE="change"      # change | always
ALERT_MAIL=""
ALERT_WEBHOOK=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
RESULTS="$DATA_DIR/results/usage.csv"
ALERT_LOG="$LOG_DIR/alerts.log"
RUN_LOG="$LOG_DIR/disk.log"

pause() { read -rp "Weiter mit Enter..." _; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" ]]; }

make_dirs() { mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$RESULTS")"; }

save_conf() {
    cat > "$CONF" <<EOF
# disk-monitor Konfiguration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
WARN_PCT=${WARN_PCT}
CRIT_PCT=${CRIT_PCT}
INODE_WARN=${INODE_WARN}
MIN_FREE_GB=${MIN_FREE_GB}
EXCLUDE="${EXCLUDE}"
RETENTION_DAYS=${RETENTION_DAYS}
TOP_DIRS=${TOP_DIRS}
ALERT_MODE="${ALERT_MODE}"
ALERT_MAIL="${ALERT_MAIL}"
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
EOF
    chmod 644 "$CONF"
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# disk-monitor - Speicherplatzüberwachung
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Dateisysteme einsammeln
# ---------------------------------------------------------------------------
# Pseudo-Dateisysteme interessieren nicht: tmpfs läuft nie "voll" im Sinne
# eines Problems, und squashfs (snap) ist per Definition zu 100 % belegt.
PSEUDO='^(tmpfs|devtmpfs|squashfs|overlay|iso9660|efivarfs|proc|sysfs|cgroup2?|ramfs|autofs|fuse[.]snapfuse|nsfs|tracefs|debugfs|configfs|securityfs|pstore|bpf|hugetlbfs|mqueue|devpts)$'

excluded() {
    local m=$1 e
    for e in $EXCLUDE; do [[ "$m" == "$e" ]] && return 0; done
    return 1
}

# Gibt je Zeile aus:  mountpoint|belegt%|inode%|frei_gb|gesamt_gb
#
# 'df --output' statt der klassischen Spalten: so steht der Mountpoint sicher am
# Zeilenende (er darf Leerzeichen enthalten und würde sonst alle Felder
# verschieben), und die Inode-Belegung kommt aus demselben Aufruf. Das Gerät
# steht bewusst nicht mit drin - auch das kann Leerzeichen enthalten und
# gebraucht wird es nicht.
collect() {
    df -B1K --output=fstype,pcent,ipcent,avail,size,target 2>/dev/null \
    | awk -v p="$PSEUDO" '
        NR > 1 && $1 !~ p {
            pct = $2; sub(/%/, "", pct); if (pct == "-" || pct == "") pct = 0
            ip  = $3; sub(/%/, "", ip);  if (ip  == "-" || ip  == "") ip  = 0
            mnt = $6; for (i = 7; i <= NF; i++) mnt = mnt " " $i
            printf "%s|%s|%s|%.1f|%.1f\n", mnt, pct, ip, $4/1048576, $5/1048576
        }' \
    | while IFS='|' read -r mnt rest; do
        excluded "$mnt" && continue
        printf '%s|%s\n' "$mnt" "$rest"
      done
}

slug() { echo "${1//\//_}" | sed 's/^_$/root/; s/^_//'; }

# ---------------------------------------------------------------------------
# Bewertung
# ---------------------------------------------------------------------------
# Setzt die globalen STATE und REASON.
evaluate() {
    local mnt=$1 pct=$2 ipct=$3 free=$4
    STATE=ok
    REASON=""

    if (( pct >= CRIT_PCT )); then
        STATE=crit; REASON="Belegung ${pct}% >= ${CRIT_PCT}%"
    elif (( pct >= WARN_PCT )); then
        STATE=warn; REASON="Belegung ${pct}% >= ${WARN_PCT}%"
    fi

    # Inodes können voll sein, während Platz frei ist - dann geht auch nichts
    # mehr, und df -h zeigt nichts davon.
    if (( ipct >= INODE_WARN )); then
        [[ "$STATE" == "ok" ]] && STATE=warn
        REASON="${REASON:+$REASON; }Inodes ${ipct}% >= ${INODE_WARN}%"
    fi

    if (( MIN_FREE_GB > 0 )); then
        if awk -v f="$free" -v m="$MIN_FREE_GB" 'BEGIN{exit !(f < m)}'; then
            [[ "$STATE" == "ok" ]] && STATE=warn
            REASON="${REASON:+$REASON; }nur noch ${free} GB frei (< ${MIN_FREE_GB} GB)"
        fi
    fi
}

# Lineare Hochrechnung aus der ältesten und der jüngsten Messung.
# Grob, aber genau die Frage, die man bei einer Warnung hat: reicht es noch?
forecast() {
    local mnt=$1
    [[ -f "$RESULTS" ]] || return 0
    awk -F, -v m="$mnt" '
        $2 == m {
            if (first == "") { first = $1; fp = $3 }
            last = $1; lp = $3
        }
        END {
            if (first == "" || first == last) exit
            cmd = "date -d \"" first "\" +%s"; cmd | getline t0; close(cmd)
            cmd = "date -d \"" last  "\" +%s"; cmd | getline t1; close(cmd)
            days = (t1 - t0) / 86400
            if (days < 1) exit
            rate = (lp - fp) / days
            if (rate <= 0.01) { printf "stabil oder rückläufig (%.2f %%/Tag)", rate; exit }
            printf "+%.2f %%/Tag, voll in ca. %d Tagen", rate, int((100 - lp) / rate)
        }' "$RESULTS"
}

top_dirs() {
    local mnt=$1
    echo "  Größte Verzeichnisse unter ${mnt} (max. 2 Ebenen, ohne andere Dateisysteme):"
    du -x -h --max-depth=2 "$mnt" 2>/dev/null | sort -h | tail -n 12 | sed 's/^/    /'
}

notify() {
    local subject=$1 body=$2
    echo "$(date '+%F %T') ${subject}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":$(printf '%s' "$subject" | sed 's/"/\\"/g; s/^/"/; s/$/"/')}" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_MAIL" ]]; then
        if command -v mail &>/dev/null; then
            printf '%s\n' "$body" | mail -s "$subject" "$ALERT_MAIL" \
                || echo "$(date '+%F %T') !!! Mailversand fehlgeschlagen" >> "$ALERT_LOG"
        else
            echo "$(date '+%F %T') !!! 'mail' fehlt - kein Versand" >> "$ALERT_LOG"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Prüflauf
# ---------------------------------------------------------------------------
run_check() {
    local verbose=${1:-}
    is_setup || { echo "Nicht eingerichtet. Erst Setup ausführen." >&2; return 1; }
    make_dirs

    local now host mnt pct ipct free total prev
    now=$(date '+%F %T')
    host=$(hostname -f 2>/dev/null || hostname)

    [[ -f "$RESULTS" ]] || echo "timestamp,mount,pct,inode_pct,free_gb" > "$RESULTS"

    local -a changes=() worst=()
    local body="" rc=0

    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue

        evaluate "$mnt" "$pct" "$ipct" "$free"
        echo "${now},${mnt},${pct},${ipct},${free}" >> "$RESULTS"

        local sf="$STATE_DIR/$(slug "$mnt").state"
        prev="-"
        [[ -f "$sf" ]] && prev=$(cut -d'|' -f1 "$sf")
        echo "${STATE}|${now}|${pct}|${ipct}" > "$sf"

        [[ "$STATE" != "ok" ]] && rc=1

        if [[ -n "$verbose" ]]; then
            printf '%-24s %5s%%  Inodes %4s%%  frei %8s GB   %-5s %s\n' \
                "$mnt" "$pct" "$ipct" "$free" "$STATE" "$REASON"
        fi

        # Erstaufnahme im Normalzustand ist kein Vorfall.
        if [[ "$prev" == "-" && "$STATE" == "ok" ]]; then continue; fi

        if [[ "$prev" != "$STATE" || "$ALERT_MODE" == "always" ]]; then
            if [[ "$STATE" == "ok" ]]; then
                changes+=("ENTWARNUNG ${mnt}: wieder unter der Schwelle (${pct}%)")
            else
                changes+=("${STATE^^} ${mnt}: ${REASON}")
                worst+=("$mnt")
            fi
        fi
    done < <(collect)

    if (( ${#changes[@]} > 0 )); then
        body="Speicherplatz auf ${host}"$'\n'"Stand: ${now}"$'\n'
        body+=$'\n'"Änderungen:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Belegung:"$'\n'
        body+=$(df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/  /')

        local m fc
        for m in "${worst[@]}"; do
            fc=$(forecast "$m")
            body+=$'\n\n'"${m}"
            [[ -n "$fc" ]] && body+=$'\n'"  Trend: ${fc}"
            if (( TOP_DIRS == 1 )); then
                body+=$'\n'"$(top_dirs "$m")"
            fi
        done

        local subject
        if (( ${#worst[@]} > 0 )); then
            subject="[disk] ${host}: ${changes[0]}"
        else
            subject="[disk] ${host}: Entwarnung"
        fi
        (( ${#changes[@]} > 1 )) && subject+=" (+$(( ${#changes[@]} - 1 )) weitere)"

        notify "$subject" "$body"
        [[ -n "$verbose" ]] && { echo; echo "$body"; } || true
    elif [[ -n "$verbose" ]]; then
        echo
        echo "Keine Zustandsänderung - es würde keine Mail verschickt."
    fi

    {
        echo "$(date '+%F %T') Lauf beendet, $(printf '%s' "${#changes[@]}") Änderung(en)"
    } >> "$RUN_LOG"
    tail -n 2000 "$RUN_LOG" > "$RUN_LOG.tmp" 2>/dev/null && mv "$RUN_LOG.tmp" "$RUN_LOG"

    prune_old
    return $rc
}

prune_old() {
    [[ -f "$RESULTS" ]] || return 0
    local cutoff
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$RESULTS" > "$RESULTS.tmp" \
        && mv "$RESULTS.tmp" "$RESULTS"
}

# ---------------------------------------------------------------------------
# Anzeige
# ---------------------------------------------------------------------------
show_usage() {
    printf '%-24s %7s %8s %10s %10s  %-5s %s\n' \
        "MOUNTPOINT" "BELEGT" "INODES" "FREI GB" "GESAMT GB" "STAND" "TREND"
    printf '%-24s %7s %8s %10s %10s  %-5s %s\n' \
        "------------------------" "-------" "--------" "----------" "----------" "-----" "-----"
    local mnt pct ipct free total
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        evaluate "$mnt" "$pct" "$ipct" "$free"
        printf '%-24s %6s%% %7s%% %10s %10s  %-5s %s\n' \
            "$mnt" "$pct" "$ipct" "$free" "$total" "$STATE" "$(forecast "$mnt")"
    done < <(collect)

    if [[ -n "$EXCLUDE" ]]; then
        echo
        echo "Ausgeschlossen: $EXCLUDE"
    fi
}

show_alerts() {
    echo "--- Letzte Zustandswechsel ---"
    tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(keine)"
    pause
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------
configure() {
    echo ">>> Einstellungen disk-monitor"
    echo

    local D I W C IN MF R T
    read -rp "Datenverzeichnis [${DATA_DIR}]: " D; DATA_DIR=${D:-$DATA_DIR}
    read -rp "Prüfabstand in Minuten [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}

    echo
    read -rp "Warnung ab Belegung in % [${WARN_PCT}]: " W; WARN_PCT=${W:-$WARN_PCT}
    read -rp "Kritisch ab Belegung in % [${CRIT_PCT}]: " C; CRIT_PCT=${C:-$CRIT_PCT}
    read -rp "Warnung ab Inode-Belegung in % [${INODE_WARN}]: " IN; INODE_WARN=${IN:-$INODE_WARN}
    read -rp "Zusätzlich warnen unter X GB frei (0 = aus) [${MIN_FREE_GB}]: " MF
    MIN_FREE_GB=${MF:-$MIN_FREE_GB}

    if (( CRIT_PCT <= WARN_PCT )); then
        echo "!!! Kritisch muss über Warnung liegen - wird auf $((WARN_PCT + 5)) gesetzt."
        CRIT_PCT=$((WARN_PCT + 5))
    fi

    echo
    echo "Alarmierung:"
    echo "  1) nur bei Zustandswechsel (empfohlen)"
    echo "  2) bei jedem Lauf, solange etwas über der Schwelle liegt"
    local A; read -rp "Auswahl [1]: " A
    [[ "${A:-1}" == "2" ]] && ALERT_MODE="always" || ALERT_MODE="change"

    read -rp "E-Mail-Adresse für Alerts (leer = keine) [${ALERT_MAIL}]: " M
    ALERT_MAIL=${M:-$ALERT_MAIL}
    read -rp "Webhook-URL (leer = keiner) [${ALERT_WEBHOOK}]: " WH
    ALERT_WEBHOOK=${WH:-$ALERT_WEBHOOK}

    echo
    confirm "Größte Verzeichnisse in den Alert schreiben (du, kann dauern)?" \
        "$([[ $TOP_DIRS -eq 1 ]] && echo J || echo N)" && TOP_DIRS=1 || TOP_DIRS=0

    read -rp "Messwerte aufbewahren (Tage) [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    RESULTS="$DATA_DIR/results/usage.csv"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/disk.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Prüfung: alle ${INTERVAL_MIN} min   ($CRON_FILE)"
    echo "Schwellen: warn ${WARN_PCT}%, kritisch ${CRIT_PCT}%, Inodes ${INODE_WARN}%"
    echo ">>> Eingerichtet."
    pause
}

edit_excludes() {
    while true; do
        clear
        echo "=== Ausgeschlossene Mountpoints ==="
        if [[ -z "$EXCLUDE" ]]; then echo "(keine)"; else printf '  %s\n' $EXCLUDE; fi
        echo
        echo "Aktuell überwacht:"
        collect | cut -d'|' -f1 | sed 's/^/  /'
        echo
        echo "1) Mountpoint ausschließen"
        echo "2) Ausschluss aufheben"
        echo "3) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) read -rp "Mountpoint: " M
               [[ -n "$M" ]] && EXCLUDE="${EXCLUDE:+$EXCLUDE }$M" && save_conf ;;
            2) read -rp "Mountpoint: " M
               EXCLUDE=$(echo "$EXCLUDE" | tr ' ' '\n' | grep -vxF "$M" | tr '\n' ' ')
               EXCLUDE=${EXCLUDE% }
               save_conf ;;
            3) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation disk-monitor"
    echo
    echo "Folgendes wird entfernt:"
    [[ -f "$CRON_FILE" ]] && echo "  - Cron-Eintrag $CRON_FILE (alle ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - Konfiguration $CONF"
    [[ -d "$DATA_DIR" ]]  && echo "  - Datenverzeichnis $DATA_DIR (Messreihe, Zustand, Alert-Log)   [Rückfrage]"
    echo
    echo "Es wurden keine Pakete installiert, es bleibt nichts zurück."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup disk-monitor "$CONF" "$DATA_DIR" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Messreihe und Zustand in $DATA_DIR ebenfalls löschen?"; then
        rm -rf "$DATA_DIR"
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
        echo " Speicherplatz-Überwachung"
        echo "==========================================="
        if is_setup; then
            echo "Schwellen: warn ${WARN_PCT}%  kritisch ${CRIT_PCT}%  Inodes ${INODE_WARN}%"
            echo "Cron:      $([[ -f "$CRON_FILE" ]] && echo "alle ${INTERVAL_MIN} min" || echo '!!! nicht installiert')"
            echo "Alerts an: ${ALERT_MAIL:-(keine Mail)}${ALERT_WEBHOOK:+ + Webhook}"
            echo
            show_usage
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Einrichten / Einstellungen bearbeiten"
        echo "2) Jetzt prüfen"
        echo "3) Ausschlüsse verwalten"
        echo "4) Alerts anzeigen"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || configure; echo; run_check verbose; echo; pause ;;
            3) is_setup || configure; edit_excludes ;;
            4) show_alerts ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --status)    show_usage ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Verwendung: $0 [--check|--status|--uninstall]"; exit 1 ;;
esac
