#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# mail-setup.sh - mail delivery for the server: SMTP via msmtp, or hand over
#                 to graph-mailer.sh (Microsoft 365 via Graph API)
# Modes: (no argument) = interactive menu
#        --setup       = choose the way (SMTP or Graph) and set it up
#        --setup-smtp  = set up SMTP (msmtp) directly
#        --test        = send a test mail
#        --uninstall   = uninstall msmtp configuration
# Presets from a caller: a DEFAULT_* that is set (not empty) is taken without
# a question - it wins over a value already in /etc/msmtprc or /etc/aliases;
# an invalid one is an error. Unset ones are asked (batch mode: default).
#   DEFAULT_MAILER          smtp|graph|keep    (skips the menu; default: graph if set up, else smtp)
#   DEFAULT_SMTP_HOST       SMTP server        (no default - required)
#   DEFAULT_SMTP_TLS        starttls|tls|none  (or 1|2|3; default starttls)
#   DEFAULT_SMTP_PORT       port               (default 587/465/25 by DEFAULT_SMTP_TLS)
#   DEFAULT_SMTP_AUTH       Y|N authentication (default Y)
#   DEFAULT_SMTP_USER       username           (required when DEFAULT_SMTP_AUTH=Y)
#   DEFAULT_MAIL_FROM       sender address     (required)
#   DEFAULT_ROOT_RCPT       root alias         (optional; also the test recipient)
#   DEFAULT_SMTP_TLS_CHECK  Y|N certificate check (default Y)
#   DEFAULT_TEST_MAIL       Y|N send a test mail at the end (default Y)
# Secret from the environment: SMTP_PASSWORD (never on a command line).
# graph-mailer.sh reads its own DEFAULT_* values and GRAPH_CLIENT_SECRET.
# Batch mode: BATCH=1 - no questions, every one without a preset takes its
# default and prints it; a required value without a default is an error. A
# password already in /etc/msmtprc is kept when SMTP_PASSWORD is not set.
# Exit status (--setup): 0 done, 2 left as it is (DEFAULT_MAILER=keep, or
# '-' at a required value),
# 1 error (in batch mode also: the test mail failed - the config is saved).
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Started from a version directory (<base>/<version>/, see build-bundle.sh):
# paths written into cron and systemd go through <base>/current, so an update
# or a rollback switches them along.
if [[ -L "$DIR/../current" && "$(readlink -f "$DIR/../current")" == "$(readlink -f "$DIR")" ]]; then
    DIR="$(cd "$DIR/../current" && pwd)"
fi
GRAPH_SCRIPT="$DIR/graph-mailer.sh"
MSMTPRC=/etc/msmtprc
ALIASES=/etc/aliases
LOGFILE=/var/log/msmtp.log

pause() {
    if [[ -n "${BATCH:-}" ]]; then return 0; fi
    read -rp "Press Enter to continue..." _
}

