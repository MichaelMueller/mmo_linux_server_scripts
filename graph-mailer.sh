#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# graph-mailer.sh - send mail through Microsoft Graph (Microsoft 365),
#                   hooked in as a sendmail replacement
# Modes: (no argument)  = interactive menu
#        --sendmail ... = sendmail-compatible call (reads the mail from stdin)
#        --test         = test mail
#        --status       = configuration and integration on stdout
#        --uninstall    = uninstall
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.2.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

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

pause() { read -rp "Press Enter to continue..." _; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nothing to back up)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
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

# Escape quotes and backslashes for the curl config.
cfgesc() { printf '%s' "${1//\\/\\\\}" | sed 's/"/\\"/g'; }

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
# Credentials go through a curl config on stdin, not over the command line -
# otherwise the client secret would show up in the process list.
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
        echo "!!! No token: ${msg}" >&2
        log "token failed: ${msg}"
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
        # 60 s of headroom, so a token does not expire mid-send
        if [[ -n "$exp" && -n "$tok" ]] && (( $(date +%s) < exp - 60 )); then
            printf '%s' "$tok"; return 0
        fi
    fi
    fetch_token
}

# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------
# Graph accepts a complete MIME message, base64-encoded. That is exactly right
# for a sendmail replacement: attachments, encodings and custom headers pass
# through unchanged, nothing has to be rebuilt as JSON.
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
    echo "!!! Graph answers HTTP ${http}: ${msg}" >&2
    log "send failed (HTTP ${http}): ${msg}"
    rm -f "$tmp" "$out"
    return 1
}

# ---------------------------------------------------------------------------
# sendmail mode
# ---------------------------------------------------------------------------
sendmail_mode() {
    if [[ $EUID -ne 0 ]]; then
        echo "graph-sendmail: only root can send (the configuration is 0600)." >&2
        exit 77
    fi
    if ! is_setup; then
        echo "graph-sendmail: not set up ($CONF)." >&2
        exit 78
    fi

    local -a rcpt=()
    local from=""
    while (( $# )); do
        case "$1" in
            -t)        ;;                       # recipients are in the headers
            -f|-r)     shift; from=${1:-} ;;
            -f*)       from=${1#-f} ;;
            -F)        shift ;;                 # display name, not interesting
            --)        ;;
            -*)        ;;                       # swallow -i, -oi, -oem ...
            *)         rcpt+=("$1") ;;
        esac
        shift || true
    done

    local msg headers body
    msg=$(cat)

    # Split headers and body at the first blank line. If the message does not
    # start with a header, it is all body - that is what the real sendmail
    # does too.
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
    has_header Subject    || add+="Subject: (no subject)"$'\n'
    has_header Message-ID || add+="Message-ID: <$(date +%s).$$@$(hostname -f 2>/dev/null || hostname)>"$'\n'
    if ! has_header MIME-Version && ! has_header Content-Type; then
        add+="MIME-Version: 1.0"$'\n'
        add+="Content-Type: text/plain; charset=UTF-8"$'\n'
    fi

    local hdr="${add}${headers}"
    hdr=${hdr%$'\n'}                       # exactly one break before the blank line
    local mime="${hdr}"$'\n\n'"${body}"

    # Graph does not care about the envelope sender from -f: it always sends
    # from the configured mailbox. It is recorded for the log.
    if send_mime "$mime"; then
        log "sent to ${rcpt[*]:-<header>}${from:+ (envelope-from ${from})}"
        exit 0
    fi
    log "ERROR sending to ${rcpt[*]:-<header>}"
    exit 75      # EX_TEMPFAIL - the caller may try again later
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
save_conf() {
    umask 077
    cat > "$CONF" <<EOF
# graph-mailer - generated on $(date '+%F %T')
TENANT_ID="${TENANT_ID}"
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
# Alternative to the clear-text secret: a command that prints it
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
# sendmail-compatible entry point for graph-mailer.sh
exec ${SELF} --sendmail "\$@"
EOF
    chmod 755 "$SHIM"
}

sendmail_active() {
    [[ -L "$SENDMAIL" ]] && [[ "$(readlink -f "$SENDMAIL")" == "$(readlink -f "$SHIM")" ]]
}

