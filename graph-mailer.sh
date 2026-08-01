#!/usr/bin/env bash
# graph-mailer.sh - Mailversand über Microsoft Graph (Microsoft 365),
#                   eingehängt als sendmail-Ersatz
# Modi:  (ohne Argument) = interaktives Menü
#        --sendmail ...  = sendmail-kompatibler Aufruf (liest die Mail von stdin)
#        --test          = Testmail
#        --status        = Konfiguration und Integration auf stdout
#        --uninstall     = Deinstallation
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"

CONF=/etc/graph-mailer.conf
SHIM=/usr/local/sbin/graph-sendmail
SENDMAIL=/usr/sbin/sendmail
TOKEN_DIR=/run/graph-mailer
TOKEN_FILE="$TOKEN_DIR/token"
LOGFILE=/var/log/graph-mailer.log

TENANT_ID=""
CLIENT_ID=""
CLIENT_SECRET=""
CLIENT_SECRET_CMD=""
SENDER=""
SENDER_NAME=""

# shellcheck disable=SC1090
[[ -r "$CONF" ]] && . "$CONF"

GRAPH=https://graph.microsoft.com/v1.0

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
    if (( ${#existing[@]} == 0 )); then echo "(nichts zu sichern)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

log() { echo "$(date '+%F %T') $*" >> "$LOGFILE"; }

is_setup() { [[ -n "$TENANT_ID" && -n "$CLIENT_ID" && -n "$SENDER" ]]; }

secret() {
    if [[ -n "$CLIENT_SECRET_CMD" ]]; then
        eval "$CLIENT_SECRET_CMD"
    else
        printf '%s' "$CLIENT_SECRET"
    fi
}

# Anführungszeichen und Backslashes für die curl-Config maskieren.
cfgesc() { printf '%s' "${1//\\/\\\\}" | sed 's/"/\\"/g'; }

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
# Zugangsdaten gehen über eine curl-Config auf stdin, nicht über die
# Kommandozeile - sonst stünde das Client-Secret in der Prozessliste.
fetch_token() {
    local resp tok exp url
    url="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

    resp=$(
        {
            printf 'data-urlencode = "client_id=%s"\n'     "$(cfgesc "$CLIENT_ID")"
            printf 'data-urlencode = "client_secret=%s"\n' "$(cfgesc "$(secret)")"
            printf 'data-urlencode = "scope=https://graph.microsoft.com/.default"\n'
            printf 'data-urlencode = "grant_type=client_credentials"\n'
        } | curl -sS -m 30 --config - -X POST "$url" 2>&1
    )

    tok=$(grep -o '"access_token":"[^"]*"' <<<"$resp" | head -1 | cut -d'"' -f4)
    exp=$(grep -o '"expires_in":[0-9]*'    <<<"$resp" | head -1 | cut -d: -f2)

    if [[ -z "$tok" ]]; then
        local msg
        msg=$(grep -o '"error_description":"[^"]*"' <<<"$resp" | head -1 | cut -d'"' -f4)
        [[ -z "$msg" ]] && msg=$(head -c 300 <<<"$resp")
        echo "!!! Kein Token: ${msg}" >&2
        log "Token fehlgeschlagen: ${msg}"
        return 1
    fi

    mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR"
    printf '%s\n%s\n' "$(( $(date +%s) + ${exp:-3600} ))" "$tok" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    printf '%s' "$tok"
}

get_token() {
    local exp tok
    if [[ -r "$TOKEN_FILE" ]]; then
        exp=$(sed -n '1p' "$TOKEN_FILE")
        tok=$(sed -n '2p' "$TOKEN_FILE")
        # 60 s Sicherheitsabstand, damit ein Token nicht mitten im Versand abläuft
        if [[ -n "$exp" && -n "$tok" ]] && (( $(date +%s) < exp - 60 )); then
            printf '%s' "$tok"; return 0
        fi
    fi
    fetch_token
}

# ---------------------------------------------------------------------------
# Versand
# ---------------------------------------------------------------------------
# Graph nimmt eine vollständige MIME-Nachricht base64-kodiert entgegen. Das ist
# für einen sendmail-Ersatz genau richtig: Anhänge, Kodierungen und eigene
# Header gehen unverändert durch, es muss nichts in JSON umgebaut werden.
send_mime() {
    local mime=$1
    local tok tmp out http

    tok=$(get_token) || return 1

    tmp=$(mktemp); out=$(mktemp)
    chmod 600 "$tmp" "$out"
    printf '%s' "$mime" | base64 | tr -d '\n' > "$tmp"

    http=$(
        printf 'header = "Authorization: Bearer %s"\n' "$(cfgesc "$tok")" \
        | curl -sS -m 120 --config - \
            -X POST "${GRAPH}/users/$(printf '%s' "$SENDER")/sendMail" \
            -H 'Content-Type: text/plain' \
            --data-binary "@$tmp" \
            -o "$out" -w '%{http_code}' 2>>"$out"
    )

    if [[ "$http" == "202" ]]; then
        rm -f "$tmp" "$out"
        return 0
    fi

    local msg
    msg=$(grep -o '"message":"[^"]*"' "$out" | head -1 | cut -d'"' -f4)
    [[ -z "$msg" ]] && msg=$(head -c 300 "$out")
    echo "!!! Graph antwortet HTTP ${http}: ${msg}" >&2
    log "Versand fehlgeschlagen (HTTP ${http}): ${msg}"
    rm -f "$tmp" "$out"
    return 1
}

# ---------------------------------------------------------------------------
# sendmail-Modus
# ---------------------------------------------------------------------------
sendmail_mode() {
    if [[ $EUID -ne 0 ]]; then
        echo "graph-sendmail: nur root kann versenden (Konfiguration ist 0600)." >&2
        exit 77
    fi
    if ! is_setup; then
        echo "graph-sendmail: nicht eingerichtet ($CONF)." >&2
        exit 78
    fi

    local -a rcpt=()
    local from=""
    while (( $# )); do
        case "$1" in
            -t)        ;;                       # Empfänger stehen in den Headern
            -f|-r)     shift; from=${1:-} ;;
            -f*)       from=${1#-f} ;;
            -F)        shift ;;                 # Anzeigename, uninteressant
            --)        ;;
            -*)        ;;                       # -i, -oi, -oem ... schlucken
            *)         rcpt+=("$1") ;;
        esac
        shift || true
    done

    local msg headers body
    msg=$(cat)

    # Header und Rumpf an der ersten Leerzeile trennen. Beginnt die Nachricht
    # nicht mit einem Header, ist sie vollständig Rumpf - so verhält sich auch
    # das echte sendmail.
    if [[ "$msg" =~ ^[A-Za-z][A-Za-z0-9-]*: ]]; then
        if [[ "$msg" == *$'\n\n'* ]]; then
            headers=${msg%%$'\n\n'*}
            body=${msg#*$'\n\n'}
        else
            headers="$msg"
            body=""
        fi
    else
        headers=""
        body="$msg"
    fi

    has_header() { grep -qiE "^$1:" <<<"$headers"; }

    local add=""
    if ! has_header To && (( ${#rcpt[@]} > 0 )); then
        local joined; joined=$(printf '%s, ' "${rcpt[@]}"); joined=${joined%, }
        add+="To: ${joined}"$'\n'
    fi
    if ! has_header From; then
        if [[ -n "$SENDER_NAME" ]]; then
            add+="From: ${SENDER_NAME} <${SENDER}>"$'\n'
        else
            add+="From: ${SENDER}"$'\n'
        fi
    fi
    has_header Date       || add+="Date: $(date -R)"$'\n'
    has_header Subject    || add+="Subject: (kein Betreff)"$'\n'
    has_header Message-ID || add+="Message-ID: <$(date +%s).$$@$(hostname -f 2>/dev/null || hostname)>"$'\n'
    if ! has_header MIME-Version && ! has_header Content-Type; then
        add+="MIME-Version: 1.0"$'\n'
        add+="Content-Type: text/plain; charset=UTF-8"$'\n'
    fi

    local hdr="${add}${headers}"
    hdr=${hdr%$'\n'}                       # genau ein Umbruch vor der Leerzeile
    local mime="${hdr}"$'\n\n'"${body}"

    # Der Envelope-Absender aus -f interessiert Graph nicht: es verschickt immer
    # aus dem konfigurierten Postfach. Fürs Protokoll wird er festgehalten.
    if send_mime "$mime"; then
        log "gesendet an ${rcpt[*]:-<Header>}${from:+ (envelope-from ${from})}"
        exit 0
    fi
    log "FEHLER beim Versand an ${rcpt[*]:-<Header>}"
    exit 75      # EX_TEMPFAIL - der Aufrufer darf es später erneut versuchen
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------
save_conf() {
    umask 077
    cat > "$CONF" <<EOF
# graph-mailer - erzeugt am $(date '+%F %T')
TENANT_ID="${TENANT_ID}"
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
# Alternative zum Klartext-Secret: ein Kommando, das es ausgibt
CLIENT_SECRET_CMD="${CLIENT_SECRET_CMD}"
SENDER="${SENDER}"
SENDER_NAME="${SENDER_NAME}"
EOF
    chmod 600 "$CONF"
    chown root:root "$CONF"
}

install_shim() {
    cat > "$SHIM" <<EOF
#!/bin/sh
# sendmail-kompatibler Einstieg für graph-mailer.sh
exec ${SELF} --sendmail "\$@"
EOF
    chmod 755 "$SHIM"
}

sendmail_active() {
    [[ -L "$SENDMAIL" ]] && [[ "$(readlink -f "$SENDMAIL")" == "$(readlink -f "$SHIM")" ]]
}

enable_sendmail() {
    if sendmail_active; then echo "Bereits eingehängt."; return 0; fi

    if [[ -f /etc/msmtprc ]]; then
        echo "!!! Es gibt eine msmtp-Konfiguration (/etc/msmtprc)."
        echo "!!! Beide Mailer können nicht gleichzeitig sendmail sein - der Graph-"
        echo "!!! Mailer übernimmt jetzt, msmtp bleibt konfiguriert, aber ungenutzt."
        confirm "Trotzdem fortfahren?" || return 1
    fi

    # dpkg-divert statt Überschreiben: die Datei eines Pakets wird beiseite
    # gelegt statt zerstört, und ein Paket-Update legt sie nicht wieder darüber.
    if command -v dpkg-divert &>/dev/null; then
        dpkg-divert --quiet --add --rename --divert "${SENDMAIL}.distrib" "$SENDMAIL" || true
    elif [[ -e "$SENDMAIL" ]]; then
        mv "$SENDMAIL" "${SENDMAIL}.distrib"
    fi

    ln -sf "$SHIM" "$SENDMAIL"
    echo "$SENDMAIL zeigt jetzt auf $SHIM."
}

disable_sendmail() {
    sendmail_active || { echo "Nicht eingehängt."; return 0; }
    rm -f "$SENDMAIL"
    if command -v dpkg-divert &>/dev/null; then
        dpkg-divert --quiet --remove --rename "$SENDMAIL" || true
    elif [[ -e "${SENDMAIL}.distrib" ]]; then
        mv "${SENDMAIL}.distrib" "$SENDMAIL"
    fi
    echo "Ursprünglicher Zustand von $SENDMAIL wiederhergestellt."
}

configure() {
    if ! command -v curl &>/dev/null; then
        echo ">>> Installiere curl..."
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null
    fi

    echo ">>> Microsoft-365-Mailer (Graph)"
    echo
    echo "Gebraucht wird eine App-Registrierung in Entra ID mit der"
    echo "ANWENDUNGSberechtigung 'Mail.Send' (nicht 'delegiert'), für die ein"
    echo "Administrator die Zustimmung erteilt hat."
    echo

    local T C S SND N SC
    read -rp "Verzeichnis-ID (Tenant) [${TENANT_ID}]: " T; TENANT_ID=${T:-$TENANT_ID}
    while [[ -z "$TENANT_ID" ]]; do read -rp "  -> Pflichtfeld: " TENANT_ID; done

    read -rp "Anwendungs-ID (Client) [${CLIENT_ID}]: " C; CLIENT_ID=${C:-$CLIENT_ID}
    while [[ -z "$CLIENT_ID" ]]; do read -rp "  -> Pflichtfeld: " CLIENT_ID; done

    echo
    echo "Das Client-Secret kann im Klartext in ${CONF} (0600) stehen, oder ein"
    echo "Kommando liefert es (z.B. 'cat /root/.graph-secret')."
    read -rp "Kommando statt Klartext (leer = Klartext) [${CLIENT_SECRET_CMD}]: " SC
    CLIENT_SECRET_CMD=${SC:-$CLIENT_SECRET_CMD}

    if [[ -z "$CLIENT_SECRET_CMD" ]]; then
        read -rsp "Client-Secret (leer = bestehendes behalten): " S; echo
        [[ -n "$S" ]] && CLIENT_SECRET="$S"
        while [[ -z "$CLIENT_SECRET" ]]; do
            read -rsp "  -> Pflichtfeld: " CLIENT_SECRET; echo
        done
    else
        CLIENT_SECRET=""
    fi

    echo
    read -rp "Absender-Postfach (UPN, z.B. server@firma.de) [${SENDER}]: " SND
    SENDER=${SND:-$SENDER}
    while [[ -z "$SENDER" ]]; do read -rp "  -> Pflichtfeld: " SENDER; done

    read -rp "Anzeigename (optional) [${SENDER_NAME}]: " N; SENDER_NAME=${N:-$SENDER_NAME}

    save_conf
    install_shim
    touch "$LOGFILE"; chmod 600 "$LOGFILE"

    echo
    echo "Konfiguration in ${CONF} (0600), Shim in ${SHIM}."
    echo

    echo ">>> Token wird geholt..."
    if fetch_token >/dev/null; then
        echo "Token erhalten - Zugangsdaten und Berechtigung stimmen."
    else
        echo "Der Token-Abruf hat nicht geklappt. Die Konfiguration ist gespeichert,"
        echo "Menüpunkt 3 zeigt den Fehler erneut."
        pause; return
    fi

    echo
    if confirm "sendmail auf diesen Mailer umbiegen?" J; then
        enable_sendmail || true
    fi

    echo
    confirm "Jetzt eine Testmail senden?" J && send_test || pause
}

send_test() {
    is_setup || { echo "Nicht eingerichtet."; pause; return; }

    local rcpt
    read -rp "Empfänger [${SENDER}]: " rcpt; rcpt=${rcpt:-$SENDER}
    while [[ -z "$rcpt" ]]; do read -rp "  -> Pflichtfeld: " rcpt; done

    local host mime
    host=$(hostname -f 2>/dev/null || hostname)
    mime="From: ${SENDER_NAME:-$SENDER} <${SENDER}>
To: ${rcpt}
Subject: Testmail von ${host}
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Der Versand über Microsoft Graph funktioniert.

Host:     ${host}
Absender: ${SENDER}
Zeit:     $(date '+%F %T')
"

    echo ">>> Sende an ${rcpt} ..."
    if send_mime "$mime"; then
        echo ">>> Von Graph angenommen (HTTP 202)."
        log "Testmail an ${rcpt} angenommen"
    else
        echo "!!! Fehlgeschlagen. Letzte Logzeilen:"
        tail -n 5 "$LOGFILE" 2>/dev/null || true
    fi
    pause
}

show_status() {
    echo "--- Konfiguration ($CONF) ---"
    if is_setup; then
        printf '  %-14s %s\n' "Tenant"    "$TENANT_ID"
        printf '  %-14s %s\n' "Client"    "$CLIENT_ID"
        printf '  %-14s %s\n' "Secret"    "$([[ -n "$CLIENT_SECRET_CMD" ]] && echo "über Kommando: $CLIENT_SECRET_CMD" || echo '******** (im Klartext hinterlegt)')"
        printf '  %-14s %s\n' "Absender"  "${SENDER_NAME:+$SENDER_NAME }<${SENDER}>"
    else
        echo "  (nicht eingerichtet)"
    fi
    echo
    echo "--- sendmail-Integration ---"
    if sendmail_active; then
        echo "  aktiv: $SENDMAIL -> $SHIM"
    else
        echo "  nicht aktiv"
        [[ -e "$SENDMAIL" ]] && echo "  $SENDMAIL zeigt auf: $(readlink -f "$SENDMAIL")"
    fi
    [[ -e "${SENDMAIL}.distrib" ]] && echo "  beiseitegelegt: ${SENDMAIL}.distrib"
    echo
    echo "--- Token ---"
    if [[ -r "$TOKEN_FILE" ]]; then
        local exp; exp=$(sed -n '1p' "$TOKEN_FILE")
        echo "  zwischengespeichert, gültig bis $(date -d "@${exp}" '+%F %T' 2>/dev/null || echo "$exp")"
    else
        echo "  keiner zwischengespeichert"
    fi
}

check_token() {
    echo ">>> Token wird neu geholt..."
    if fetch_token >/dev/null; then
        echo "Erfolgreich. Gültig bis $(date -d "@$(sed -n '1p' "$TOKEN_FILE")" '+%F %T' 2>/dev/null)."
    fi
    pause
}

show_log() {
    [[ -f "$LOGFILE" ]] || { echo "Kein Log vorhanden."; pause; return; }
    tail -n 40 "$LOGFILE"
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation Microsoft-365-Mailer"
    echo
    echo "Folgendes wird entfernt:"
    sendmail_active     && echo "  - die sendmail-Umleitung ($SENDMAIL -> $SHIM)"
    [[ -f "$SHIM" ]]    && echo "  - $SHIM"
    [[ -f "$CONF" ]]    && echo "  - $CONF (enthält das Client-Secret)"
    [[ -d "$TOKEN_DIR" ]] && echo "  - zwischengespeichertes Token in $TOKEN_DIR"
    [[ -f "$LOGFILE" ]] && echo "  - $LOGFILE                                    [Rückfrage]"
    echo
    echo "Die App-Registrierung in Entra ID bleibt bestehen - die muss dort"
    echo "gelöscht werden, wenn sie nicht mehr gebraucht wird."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup graph-mailer "$CONF" "$SHIM" "$LOGFILE" || { pause; return; }

    disable_sendmail
    rm -f "$SHIM" "$CONF"
    rm -rf "$TOKEN_DIR"

    if [[ -f "$LOGFILE" ]] && confirm "$LOGFILE ebenfalls löschen?"; then
        rm -f "$LOGFILE"
    fi

    echo
    echo "Entfernt."
    if [[ -f /etc/msmtprc ]]; then
        echo "Hinweis: /etc/msmtprc ist noch da - mail-setup.sh kann den Versand"
        echo "wieder übernehmen (dort Menüpunkt 1)."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Microsoft-365-Mailer (Graph)"
        echo "==========================================="
        if is_setup; then
            echo "Absender: ${SENDER}"
            echo "Tenant:   ${TENANT_ID}"
            echo "sendmail: $(sendmail_active && echo "auf diesen Mailer umgebogen" || echo "nicht umgebogen")"
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Einrichten / Zugangsdaten bearbeiten"
        echo "2) Testmail senden"
        echo "3) Token prüfen"
        echo "4) Status anzeigen"
        echo "5) sendmail-Integration $(sendmail_active && echo "abschalten" || echo "einschalten")"
        echo "6) Log anzeigen"
        echo "7) Deinstallieren"
        echo "8) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) configure ;;
            2) send_test ;;
            3) check_token ;;
            4) show_status; pause ;;
            5) if sendmail_active; then disable_sendmail; else enable_sendmail || true; fi; pause ;;
            6) show_log ;;
            7) uninstall ;;
            8) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --sendmail)  shift; sendmail_mode "$@" ;;
    --test)      [[ $EUID -eq 0 ]] || { echo "Bitte als root." >&2; exit 1; }; send_test ;;
    --status)    show_status ;;
    --uninstall) [[ $EUID -eq 0 ]] || { echo "Bitte als root." >&2; exit 1; }; uninstall ;;
    "")          [[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }
                 is_setup || configure; main_menu ;;
    *)           echo "Verwendung: $0 [--sendmail ...|--test|--status|--uninstall]"; exit 1 ;;
esac