# Presets: a DEFAULT_* that is set (not empty) is a fixed value - its question
# is not asked, one line "<question>: <value> (preset)" is printed instead.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# without a preset takes its built-in default and prints what it took. A
# required value without a default is an error.
# preset NAME -> 0 when the caller set the variable NAME (non-empty)
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# yn_value VALUE -> prints Y or N; fails for anything that is not yes/no
yn_value() {
    case "${1:-}" in
        [YyJj]|[Yy]es|YES|[Jj]a|JA|1|[Tt]rue|TRUE)    echo Y ;;
        [Nn]|[Nn]o|NO|[Nn]ein|NEIN|0|[Ff]alse|FALSE) echo N ;;
        *) return 1 ;;
    esac
}
# confirm "Question" [default Y|N] [DEFAULT_NAME]
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (preset ${pre})" >&2; exit 1; }
        echo "$q -> $( [[ "$def" == Y ]] && echo yes || echo no) (preset)"
        [[ "$def" == Y ]]; return
    fi
    if [[ -n "${BATCH:-}" ]]; then
        echo "$q -> $( [[ "$def" =~ ^[YyJj]$ ]] && echo yes || echo no)"
        [[ "$def" =~ ^[YyJj]$ ]]; return
    fi
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}
# ask VAR "Question" [default] [required] [DEFAULT_NAME] - the answer lands in VAR
ask() {
    local __v=$1 __q=$2 __d=${3:-} __r=${4:-} __p=${5:-} __a
    if preset "$__p"; then
        printf -v "$__v" '%s' "${!__p}"; echo "${__q}: ${!__p} (preset)"; return 0
    fi
    if [[ -n "${BATCH:-}" ]]; then
        if [[ -z "$__d" && -n "$__r" ]]; then echo "!!! ${__q}: no value given (batch mode)" >&2; return 1; fi
        printf -v "$__v" '%s' "$__d"; echo "${__q}: ${__d:--}"; return 0
    fi
    while true; do
        read -rp "${__q}${__d:+ [${__d}]}: " __a || return 1
        __a=${__a:-$__d}
        # a required value: '-' cancels the whole setup (exit status 2)
        if [[ -n "$__r" && "$__a" == "-" ]]; then echo "Cancelled - the configuration was not changed."; return 2; fi
        [[ -n "$__a" || -z "$__r" ]] && break
        echo "  -> required ('-' cancels)"
    done
    printf -v "$__v" '%s' "$__a"
}
# ask_secret VAR "Question" ENVNAME - from the environment variable ENVNAME if
# set, else asked hidden; in batch mode a missing secret is an error.
ask_secret() {
    local __v=$1 __q=$2 __e=$3 __a
    if [[ -n "${!__e:-}" ]]; then printf -v "$__v" '%s' "${!__e}"; echo "${__q}: (from \$${__e})"; return 0; fi
    if [[ -n "${BATCH:-}" ]]; then echo "!!! ${__q}: \$${__e} not set (batch mode)" >&2; return 1; fi
    read -rsp "${__q}: " __a; echo
    printf -v "$__v" '%s' "$__a"
}
# yn NAME VALUE BUILTIN -> prints Y or N (VALUE, or BUILTIN when empty);
# anything else is an error naming the variable NAME.
yn() {
    yn_value "${2:-$3}" || { echo "!!! ${1}=${2}: expected Y or N" >&2; return 1; }
}

# make_backup <name> <path>...   -> /root/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nothing to back up)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

is_setup() { [[ -f "$MSMTPRC" ]] && grep -q '^account ' "$MSMTPRC"; }

get_val() { grep -m1 "^${1} " "$MSMTPRC" 2>/dev/null | awk '{print $2}' || true; }

install_pkgs() {
    if ! command -v msmtp &>/dev/null; then
        echo ">>> Installing msmtp, msmtp-mta, bsd-mailx..."
        apt-get update -qq </dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp msmtp-mta bsd-mailx </dev/null >/dev/null
    fi
    if ! command -v mail &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bsd-mailx </dev/null >/dev/null
    fi
}