enable_sendmail() {
    if sendmail_active; then echo "Already hooked in."; return 0; fi

    if [[ -f /etc/msmtprc ]]; then
        echo "!!! There is an msmtp configuration (/etc/msmtprc)."
        echo "!!! Both mailers cannot be sendmail at the same time - the Graph"
        echo "!!! mailer takes over now, msmtp stays configured but unused."
        confirm "Continue anyway?" || return 1
    fi

    # dpkg-divert instead of overwriting: a package's file is moved aside
    # instead of destroyed, and a package update does not put it back on top.
    if command -v dpkg-divert &>/dev/null; then
        dpkg-divert --quiet --add --rename --divert "${SENDMAIL}.distrib" "$SENDMAIL" || true
    elif [[ -e "$SENDMAIL" ]]; then
        mv "$SENDMAIL" "${SENDMAIL}.distrib"
    fi

    ln -sf "$SHIM" "$SENDMAIL"
    echo "$SENDMAIL now points at $SHIM."
}

disable_sendmail() {
    sendmail_active || { echo "Not hooked in."; return 0; }
    rm -f "$SENDMAIL"
    if command -v dpkg-divert &>/dev/null; then
        dpkg-divert --quiet --remove --rename "$SENDMAIL" || true
    elif [[ -e "${SENDMAIL}.distrib" ]]; then
        mv "${SENDMAIL}.distrib" "$SENDMAIL"
    fi
    echo "Original state of $SENDMAIL restored."
}

configure() {
    if ! command -v curl &>/dev/null; then
        echo ">>> Installing curl..."
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null
    fi

    echo ">>> Microsoft 365 mailer (Graph)"
    echo
    echo "What you need is an app registration in Entra ID with the APPLICATION"
    echo "permission 'Mail.Send' (not 'delegated'), granted admin consent."
    echo

    local T C S SND N SC
    read -rp "Directory ID (tenant) [${TENANT_ID}]: " T; TENANT_ID=${T:-$TENANT_ID}
    while [[ -z "$TENANT_ID" ]]; do read -rp "  -> required: " TENANT_ID; done

    read -rp "Application ID (client) [${CLIENT_ID}]: " C; CLIENT_ID=${C:-$CLIENT_ID}
    while [[ -z "$CLIENT_ID" ]]; do read -rp "  -> required: " CLIENT_ID; done

    echo
    echo "The client secret can sit in clear text in ${CONF} (0600), or a command"
    echo "can supply it (e.g. 'cat /root/.graph-secret')."
    read -rp "Command instead of clear text (empty = clear text) [${CLIENT_SECRET_CMD}]: " SC
    CLIENT_SECRET_CMD=${SC:-$CLIENT_SECRET_CMD}

    if [[ -z "$CLIENT_SECRET_CMD" ]]; then
        read -rsp "Client secret (empty = keep the existing one): " S; echo
        [[ -n "$S" ]] && CLIENT_SECRET="$S"
        while [[ -z "$CLIENT_SECRET" ]]; do
            read -rsp "  -> required: " CLIENT_SECRET; echo
        done
    else
        CLIENT_SECRET=""
    fi

    echo
    read -rp "Sender mailbox (UPN, e.g. server@company.com) [${SENDER}]: " SND
    SENDER=${SND:-$SENDER}
    while [[ -z "$SENDER" ]]; do read -rp "  -> required: " SENDER; done

    read -rp "Display name (optional) [${SENDER_NAME}]: " N; SENDER_NAME=${N:-$SENDER_NAME}

    save_conf
    install_shim
    touch "$LOGFILE"; chmod 600 "$LOGFILE"

    echo
    echo "Configuration in ${CONF} (0600), shim in ${SHIM}."
    echo

    echo ">>> Fetching a token..."
    if fetch_token >/dev/null; then
        echo "Token received - credentials and permission are correct."
    else
        echo "Fetching the token did not work. The configuration is saved,"
        echo "menu item 3 shows the error again."
        pause; return
    fi

    echo
    if confirm "Point sendmail at this mailer?" Y; then
        enable_sendmail || true
    fi

    echo
    confirm "Send a test mail now?" Y && send_test || pause
}

send_test() {
    is_setup || { echo "Not set up."; pause; return; }

    local rcpt
    read -rp "Recipient [${SENDER}]: " rcpt; rcpt=${rcpt:-$SENDER}
    while [[ -z "$rcpt" ]]; do read -rp "  -> required: " rcpt; done

    local host mime
    host=$(hostname -f 2>/dev/null || hostname)
    mime="From: ${SENDER_NAME:-$SENDER} <${SENDER}>
To: ${rcpt}
Subject: Test mail from ${host}
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Sending through Microsoft Graph works.

Host:   ${host}
Sender: ${SENDER}
Time:   $(date '+%F %T')
"

    echo ">>> Sending to ${rcpt} ..."
    if send_mime "$mime"; then
        echo ">>> Accepted by Graph (HTTP 202)."
        log "test mail to ${rcpt} accepted"
    else
        echo "!!! Failed. Last log lines:"
        tail -n 5 "$LOGFILE" 2>/dev/null || true
    fi
    pause
}

