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
VERSION="2.4.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"

CONF=/etc/graph-mailer.conf
CRON_FILE=/etc/cron.d/graph-mailer
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
# Client secrets in Entra ID expire - 6, 12 or 24 months, and then sending stops
# dead with AADSTS7000215. Entra sends no reminder anywhere near the machine
# that depends on it, so the date is kept here and warned about from here.
SECRET_EXPIRY=""         # YYYY-MM-DD, when the client secret expires
EXPIRY_WARN_DAYS=30      # start warning this many days before that
EXPIRY_MAIL=""           # recipient of the warning - mandatory, no fallback

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
SECRET_EXPIRY="${SECRET_EXPIRY}"
EXPIRY_WARN_DAYS=${EXPIRY_WARN_DAYS}
EXPIRY_MAIL="${EXPIRY_MAIL}"
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

    # The expiry date is the one piece of information Entra will not remind you
    # about anywhere near this machine. It is on the same screen where the
    # secret was just created, so this is the moment to write it down.
    echo
    echo "--- Secret expiry ---"
    echo "A client secret expires (6, 12 or 24 months), and when it does every"
    echo "mail from this host stops going out with AADSTS7000215. Entra shows the"
    echo "date next to the secret you just created - entering it here gets you a"
    echo "warning by mail in good time."
    local EW EM
    if ask_expiry_date "Expiry date, e.g. 2028-06-30 (empty = no warning) [${SECRET_EXPIRY}]: "; then
        SECRET_EXPIRY=$NEW_EXPIRY
    else
        # Empty: whatever was already stored stays, which for a first setup means
        # no warning at all.
        [[ -z "$SECRET_EXPIRY" ]] && echo "  (no date - no warning before the secret expires)"
    fi

    if [[ -n "$SECRET_EXPIRY" ]]; then
        read -rp "Warn how many days before? [${EXPIRY_WARN_DAYS}]: " EW
        EXPIRY_WARN_DAYS=${EW:-$EXPIRY_WARN_DAYS}
        while [[ ! "$EXPIRY_WARN_DAYS" =~ ^[0-9]+$ ]] || (( EXPIRY_WARN_DAYS < 1 )); do
            read -rp "  -> a whole number of days, at least 1: " EXPIRY_WARN_DAYS
        done
        ask_expiry_mail
        EXPIRY_MAIL=$NEW_EXPIRY_MAIL
        echo "  -> checked daily, warning from ${EXPIRY_WARN_DAYS} days before"
        echo "     ${SECRET_EXPIRY}, to ${EXPIRY_MAIL}"
    fi

    save_conf
    write_expiry_cron
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