configure() {
    # DEFAULT_* values from the caller, checked before anything is installed,
    # asked or written - an invalid one is an error.
    local def_enc def_auth def_cert def_test
    case "${DEFAULT_SMTP_TLS:-1}" in
        1|starttls|STARTTLS)             def_enc=1 ;;
        2|tls|TLS|ssl|SSL)               def_enc=2 ;;
        3|none|off|plain|unencrypted)    def_enc=3 ;;
        *) echo "!!! DEFAULT_SMTP_TLS=${DEFAULT_SMTP_TLS}: expected starttls, tls or none" >&2; return 1 ;;
    esac
    def_auth=$(yn DEFAULT_SMTP_AUTH "${DEFAULT_SMTP_AUTH:-}" Y)           || return 1
    def_cert=$(yn DEFAULT_SMTP_TLS_CHECK "${DEFAULT_SMTP_TLS_CHECK:-}" Y) || return 1
    def_test=$(yn DEFAULT_TEST_MAIL "${DEFAULT_TEST_MAIL:-}" Y)           || return 1
    if preset DEFAULT_SMTP_PORT && ! [[ "$DEFAULT_SMTP_PORT" =~ ^[0-9]+$ ]]; then
        echo "!!! DEFAULT_SMTP_PORT=${DEFAULT_SMTP_PORT}: not a number" >&2; return 1
    fi

    install_pkgs

    # Values already stored are the defaults of the questions; a preset
    # (DEFAULT_* set) wins over them. The password is never handed over.
    local cur_host="" cur_port="" cur_user="" cur_from="" cur_rcpt=""
    if is_setup; then
        cur_host=$(get_val host)
        cur_port=$(get_val port)
        cur_user=$(get_val user)
        cur_from=$(get_val from)
        cur_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || true)
    fi

    echo "--- SMTP parameters ---"
    local SMTP_HOST SMTP_PORT ENC NEEDAUTH MAIL_FROM ROOT_RCPT CERTCHECK
    ask SMTP_HOST "SMTP server" "${cur_host:-}" required DEFAULT_SMTP_HOST || return $?

    echo
    if preset DEFAULT_SMTP_TLS; then
        ENC=$def_enc
        echo "Encryption: ${DEFAULT_SMTP_TLS} (preset)"
    else
        echo "Encryption:"
        echo "  1) STARTTLS  (port 587, the usual one)"
        echo "  2) TLS/SSL   (port 465, implicit)"
        echo "  3) unencrypted (port 25, internal network only)"
        ask ENC "Choice" "$def_enc"
    fi

    local DEF_PORT TLS_ON STARTTLS_ON
    case "$ENC" in
        2) DEF_PORT=465; TLS_ON=on;  STARTTLS_ON=off ;;
        3) DEF_PORT=25;  TLS_ON=off; STARTTLS_ON=off ;;
        *) DEF_PORT=587; TLS_ON=on;  STARTTLS_ON=on  ;;
    esac

    ask SMTP_PORT "Port" "${cur_port:-$DEF_PORT}" "" DEFAULT_SMTP_PORT
    if [[ -n "${BATCH:-}" ]] && ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]]; then
        echo "!!! Port '${SMTP_PORT}' is not a number" >&2; return 1
    fi

    if confirm "Authentication needed?" "$def_auth" DEFAULT_SMTP_AUTH; then NEEDAUTH=Y; else NEEDAUTH=N; fi

    local SMTP_USER="" SMTP_PASS="" old_pass=""
    if [[ "$NEEDAUTH" == Y ]]; then
        ask SMTP_USER "Username" "${cur_user:-}" required DEFAULT_SMTP_USER || return $?

        if is_setup; then
            old_pass=$(sed -n 's/^password[[:space:]]*//p' "$MSMTPRC" | head -n1)
        fi
        if [[ -n "${BATCH:-}" && -z "${SMTP_PASSWORD:-}" && -n "$old_pass" ]]; then
            echo "Password: (keeping the existing one)"
            SMTP_PASS=$old_pass
        else
            ask_secret SMTP_PASS "Password (empty = keep the existing one)" SMTP_PASSWORD
        fi
        if [[ -z "$SMTP_PASS" ]]; then SMTP_PASS=$old_pass; fi
        while [[ -z "$SMTP_PASS" ]]; do
            read -rsp "  -> required ('-' cancels): " SMTP_PASS || return 1; echo
            [[ "$SMTP_PASS" == "-" ]] && { echo "Cancelled - the configuration was not changed."; return 2; }
        done
    fi

    ask MAIL_FROM "Sender address (From)" "${cur_from:-}" required DEFAULT_MAIL_FROM || return $?

    ask ROOT_RCPT "Default recipient for system/root mail" "${cur_rcpt:-}" "" DEFAULT_ROOT_RCPT

    if confirm "Check the server certificate?" "$def_cert" DEFAULT_SMTP_TLS_CHECK; then CERTCHECK=Y; else CERTCHECK=N; fi

    umask 077
    {
        echo "# msmtp - generated by mail-setup.sh on $(date '+%F %T')"
        echo "defaults"
        echo "auth           $([[ "$NEEDAUTH" =~ ^[YyJj]$ ]] && echo on || echo off)"
        echo "tls            ${TLS_ON}"
        echo "tls_starttls   ${STARTTLS_ON}"
        if [[ "$CERTCHECK" =~ ^[YyJj]$ ]]; then
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
        if [[ "$NEEDAUTH" =~ ^[YyJj]$ ]]; then
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
    echo "Configuration written to $MSMTPRC (chmod 600)."
    echo "Careful: the password sits there in clear text, readable only by root."
    echo

    if confirm "Send a test mail now?" "$def_test" DEFAULT_TEST_MAIL; then send_test; else pause; fi
}