show_status() {
    echo "--- Configuration ($CONF) ---"
    if is_setup; then
        printf '  %-14s %s\n' "Tenant"  "$TENANT_ID"
        printf '  %-14s %s\n' "Client"  "$CLIENT_ID"
        printf '  %-14s %s\n' "Secret"  "$([[ -n "$CLIENT_SECRET_CMD" ]] && echo "through a command: $CLIENT_SECRET_CMD" || echo '******** (stored in clear text)')"
        printf '  %-14s %s\n' "Sender"  "${SENDER_NAME:+$SENDER_NAME }<${SENDER}>"
    else
        echo "  (not set up)"
    fi
    echo
    echo "--- sendmail integration ---"
    if sendmail_active; then
        echo "  active: $SENDMAIL -> $SHIM"
    else
        echo "  not active"
        [[ -e "$SENDMAIL" ]] && echo "  $SENDMAIL points at: $(readlink -f "$SENDMAIL")"
    fi
    [[ -e "${SENDMAIL}.distrib" ]] && echo "  moved aside: ${SENDMAIL}.distrib"
    echo
    echo "--- Token ---"
    if [[ -r "$TOKEN_FILE" ]]; then
        local exp; exp=$(sed -n '1p' "$TOKEN_FILE")
        echo "  cached, valid until $(date -d "@${exp}" '+%F %T' 2>/dev/null || echo "$exp")"
    else
        echo "  none cached"
    fi
}

check_token() {
    echo ">>> Fetching a fresh token..."
    if fetch_token >/dev/null; then
        echo "Successful. Valid until $(date -d "@$(sed -n '1p' "$TOKEN_FILE")" '+%F %T' 2>/dev/null)."
    fi
    pause
}

show_log() {
    [[ -f "$LOGFILE" ]] || { echo "There is no log."; pause; return; }
    tail -n 40 "$LOGFILE"
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall Microsoft 365 mailer"
    echo
    echo "The following will be removed:"
    sendmail_active     && echo "  - the sendmail redirection ($SENDMAIL -> $SHIM)"
    [[ -f "$SHIM" ]]    && echo "  - $SHIM"
    [[ -f "$CONF" ]]    && echo "  - $CONF (contains the client secret)"
    [[ -d "$TOKEN_DIR" ]] && echo "  - cached token in $TOKEN_DIR"
    [[ -f "$LOGFILE" ]] && echo "  - $LOGFILE                                    [asked]"
    echo
    echo "The app registration in Entra ID stays - it has to be deleted there if"
    echo "it is no longer needed."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup graph-mailer "$CONF" "$SHIM" "$LOGFILE" || { pause; return; }

    disable_sendmail
    rm -f "$SHIM" "$CONF"
    rm -rf "$TOKEN_DIR"

    if [[ -f "$LOGFILE" ]] && confirm "Delete $LOGFILE as well?"; then
        rm -f "$LOGFILE"
    fi

    echo
    echo "Removed."
    if [[ -f /etc/msmtprc ]]; then
        echo "Note: /etc/msmtprc is still there - mail-setup.sh can take sending"
        echo "over again (menu item 1 there)."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Microsoft 365 mailer (Graph)"
        echo "==========================================="
        if is_setup; then
            echo "Sender:   ${SENDER}"
            echo "Tenant:   ${TENANT_ID}"
            echo "sendmail: $(sendmail_active && echo "pointed at this mailer" || echo "not redirected")"
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Set up / edit credentials"
        echo "2) Send a test mail"
        echo "3) Check the token"
        echo "4) Show status"
        echo "5) $(sendmail_active && echo "Switch off" || echo "Switch on") the sendmail integration"
        echo "6) Show the log"
        echo "7) Uninstall"
        echo "8) Quit"
        read -rp "Choice: " CH
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
    --test)      [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; send_test ;;
    --status)    show_status ;;
    --uninstall) [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; uninstall ;;
    "")          [[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)." >&2; exit 1; }
                 is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--sendmail ...|--test|--status|--uninstall|--version]"; exit 1 ;;
esac
