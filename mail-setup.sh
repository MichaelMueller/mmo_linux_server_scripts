#!/usr/bin/env bash
# mail-setup.sh - SMTP-Versand einrichten (msmtp als sendmail-Ersatz)
# Kein Entity-Management, nur Parameter-Konfiguration.
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

MSMTPRC=/etc/msmtprc
ALIASES=/etc/aliases
LOGFILE=/var/log/msmtp.log

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

is_setup() { [[ -f "$MSMTPRC" ]] && grep -q '^account ' "$MSMTPRC"; }

get_val() { grep -m1 "^${1} " "$MSMTPRC" 2>/dev/null | awk '{print $2}' || true; }

install_pkgs() {
    if ! command -v msmtp &>/dev/null; then
        echo ">>> Installiere msmtp, msmtp-mta, bsd-mailx..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y msmtp msmtp-mta bsd-mailx >/dev/null
    fi
    if ! command -v mail &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt install -y bsd-mailx >/dev/null
    fi
}

configure() {
    install_pkgs

    local cur_host cur_port cur_user cur_from cur_tls cur_starttls cur_rcpt
    if is_setup; then
        cur_host=$(get_val host)
        cur_port=$(get_val port)
        cur_user=$(get_val user)
        cur_from=$(get_val from)
        cur_tls=$(get_val tls)
        cur_starttls=$(get_val tls_starttls)
        cur_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || true)
    fi

    echo "--- SMTP-Parameter ---"
    read -rp "SMTP-Server [${cur_host:-}]: " SMTP_HOST
    SMTP_HOST=${SMTP_HOST:-${cur_host:-}}
    while [[ -z "$SMTP_HOST" ]]; do read -rp "  -> Pflichtfeld: " SMTP_HOST; done

    echo
    echo "Verschlüsselung:"
    echo "  1) STARTTLS  (Port 587, üblich)"
    echo "  2) TLS/SSL   (Port 465, implizit)"
    echo "  3) unverschlüsselt (Port 25, nur im internen Netz)"
    read -rp "Auswahl [1]: " ENC; ENC=${ENC:-1}

    local DEF_PORT TLS_ON STARTTLS_ON
    case "$ENC" in
        2) DEF_PORT=465; TLS_ON=on;  STARTTLS_ON=off ;;
        3) DEF_PORT=25;  TLS_ON=off; STARTTLS_ON=off ;;
        *) DEF_PORT=587; TLS_ON=on;  STARTTLS_ON=on  ;;
    esac

    read -rp "Port [${cur_port:-$DEF_PORT}]: " SMTP_PORT
    SMTP_PORT=${SMTP_PORT:-${cur_port:-$DEF_PORT}}

    read -rp "Authentifizierung nötig? [J/n]: " NEEDAUTH
    NEEDAUTH=${NEEDAUTH:-J}

    local SMTP_USER="" SMTP_PASS=""
    if [[ "$NEEDAUTH" =~ ^[Jj]$ ]]; then
        read -rp "Benutzername [${cur_user:-}]: " SMTP_USER
        SMTP_USER=${SMTP_USER:-${cur_user:-}}
        while [[ -z "$SMTP_USER" ]]; do read -rp "  -> Pflichtfeld: " SMTP_USER; done

        read -rsp "Passwort (leer = bestehendes behalten): " SMTP_PASS; echo
        if [[ -z "$SMTP_PASS" ]] && is_setup; then
            SMTP_PASS=$(grep -m1 '^password ' "$MSMTPRC" | cut -d' ' -f2- || true)
        fi
        while [[ -z "$SMTP_PASS" ]]; do
            read -rsp "  -> Pflichtfeld: " SMTP_PASS; echo
        done
    fi

    read -rp "Absenderadresse (From) [${cur_from:-}]: " MAIL_FROM
    MAIL_FROM=${MAIL_FROM:-${cur_from:-}}
    while [[ -z "$MAIL_FROM" ]]; do read -rp "  -> Pflichtfeld: " MAIL_FROM; done

    read -rp "Standard-Empfänger für System-/root-Mails [${cur_rcpt:-}]: " ROOT_RCPT
    ROOT_RCPT=${ROOT_RCPT:-${cur_rcpt:-}}

    read -rp "Zertifikat des Servers prüfen? [J/n]: " CERTCHECK
    CERTCHECK=${CERTCHECK:-J}

    umask 077
    {
        echo "# msmtp - erzeugt von mail-setup.sh am $(date '+%F %T')"
        echo "defaults"
        echo "auth           $([[ "$NEEDAUTH" =~ ^[Jj]$ ]] && echo on || echo off)"
        echo "tls            ${TLS_ON}"
        echo "tls_starttls   ${STARTTLS_ON}"
        if [[ "$CERTCHECK" =~ ^[Jj]$ ]]; then
            echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
        else
            echo "tls_certcheck  off"
        fi
        echo "logfile        ${LOGFILE}"
        echo "timeout        20"
        echo
        echo "account        default"
        echo "host           ${SMTP_HOST}"
        echo "port           ${SMTP_PORT}"
        echo "from           ${MAIL_FROM}"
        if [[ "$NEEDAUTH" =~ ^[Jj]$ ]]; then
            echo "user           ${SMTP_USER}"
            echo "password       ${SMTP_PASS}"
        fi
    } > "$MSMTPRC"

    chmod 600 "$MSMTPRC"
    chown root:root "$MSMTPRC"
    touch "$LOGFILE" && chmod 600 "$LOGFILE"

    if [[ -n "$ROOT_RCPT" ]]; then
        touch "$ALIASES"
        if grep -q '^root:' "$ALIASES"; then
            sed -i "s|^root:.*|root: ${ROOT_RCPT}|" "$ALIASES"
        else
            echo "root: ${ROOT_RCPT}" >> "$ALIASES"
        fi
        command -v newaliases &>/dev/null && newaliases 2>/dev/null || true
    fi

    echo
    echo "Konfiguration geschrieben nach $MSMTPRC (chmod 600)."
    echo "Achtung: das Passwort liegt dort im Klartext, lesbar nur für root."
    echo

    read -rp "Jetzt Testmail senden? [J/n]: " T
    T=${T:-J}
    [[ "$T" =~ ^[Jj]$ ]] && send_test || pause
}