# In batch mode a failed test mail returns 1; interactively it always returns
# 0 (the menu runs under set -e).
send_test() {
    if ! is_setup; then
        echo "Not set up yet."; pause
        if [[ -n "${BATCH:-}" ]]; then return 1; fi
        return 0
    fi

    local from default_rcpt RCPT rc=0
    from=$(get_val from)
    default_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || true)
    default_rcpt=${default_rcpt:-$from}

    # DEFAULT_ROOT_RCPT is also the test recipient
    ask RCPT "Recipient" "$default_rcpt" required DEFAULT_ROOT_RCPT

    echo ">>> Sending a test mail to $RCPT ..."
    if printf 'Subject: Test mail from %s\nFrom: %s\nTo: %s\n\nSMTP sending works.\nHost: %s\nTime: %s\n' \
        "$(hostname -f 2>/dev/null || hostname)" "$from" "$RCPT" "$(hostname)" "$(date '+%F %T')" \
        | msmtp --read-envelope-from -- "$RCPT" 2>&1; then
        echo ">>> Handed over successfully."
    else
        rc=1
        echo "!!! Failed. Last log lines:"
        tail -n 10 "$LOGFILE" 2>/dev/null || true
        if [[ -n "${BATCH:-}" ]]; then
            echo "!!! Test mail failed - the configuration is saved, check it with: $0 --test" >&2
        fi
    fi
    pause
    if [[ -n "${BATCH:-}" ]]; then return "$rc"; fi
    return 0
}

show_config() {
    is_setup || { echo "Not set up."; pause; return; }
    echo "--- $MSMTPRC (password masked) ---"
    sed 's/^password .*/password       ********/' "$MSMTPRC"
    echo
    echo "--- root alias ---"
    grep '^root:' "$ALIASES" 2>/dev/null || echo "(not set)"
    echo
    echo "--- sendmail binary ---"
    ls -l /usr/sbin/sendmail 2>/dev/null || echo "(not present)"
    pause
}

show_log() {
    [[ -f "$LOGFILE" ]] || { echo "There is no log."; pause; return; }
    tail -n 40 "$LOGFILE"
    pause
}

