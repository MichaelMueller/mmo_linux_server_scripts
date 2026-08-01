#!/usr/bin/env bash
# auto-update.sh - automatische apt-Updates per Cron, mit Mail-Report
# Modi:  (ohne Argument) = interaktives Menü
#        --run           = einmaliger Update-Lauf (für cron)
#        --status        = Kurzstatus auf stdout
#        --uninstall     = Deinstallation
#
# Bewusst ohne 'set -e': der Runner sammelt Fehler ein und meldet sie am Ende,
# statt mitten im Lauf abzubrechen und den Report zu verschlucken.
set -uo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/auto-update.conf"
CRON_FILE=/etc/cron.d/auto-update

# ---------------------------------------------------------------------------
# Konfiguration laden / Defaults
# ---------------------------------------------------------------------------
SCHEDULE="daily"        # daily | weekly
WEEKDAY=0               # 0=Sonntag ... 6=Samstag (nur bei weekly)
HOUR=4
MINUTE=17
MODE="security"         # security | all
AUTOREMOVE=1
AUTO_REBOOT=0           # Neustart zulassen, wenn einer nötig wird
MAIL_TO=""
MAIL_ON_INSTALL=1       # Mail, wenn Pakete aktualisiert wurden
MAIL_ON_ERROR=1         # Mail, wenn etwas schiefging
MAIL_ON_NOOP=0          # Mail auch, wenn es nichts zu tun gab
LOG_FILE="$DIR/var/auto-update.log"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# Konfigurationen aus älteren Ständen kannten statt der drei Schalter ein
# einzelnes MAIL_WHEN. Einmalig übersetzen, damit niemand neu einrichten muss.
if [[ -n "${MAIL_WHEN:-}" ]]; then
    case "$MAIL_WHEN" in
        always)  MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=1 ;;
        errors)  MAIL_ON_INSTALL=0; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
        *)       MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
    esac
fi

DAYS=(Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag)

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

# make_backup <name> <pfad>...   -> /root/<name>-uninstall-<ts>.tar.gz
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

save_conf() {
    cat > "$CONF" <<EOF
# auto-update Konfiguration
SCHEDULE="${SCHEDULE}"
WEEKDAY=${WEEKDAY}
HOUR=${HOUR}
MINUTE=${MINUTE}
MODE="${MODE}"
AUTOREMOVE=${AUTOREMOVE}
AUTO_REBOOT=${AUTO_REBOOT}
MAIL_TO="${MAIL_TO}"
MAIL_ON_INSTALL=${MAIL_ON_INSTALL}
MAIL_ON_ERROR=${MAIL_ON_ERROR}
MAIL_ON_NOOP=${MAIL_ON_NOOP}
LOG_FILE="${LOG_FILE}"
EOF
    chmod 644 "$CONF"
}

cron_spec() {
    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "${MINUTE} ${HOUR} * * ${WEEKDAY}"
    else
        echo "${MINUTE} ${HOUR} * * *"
    fi
}

schedule_text() {
    local t
    t=$(printf '%02d:%02d' "$HOUR" "$MINUTE")
    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "wöchentlich, ${DAYS[$WEEKDAY]} um ${t}"
    else
        echo "täglich um ${t}"
    fi
}