send_test() {
    is_setup || { echo "Noch nicht eingerichtet."; pause; return; }

    local from default_rcpt
    from=$(get_val from)
    default_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || echo "$from")

    read -rp "Empfänger [${default_rcpt}]: " RCPT
    RCPT=${RCPT:-$default_rcpt}
    while [[ -z "$RCPT" ]]; do read -rp "  -> Pflichtfeld: " RCPT; done

    echo ">>> Sende Testmail an $RCPT ..."
    if printf 'Subject: Testmail von %s\nFrom: %s\nTo: %s\n\nSMTP-Versand funktioniert.\nHost: %s\nZeit: %s\n' \
        "$(hostname -f 2>/dev/null || hostname)" "$from" "$RCPT" "$(hostname)" "$(date '+%F %T')" \
        | msmtp --read-envelope-from -- "$RCPT" 2>&1; then
        echo ">>> Erfolgreich übergeben."
    else
        echo "!!! Fehlgeschlagen. Letzte Logzeilen:"
        tail -n 10 "$LOGFILE" 2>/dev/null || true
    fi
    pause
}

show_config() {
    is_setup || { echo "Nicht eingerichtet."; pause; return; }
    echo "--- $MSMTPRC (Passwort maskiert) ---"
    sed 's/^password .*/password       ********/' "$MSMTPRC"
    echo
    echo "--- root-Alias ---"
    grep '^root:' "$ALIASES" 2>/dev/null || echo "(nicht gesetzt)"
    echo
    echo "--- sendmail-Binary ---"
    ls -l /usr/sbin/sendmail 2>/dev/null || echo "(nicht vorhanden)"
    pause
}

show_log() {
    [[ -f "$LOGFILE" ]] || { echo "Kein Log vorhanden."; pause; return; }
    tail -n 40 "$LOGFILE"
    pause
}

uninstall() {
    echo ">>> Deinstallation SMTP-Mailer"
    echo

    local cur_rcpt
    cur_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || true)

    echo "Folgendes wird entfernt:"
    [[ -f "$MSMTPRC" ]]  && echo "  - Konfiguration $MSMTPRC (inkl. SMTP-Passwort)" || true
    [[ -n "$cur_rcpt" ]] && echo "  - root-Alias in $ALIASES  (root: $cur_rcpt)   [Rückfrage]" || true
    [[ -f "$LOGFILE" ]]  && echo "  - Versand-Log $LOGFILE                        [Rückfrage]" || true
    echo
    echo "Die Pakete bleiben installiert. Manuell entfernen:"
    echo "    apt purge msmtp msmtp-mta bsd-mailx"
    echo "  (entfernt auch /usr/sbin/sendmail - Cron- und Systemmails fallen dann still aus)"
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup mail-setup "$MSMTPRC" "$ALIASES" "$LOGFILE" || { pause; return; }

    rm -f "$MSMTPRC"

    if [[ -n "$cur_rcpt" ]] && confirm "root-Alias ($cur_rcpt) aus $ALIASES entfernen?" J; then
        sed -i '/^root:/d' "$ALIASES"
        command -v newaliases &>/dev/null && newaliases 2>/dev/null || true
    fi

    if [[ -f "$LOGFILE" ]] && confirm "Versand-Log $LOGFILE löschen?"; then
        rm -f "$LOGFILE"
    fi

    echo
    echo "Entfernt. Ohne $MSMTPRC schlägt der Versand fehl - Dienste, die 'mail'"
    echo "benutzen (tcp-monitor, auto-update), schreiben dann nur noch ins Log."
    pause
}

main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " SMTP-Mailer (msmtp)"
        echo "==========================================="
        if is_setup; then
            echo "Status:   eingerichtet"
            echo "Server:   $(get_val host):$(get_val port)"
            echo "Absender: $(get_val from)"
            echo "Empfänger (root-Alias): $(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || echo '-')"
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Einrichten / Parameter bearbeiten"
        echo "2) Testmail senden"
        echo "3) Konfiguration anzeigen"
        echo "4) Versand-Log anzeigen"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) configure ;;
            2) send_test ;;
            3) show_config ;;
            4) show_log ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --test)      send_test ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Verwendung: $0 [--test|--uninstall]"; exit 1 ;;
esac