uninstall() {
    echo ">>> Uninstall SMTP mailer"
    echo

    local cur_rcpt
    cur_rcpt=$(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || true)

    echo "The following will be removed:"
    [[ -f "$MSMTPRC" ]]  && echo "  - configuration $MSMTPRC (including the SMTP password)" || true
    [[ -n "$cur_rcpt" ]] && echo "  - root alias in $ALIASES  (root: $cur_rcpt)   [asked]" || true
    [[ -f "$LOGFILE" ]]  && echo "  - send log $LOGFILE                           [asked]" || true
    echo
    echo "The packages stay installed. To remove them manually:"
    echo "    apt purge msmtp msmtp-mta bsd-mailx"
    echo "  (that also removes /usr/sbin/sendmail - cron and system mail then fail silently)"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup mail-setup "$MSMTPRC" "$ALIASES" "$LOGFILE" || { pause; return; }

    rm -f "$MSMTPRC"

    if [[ -n "$cur_rcpt" ]] && confirm "Remove the root alias ($cur_rcpt) from $ALIASES?" Y; then
        sed -i '/^root:/d' "$ALIASES"
        command -v newaliases &>/dev/null && newaliases 2>/dev/null || true
    fi

    if [[ -f "$LOGFILE" ]] && confirm "Delete the send log $LOGFILE?"; then
        rm -f "$LOGFILE"
    fi

    echo
    echo "Removed. Without $MSMTPRC sending fails - services that use 'mail'"
    echo "(tcp-monitor, auto-update) then only write to their log."
    pause
}

current_mailer() {
    if [[ -f /etc/graph-mailer.conf ]]; then echo graph
    elif is_setup; then echo smtp
    fi
    return 0
}

# Choose the way mail leaves this server, then set it up.
choose_mailer() {
    # A preset DEFAULT_MAILER is checked first and skips the menu.
    case "${DEFAULT_MAILER:-}" in
        ""|smtp|keep) ;;
        graph) [[ -x "$GRAPH_SCRIPT" ]] || { echo "!!! DEFAULT_MAILER=graph, but $GRAPH_SCRIPT is missing" >&2; return 1; } ;;
        *) echo "!!! DEFAULT_MAILER=${DEFAULT_MAILER}: expected smtp, graph or keep" >&2; return 1 ;;
    esac
    echo ">>> Mail delivery"
    echo "Alerts and update reports go out through this channel - without it,"
    echo "failures go unnoticed."
    local cur; cur=$(current_mailer)
    [[ -n "$cur" ]] && echo "Currently set up: ${cur}"
    local def=1 c=""
    if preset DEFAULT_MAILER; then
        case "$DEFAULT_MAILER" in smtp) c=1 ;; graph) c=2 ;; keep) c=3 ;; esac
        echo "Mail delivery: ${DEFAULT_MAILER} (preset)"
    else
        echo "  1) SMTP account (msmtp)          - classic mailbox / relay"
        [[ -x "$GRAPH_SCRIPT" ]] && \
        echo "  2) Microsoft 365 via Graph API   - when SMTP AUTH is blocked"
        echo "  3) leave it as it is - nothing is changed"
        [[ "$cur" == graph ]] && [[ -x "$GRAPH_SCRIPT" ]] && def=2
        ask c "Choice" "$def"
    fi
    case "${c:-$def}" in
        1) configure ;;
        2) if [[ -x "$GRAPH_SCRIPT" ]]; then "$GRAPH_SCRIPT" --setup; else configure; fi ;;
        *) echo "Left as it is, nothing changed."; return 2 ;;
    esac
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " SMTP mailer (msmtp)"
        echo "==========================================="
        if is_setup; then
            echo "Status:   set up"
            echo "Server:   $(get_val host):$(get_val port)"
            echo "Sender:   $(get_val from)"
            echo "Recipient (root alias): $(awk '/^root:/ {print $2}' "$ALIASES" 2>/dev/null || echo '-')"
        else
            echo "Status: not set up"
        fi
        echo
        echo "0) Choose the way: SMTP or Microsoft 365 (Graph)"
        echo "1) Set up / edit SMTP parameters"
        echo "2) Send a test mail"
        echo "3) Show the configuration"
        echo "4) Show the send log"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH || exit 0
        case "$CH" in
            0) choose_mailer || true ;;
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
    --setup)     choose_mailer ;;
    --setup-smtp) configure ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--setup|--setup-smtp|--test|--uninstall|--version]"; exit 1 ;;
esac