mode_text() {
    [[ "$MODE" == "all" ]] && echo "alle Pakete" || echo "nur Sicherheitsupdates"
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# auto-update - automatische apt-Updates
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$(cron_spec) root ${SELF} --run >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------
configure() {
    echo "--- Zeitplan ---"
    echo "  1) täglich"
    echo "  2) wöchentlich"
    local S; read -rp "Auswahl [$([[ "$SCHEDULE" == "weekly" ]] && echo 2 || echo 1)]: " S
    case "${S:-}" in
        1) SCHEDULE="daily" ;;
        2) SCHEDULE="weekly" ;;
    esac

    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "  0=So 1=Mo 2=Di 3=Mi 4=Do 5=Fr 6=Sa"
        local W; read -rp "Wochentag [${WEEKDAY}]: " W; W=${W:-$WEEKDAY}
        [[ "$W" =~ ^[0-6]$ ]] && WEEKDAY=$W
    fi

    local T cur
    cur=$(printf '%02d:%02d' "$HOUR" "$MINUTE")
    read -rp "Uhrzeit (HH:MM) [${cur}]: " T; T=${T:-$cur}
    while [[ ! "$T" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        read -rp "  -> Format HH:MM: " T
    done
    HOUR=$((10#${T%%:*}))
    MINUTE=$((10#${T##*:}))

    echo
    echo "--- Umfang ---"
    echo "  1) nur Sicherheitsupdates  (Quelle *-security)"
    echo "  2) alle Pakete             (apt dist-upgrade)"
    local M; read -rp "Auswahl [$([[ "$MODE" == "all" ]] && echo 2 || echo 1)]: " M
    case "${M:-}" in
        1) MODE="security" ;;
        2) MODE="all" ;;
    esac

    echo
    confirm "Nicht mehr benötigte Pakete entfernen (apt autoremove)?" "$([[ $AUTOREMOVE -eq 1 ]] && echo J || echo N)" \
        && AUTOREMOVE=1 || AUTOREMOVE=0

    echo
    echo "--- Neustart ---"
    echo "Nach Kernel- oder libc-Updates ist ein Neustart nötig; apt hinterlässt"
    echo "dann /var/run/reboot-required. Ist der Neustart nicht zugelassen, wird er"
    echo "nur gemeldet - der Server bleibt dann bis zum nächsten Handanlegen im"
    echo "alten Kernel."
    confirm "Neustart zulassen?" "$([[ $AUTO_REBOOT -eq 1 ]] && echo J || echo N)" \
        && AUTO_REBOOT=1 || AUTO_REBOOT=0

    echo
    echo "--- Report ---"
    local R; read -rp "E-Mail-Empfänger (leer = keine Mail) [${MAIL_TO}]: " R
    MAIL_TO=${R:-$MAIL_TO}

    if [[ -n "$MAIL_TO" ]]; then
        echo
        confirm "Mail, wenn Pakete installiert wurden?" \
            "$([[ $MAIL_ON_INSTALL -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_INSTALL=1 || MAIL_ON_INSTALL=0
        confirm "Mail, wenn ein Fehler auftrat?" \
            "$([[ $MAIL_ON_ERROR -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_ERROR=1 || MAIL_ON_ERROR=0
        confirm "Mail auch, wenn es nichts zu tun gab?" \
            "$([[ $MAIL_ON_NOOP -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_NOOP=1 || MAIL_ON_NOOP=0

        if (( MAIL_ON_INSTALL + MAIL_ON_ERROR + MAIL_ON_NOOP == 0 )); then
            echo
            echo "Alles abgewählt - es wird also nie gemailt, nur ins Log geschrieben."
        fi
        if ! command -v mail &>/dev/null; then
            echo
            echo "Hinweis: 'mail' ist nicht installiert - der Report landet vorerst nur"
            echo "im Log. Der SMTP-Mailer (mail-setup.sh) richtet das ein."
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    save_conf
    write_cron

    echo
    echo "Zeitplan: $(schedule_text)"
    echo "Umfang:   $(mode_text)"
    echo "Cron:     $CRON_FILE"
    echo "Log:      $LOG_FILE"
    echo ">>> Einrichtung abgeschlossen."
    pause
}

# ---------------------------------------------------------------------------
# Update-Lauf
# ---------------------------------------------------------------------------
# Sicherheitsupdates werden über den Suite-Namen erkannt (bookworm-security,
# jammy-security ...). Eigene Repos ohne dieses Namensschema fallen damit in
# den Modus "alle Pakete".
upgradable_packages() {
    if [[ "$MODE" == "security" ]]; then
        apt list --upgradable 2>/dev/null | awk -F/ '/^[a-z0-9]/ && /-security/ {print $1}'
    else
        apt list --upgradable 2>/dev/null | awk -F/ '/^[a-z0-9]/ {print $1}'
    fi
}

show_pending() {
    echo ">>> Paketlisten werden aktualisiert..."
    apt-get update -qq >/dev/null 2>&1
    echo
    echo "--- Ausstehende Updates (${1:-$(mode_text)}) ---"
    local -a pkgs=()
    mapfile -t pkgs < <(upgradable_packages)
    if (( ${#pkgs[@]} == 0 )); then
        echo "(keine)"
    else
        printf '  %s\n' "${pkgs[@]}"
        echo
        echo "Summe: ${#pkgs[@]} Paket(e)"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        echo
        echo "!!! Ein Neustart steht aus (/var/run/reboot-required)."
    fi
}

run_update() {
    local verbose=${1:-}
    is_setup || { echo "Nicht eingerichtet. Erst Setup ausführen." >&2; return 1; }

    mkdir -p "$(dirname "$LOG_FILE")"

    local tmp rc=0 changed=0 host
    tmp=$(mktemp)
    host=$(hostname -f 2>/dev/null || hostname)

    {
        echo "auto-update auf ${host}"
        echo "Start:  $(date '+%F %T')"
        echo "Umfang: $(mode_text)"
        echo "----------------------------------------"
    } > "$tmp"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq >>"$tmp" 2>&1; then
        echo "!!! 'apt-get update' fehlgeschlagen." >> "$tmp"
        rc=1
    fi

    local -a pkgs=()
    mapfile -t pkgs < <(upgradable_packages)

    if (( ${#pkgs[@]} == 0 )); then
        echo "Keine ausstehenden Updates." >> "$tmp"
    else
        {
            echo "Zu aktualisieren (${#pkgs[@]}):"
            printf '  %s\n' "${pkgs[@]}"
            echo
        } >> "$tmp"

        local -a apt_cmd=(apt-get -y
            -o Dpkg::Options::=--force-confdef
            -o Dpkg::Options::=--force-confold)
        if [[ "$MODE" == "all" ]]; then
            apt_cmd+=(dist-upgrade)
        else
            apt_cmd+=(install --only-upgrade "${pkgs[@]}")
        fi

        if "${apt_cmd[@]}" >>"$tmp" 2>&1; then
            changed=1
        else
            echo "!!! Aktualisierung fehlgeschlagen." >> "$tmp"
            rc=1
        fi
    fi

    if (( AUTOREMOVE == 1 )); then
        echo "--- autoremove ---" >> "$tmp"
        apt-get -y autoremove >>"$tmp" 2>&1 || { echo "!!! autoremove fehlgeschlagen." >> "$tmp"; rc=1; }
    fi

    local reboot_needed=0
    if [[ -f /var/run/reboot-required ]]; then
        reboot_needed=1
        echo >> "$tmp"
        if (( AUTO_REBOOT == 1 )); then
            echo "Neustart erforderlich - der Server startet in 1 Minute neu." >> "$tmp"
        else
            echo "!!! Neustart erforderlich (/var/run/reboot-required) - bitte manuell." >> "$tmp"
        fi
    fi

    echo "----------------------------------------" >> "$tmp"
    echo "Ende: $(date '+%F %T')   Status: $( ((rc==0)) && echo ok || echo FEHLER)" >> "$tmp"

    cat "$tmp" >> "$LOG_FILE"
    # Log begrenzen, damit es nicht unbegrenzt wächst
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"

    local subject
    if (( rc != 0 )); then
        subject="[FEHLER] auto-update ${host}"
    elif (( changed == 1 )); then
        subject="auto-update ${host}: ${#pkgs[@]} Paket(e) aktualisiert"
    else
        subject="auto-update ${host}: keine Updates"
    fi

    local do_mail=0
    (( rc != 0     && MAIL_ON_ERROR   == 1 )) && do_mail=1
    (( changed == 1 && MAIL_ON_INSTALL == 1 )) && do_mail=1
    (( changed == 0 && rc == 0 && MAIL_ON_NOOP == 1 )) && do_mail=1

    if (( do_mail == 1 )) && [[ -n "$MAIL_TO" ]]; then
        if command -v mail &>/dev/null; then
            mail -s "$subject" "$MAIL_TO" < "$tmp" \
                || echo "$(date '+%F %T') !!! Mailversand an ${MAIL_TO} fehlgeschlagen" >> "$LOG_FILE"
        else
            echo "$(date '+%F %T') !!! 'mail' nicht vorhanden - kein Versand" >> "$LOG_FILE"
        fi
    fi

    [[ -n "$verbose" ]] && cat "$tmp"
    rm -f "$tmp"

    if (( reboot_needed == 1 && AUTO_REBOOT == 1 )); then
        shutdown -r +1 "auto-update: Neustart nach Paketaktualisierung" >/dev/null 2>&1 || reboot
    fi

    return $rc
}

show_log() {
    [[ -f "$LOG_FILE" ]] || { echo "Kein Log vorhanden."; pause; return; }
    tail -n 60 "$LOG_FILE"
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation auto-update"
    echo
    echo "Folgendes wird entfernt:"
    [[ -f "$CRON_FILE" ]] && echo "  - Cron-Eintrag $CRON_FILE ($(schedule_text))"
    [[ -f "$CONF" ]]      && echo "  - Konfiguration $CONF"
    [[ -f "$LOG_FILE" ]]  && echo "  - Log $LOG_FILE                              [Rückfrage]"
    echo
    echo "Bereits installierte Paketaktualisierungen bleiben natürlich bestehen;"
    echo "es werden künftig nur keine neuen mehr automatisch eingespielt."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup auto-update "$CONF" "$LOG_FILE" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -f "$LOG_FILE" ]] && confirm "Log $LOG_FILE ebenfalls löschen?"; then
        rm -f "$LOG_FILE"
    fi
    rmdir "$(dirname "$LOG_FILE")" 2>/dev/null || true

    echo
    echo "Entfernt. Der Server bekommt jetzt keine automatischen Updates mehr."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Automatische Updates (apt)"
        echo "==========================================="
        if is_setup; then
            echo "Zeitplan:  $(schedule_text)"
            echo "Umfang:    $(mode_text)"
            echo "Cron:      $([[ -f "$CRON_FILE" ]] && echo "aktiv" || echo "!!! nicht installiert")"
            echo "Neustart:  $( ((AUTO_REBOOT==1)) && echo "zugelassen" || echo "nur melden")"
            if [[ -n "$MAIL_TO" ]]; then
                local w=""
                (( MAIL_ON_INSTALL == 1 )) && w+="Installation, "
                (( MAIL_ON_ERROR   == 1 )) && w+="Fehler, "
                (( MAIL_ON_NOOP    == 1 )) && w+="jeder Lauf, "
                w=${w%, }
                echo "Report an: ${MAIL_TO}  (bei: ${w:-nie})"
            else
                echo "Report an: (keine Mail)"
            fi
            [[ -f /var/run/reboot-required ]] && echo "!!! Ein Neustart steht aus."
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Einrichten / Einstellungen bearbeiten"
        echo "2) Jetzt Updates einspielen"
        echo "3) Ausstehende Updates anzeigen"
        echo "4) Log anzeigen"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || configure; echo; run_update verbose; echo; pause ;;
            3) is_setup || configure; show_pending; pause ;;
            4) show_log ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --run)       run_update ;;
    --status)    is_setup && { echo "auto-update: $(schedule_text), $(mode_text)"; } ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Verwendung: $0 [--run|--status|--uninstall]"; exit 1 ;;
esac