# ---------------------------------------------------------------------------
# Secret expiry
# ---------------------------------------------------------------------------
# Days until SECRET_EXPIRY. Negative means it has already passed. Prints
# nothing and fails when no date is configured or it cannot be parsed.
# Reads an expiry date and puts it into the global NEW_EXPIRY, normalised to
# YYYY-MM-DD. Returns 1 when the input was empty - what that means is the
# caller's business.
#
# The point of this being a function of its own: saying WHICH of the two
# possible mistakes was made. "2028-06-31" has a perfectly correct format and
# simply does not exist - June has 30 days - and answering that with "format
# YYYY-MM-DD" sends you looking in the wrong place. A pasted "20280630" is
# accepted too, because that is how the date appears in some Entra views.
# Reads the recipient of the expiry warning into the global NEW_EXPIRY_MAIL.
#
# Deliberately without a default and deliberately mandatory. Falling back to
# SENDER looks convenient and is the wrong answer: the sending mailbox is
# frequently a noreply address that nobody ever opens, so the one message that
# has to be read by a human would land exactly where nothing is read. Whoever
# renews the secret has to be named.
ask_expiry_mail() {
    local in
    NEW_EXPIRY_MAIL=""
    echo "Who gets the warning? This has to be a mailbox somebody actually reads"
    echo "- not the sending address if that is a noreply one."
    while true; do
        read -rp "Mail address for the expiry warning${EXPIRY_MAIL:+ [$EXPIRY_MAIL]}: " in
        in="${in//[[:space:]]/}"
        [[ -z "$in" ]] && in=$EXPIRY_MAIL
        if [[ -z "$in" ]]; then
            echo "  !!! Required - without a recipient the warning goes nowhere."
            continue
        fi
        if [[ ! "$in" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            echo "  !!! That is not a mail address (user@example.com)."
            continue
        fi
        if [[ "$in" == "$SENDER" ]]; then
            echo "  Note: that is the sending address itself. Fine if it is a real"
            echo "  mailbox, useless if it is a noreply one."
            confirm "  Use it anyway?" Y || continue
        fi
        NEW_EXPIRY_MAIL=$in
        return 0
    done
}

ask_expiry_date() {
    local prompt=$1 in norm y m dd last days
    NEW_EXPIRY=""
    while true; do
        read -rp "$prompt" in
        in="${in//[[:space:]]/}"
        [[ -z "$in" ]] && return 1

        # 20280630 -> 2028-06-30
        if [[ "$in" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
            in="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        fi

        if norm=$(date -d "$in" +%F 2>/dev/null); then
            [[ "$norm" != "$in" ]] && echo "  -> read as ${norm}"
            days=$(( ( $(date -d "$norm" +%s) - $(date -d "$(date +%F)" +%s) ) / 86400 ))
            if (( days < 0 )); then
                echo "  !!! ${norm} is ${days#-} day(s) in the PAST - if that is right,"
                echo "  !!! sending is already failing and the secret needs renewing now."
            fi
            NEW_EXPIRY=$norm
            return 0
        fi

        # Parsing failed. Was the shape right, or the day?
        if [[ "$in" =~ ^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$ ]]; then
            y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; dd=${BASH_REMATCH[3]}
            if (( 10#$m < 1 || 10#$m > 12 )); then
                echo "  !!! There is no month ${m} - the month goes from 01 to 12."
            else
                last=$(date -d "${y}-${m}-01 +1 month -1 day" +%d 2>/dev/null)
                echo "  !!! There is no ${y}-${m}-${dd}: ${y}-${m} has ${last} days."
            fi
        else
            echo "  !!! Not a date: expected year-month-day, e.g. 2028-06-30."
        fi
        echo "      (empty = no warning)"
    done
}

expiry_days() {
    [[ -n "$SECRET_EXPIRY" ]] || return 1
    local exp now
    exp=$(date -d "$SECRET_EXPIRY" +%s 2>/dev/null) || return 1
    now=$(date -d "$(date '+%F')" +%s)      # midnight, so the count is in whole days
    echo $(( (exp - now) / 86400 ))
}

expiry_text() {
    local d
    if ! d=$(expiry_days); then
        # An unreadable date must not look like "nothing configured" - that would
        # quietly cost exactly the warning this is here for.
        [[ -n "$SECRET_EXPIRY" ]] && echo "!!! unreadable date: ${SECRET_EXPIRY}" \
                                  || echo "no date configured"
        return
    fi
    if (( d < 0 )); then
        echo "EXPIRED ${SECRET_EXPIRY} ($(( -d )) day$( (( d == -1 )) || echo s) ago)"
    elif (( d == 0 )); then
        echo "expires TODAY (${SECRET_EXPIRY})"
    else
        echo "${d} day$( (( d == 1 )) || echo s) left (${SECRET_EXPIRY})"
    fi
}

write_expiry_cron() {
    if [[ -z "$SECRET_EXPIRY" ]]; then
        rm -f "$CRON_FILE"
        return 0
    fi
    cat > "$CRON_FILE" <<CRON
# graph-mailer - warn before the client secret expires
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 8 * * * root ${SELF} --check-expiry >/dev/null 2>&1
CRON
    chmod 644 "$CRON_FILE"
}

# Cron runner. Sends a warning once a day while inside the warning window, and
# keeps sending after the date has passed - at that point the mail will most
# likely no longer go out, which is itself the reason to warn early.
check_expiry() {
    is_setup || { echo "Not set up." >&2; return 1; }
    local d rcpt host subject body
    d=$(expiry_days) || { echo "No expiry date configured - nothing to check."; return 0; }

    if (( d > EXPIRY_WARN_DAYS )); then
        echo "Client secret: ${d} days left - nothing to do."
        return 0
    fi

    # No fallback to SENDER: if no recipient was stored, saying so in the log
    # beats sending the warning to a mailbox that may be a noreply one.
    if [[ -z "$EXPIRY_MAIL" ]]; then
        log "!!! secret expires in ${d} days but EXPIRY_MAIL is empty - nobody warned"
        echo "!!! ${d} day(s) left, but no recipient is configured (menu item 4)."
        return 1
    fi
    rcpt=$EXPIRY_MAIL
    host=$(hostname -f 2>/dev/null || hostname)

    if (( d < 0 )); then
        subject="[graph-mailer] ${host}: client secret EXPIRED"
        body="The Entra ID client secret for this mailer expired on ${SECRET_EXPIRY}, $(( -d )) day(s) ago.

Mail delivery through Graph is failing with AADSTS7000215 until a new secret is
stored. This message could only reach you if something else is carrying it.

  1. Entra ID -> App registrations -> ${CLIENT_ID} -> Certificates & secrets
  2. Create a new client secret
  3. sudo ${SELF}   -> menu item 1, enter the new secret and its expiry date"
    else
        subject="[graph-mailer] ${host}: client secret expires in ${d} day(s)"
        body="The Entra ID client secret for this mailer expires on ${SECRET_EXPIRY} - in ${d} day(s).

When it does, every mail from this host stops going out, including the
monitoring alerts and this warning itself. Renew it before then:

  1. Entra ID -> App registrations -> ${CLIENT_ID} -> Certificates & secrets
  2. Create a new client secret
  3. sudo ${SELF}   -> menu item 1, enter the new secret and its expiry date"
    fi

    local mime
    mime="From: ${SENDER_NAME:-$SENDER} <${SENDER}>
To: ${rcpt}
Subject: ${subject}
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

${body}
"
    if send_mime "$mime"; then
        log "expiry warning sent to ${rcpt} (${d} days left)"
        echo "Warning sent to ${rcpt} (${d} day(s) left)."
    else
        log "!!! expiry warning to ${rcpt} could not be sent (${d} days left)"
        echo "!!! The warning could not be sent - see ${LOGFILE}."
        return 1
    fi
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
        printf '  %-14s %s\n' "Secret expiry" "$(expiry_text)"
        [[ -n "$SECRET_EXPIRY" ]] && printf '  %-14s %s\n' "Warning" "from ${EXPIRY_WARN_DAYS} days before, to ${EXPIRY_MAIL:-!!! nobody configured}"
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
    [[ -f "$CRON_FILE" ]] && echo "  - $CRON_FILE (the expiry warning)"
    [[ -d "$TOKEN_DIR" ]] && echo "  - cached token in $TOKEN_DIR"
    [[ -f "$LOGFILE" ]] && echo "  - $LOGFILE                                    [asked]"
    echo
    echo "The app registration in Entra ID stays - it has to be deleted there if"
    echo "it is no longer needed."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup graph-mailer "$CONF" "$SHIM" "$LOGFILE" || { pause; return; }

    disable_sendmail
    rm -f "$SHIM" "$CONF" "$CRON_FILE"
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
expiry_menu() {
    while true; do
        echo
        echo "--- Secret expiry ---"
        echo "Client secret: $(expiry_text)"
        if [[ -n "$SECRET_EXPIRY" ]]; then
            echo "Warning:       from ${EXPIRY_WARN_DAYS} days before, to ${EXPIRY_MAIL:-!!! nobody configured}"
            echo "Cron:          $([[ -f "$CRON_FILE" ]] && echo "$CRON_FILE (daily 08:17)" || echo "!!! not installed")"
        fi
        echo
        echo "1) Set the date, the lead time and the recipient"
        echo "2) Run the check now (sends only if inside the window)"
        echo "3) Remove the date and the daily check"
        echo "4) Back"
        local C EW EM
        read -rp "Choice: " C
        case "$C" in
            1)
                if ! ask_expiry_date "Expiry date, e.g. 2028-06-30 [${SECRET_EXPIRY}]: "; then
                    echo "Cancelled - nothing changed."
                    continue
                fi
                SECRET_EXPIRY=$NEW_EXPIRY
                read -rp "Warn how many days before? [${EXPIRY_WARN_DAYS}]: " EW
                EXPIRY_WARN_DAYS=${EW:-$EXPIRY_WARN_DAYS}
                while [[ ! "$EXPIRY_WARN_DAYS" =~ ^[0-9]+$ ]] || (( EXPIRY_WARN_DAYS < 1 )); do
                    read -rp "  -> a whole number of days, at least 1: " EXPIRY_WARN_DAYS
                done
                ask_expiry_mail
                EXPIRY_MAIL=$NEW_EXPIRY_MAIL
                save_conf
                write_expiry_cron
                echo "Stored: $(expiry_text), warning from ${EXPIRY_WARN_DAYS} days before."
                ;;
            2)  check_expiry || true; pause ;;
            3)
                if confirm "Remove the expiry date and the daily check?"; then
                    SECRET_EXPIRY=""
                    save_conf
                    write_expiry_cron
                    echo "Removed - no more warning before the secret expires."
                fi
                ;;
            4)  return ;;
            *)  ;;
        esac
    done
}

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
            echo "Secret:   $(expiry_text)"
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Set up / edit credentials"
        echo "2) Send a test mail"
        echo "3) Check the token"
        echo "4) Secret expiry (date, warning, test the warning)"
        echo "5) Show status"
        echo "6) $(sendmail_active && echo "Switch off" || echo "Switch on") the sendmail integration"
        echo "7) Show the log"
        echo "8) Uninstall"
        echo "9) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) send_test ;;
            3) check_token ;;
            4) expiry_menu ;;
            5) show_status; pause ;;
            6) if sendmail_active; then disable_sendmail; else enable_sendmail || true; fi; pause ;;
            7) show_log ;;
            8) uninstall ;;
            9) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --sendmail)  shift; sendmail_mode "$@" ;;
    --test)      [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; send_test ;;
    --status)    show_status ;;
    --check-expiry) check_expiry ;;
    --uninstall) [[ $EUID -eq 0 ]] || { echo "Please run as root." >&2; exit 1; }; uninstall ;;
    "")          [[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)." >&2; exit 1; }
                 is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--sendmail ...|--test|--status|--check-expiry|--uninstall|--version]"; exit 1 ;;
esac
