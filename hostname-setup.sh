#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# hostname-setup.sh - set the hostname, typed or generated from the date
# Modes: (no argument)  = interactive menu
#        --status       = current names on stdout
#        --set <hostname> [domain]
#                       = set the hostname (and the FQDN <hostname>.<domain>
#                         in /etc/hosts) without questions
# Presets from a caller: a DEFAULT_* that is set (not empty) is taken without
# a question and printed with "(preset)"; an invalid one is an error. Unset
# ones are asked (batch mode: built-in default).
#   DEFAULT_HOSTNAME   the hostname: menu item 1 asks no name; --set uses it
#                      when none is given
#   DEFAULT_DOMAIN     domain for the FQDN ('-' = none): the menu asks no
#                      domain; --set uses it when no domain is given
# Batch mode: BATCH=1 asks nothing - every question takes its default and
# prints what it took; --set always runs that way.
#
# There is no --uninstall: a hostname cannot be "removed", only replaced. The
# previous value is in the backup that every change writes.
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# Presets: a DEFAULT_* that is set (not empty) is a fixed value - its
# question is not asked, neither interactively nor in batch mode; the tool
# prints "<question>: <value> (preset)" instead. Unset ones are asked.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# without a preset takes its built-in default and prints what it took. A
# required value without a default is an error.

# preset NAME -> 0 when the caller set that DEFAULT_* (non-empty)
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# yn_value VALUE -> Y or N; failure for anything that is not yes/no
yn_value() {
    local v=${1:-}
    case "${v,,}" in
        y|yes|j|ja|1|true)  echo Y ;;
        n|no|nein|0|false)  echo N ;;
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
# ask VAR "Question" [default] [required] [DEFAULT_NAME]  - the answer lands in VAR
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
        [[ -n "$__a" || -z "$__r" ]] && break
        echo "  -> required"
    done
    printf -v "$__v" '%s' "$__a"
}

cur_short() { hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"; }
cur_fqdn()  { hostname -f 2>/dev/null || cur_short; }

show_status() {
    echo "Hostname: $(cur_short)"
    echo "FQDN:     $(cur_fqdn)"
    if command -v hostnamectl &>/dev/null; then
        local p
        p=$(hostnamectl status 2>/dev/null | awk -F': ' '/Pretty hostname/ {print $2}') || true
        [[ -n "${p:-}" ]] && echo "Pretty:   $p"
    fi
    echo "/etc/hostname: $(cat /etc/hostname 2>/dev/null || echo '(missing)')"
}

# ---------------------------------------------------------------------------
# Validation and generation
# ---------------------------------------------------------------------------
# RFC 1123: letters, digits and hyphens, not starting or ending with a hyphen,
# at most 63 characters per label. Underscores are the classic mistake - they
# are valid in DNS records but not in hostnames, and some tools reject them
# only much later, in a place that gives no hint where the problem came from.
valid_hostname() {
    local h=$1
    [[ ${#h} -ge 1 && ${#h} -le 63 ]] || return 1
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

# A domain is dot-separated labels, each one valid like a hostname.
valid_domain() {
    local d=$1 l
    [[ "$d" =~ ^[a-zA-Z0-9.-]+$ && ${#d} -le 253 && "$d" != *. && "$d" != *..* ]] || return 1
    for l in ${d//./ }; do valid_hostname "$l" || return 1; done
}

# <prefix>-yymmdd-hhmm, e.g. srv-260815-1432. Sorts chronologically as a plain
# string, which is the whole point of putting the date in a name.
gen_hostname() {
    local prefix=$1
    printf '%s-%s' "$prefix" "$(date +%y%m%d-%H%M)"
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------
# /etc/hosts matters as much as the hostname itself: without a line resolving
# the new name, every 'sudo' waits for a DNS timeout first, and programs that
# look up their own name (mailers above all) hang or fail. Debian keeps that
# line at 127.0.1.1 - deliberately not 127.0.0.1, so that the machine's own
# name does not collide with localhost.
update_hosts() {
    local old=$1 new=$2 domain=$3 line
    [[ -f /etc/hosts ]] || return 0

    if [[ -n "$domain" ]]; then
        line="127.0.1.1	${new}.${domain} ${new}"
    else
        line="127.0.1.1	${new}"
    fi

    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        # Only the 127.0.1.1 line is touched. Other entries in /etc/hosts can
        # be anything at all and are none of this tool's business.
        sed -i "s|^127\.0\.1\.1[[:space:]].*|${line}|" /etc/hosts
    else
        # After the localhost line, so the file keeps its usual shape.
        if grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
            sed -i "0,/^127\.0\.0\.1[[:space:]].*/s||&\n${line}|" /etc/hosts
        else
            printf '%s\n' "$line" >> /etc/hosts
        fi
    fi
    echo "  /etc/hosts: ${line}"
}

apply_hostname() {
    local new=$1 domain=$2
    local old; old=$(cur_short)

    if [[ "$new" == "$old" ]]; then
        echo "The hostname is already '${new}' - nothing to do."
        pause; return
    fi

    echo
    echo "Old: ${old}"
    echo "New: ${new}${domain:+ (FQDN ${new}.${domain})}"
    echo
    echo "What this affects: the prompt, mail subjects and log lines of the"
    echo "monitoring tools, and anything that identifies this machine by name."
    echo "Existing SSH connections keep running; a monitoring system that keys"
    echo "on the name will see a new host."
    echo
    confirm "Change it now?" Y || { echo "Cancelled."; pause; return; }

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -a /etc/hostname "/etc/hostname.bak-${ts}" 2>/dev/null || true
    cp -a /etc/hosts    "/etc/hosts.bak-${ts}"    2>/dev/null || true
    echo "Backup: /etc/hostname.bak-${ts}, /etc/hosts.bak-${ts}"

    if command -v hostnamectl &>/dev/null; then
        hostnamectl set-hostname "$new"
    else
        # Without systemd: write the file and set the running name, which is
        # exactly what hostnamectl does.
        printf '%s\n' "$new" > /etc/hostname
        hostname "$new"
    fi
    echo "  hostname: ${new}"

    update_hosts "$old" "$new" "$domain"

    echo
    echo "Done. Current state:"
    show_status
    echo
    echo "The shell prompt of THIS session still shows the old name - it was"
    echo "set when the session started. A new login shows the new one."
    pause
}

# Asks for the domain part of the FQDN, with an explanation of what it does.
# Prints the answer on stdout; the explanation goes to stderr.
ask_domain() {
    local h=$1 d
    # A preset needs no explanation - it is not asked.
    preset DEFAULT_DOMAIN || {
        echo
        echo "Domain for the FQDN (optional): together with the hostname it forms"
        echo "the full name, e.g. ${h}.example.com. It is only written to /etc/hosts"
        echo "(so 'hostname -f' shows it) and appears in the subject and sender of"
        echo "the alert and update mails. It does NOT create a DNS record - set one"
        echo "at the DNS provider if the name should resolve from outside."
        echo "Use a domain you or the customer control (the company or the"
        echo "customer's domain), not the website's own name. One domain, no"
        echo "leading dot. Empty = no domain, the FQDN is then just the hostname."
        echo "  e.g. 'example.com'  ->  ${h}.example.com"
    } >&2
    # ask's batch line goes to stderr too: stdout is the answer.
    ask d "Domain for the FQDN" "${DEFAULT_DOMAIN:-}" "" DEFAULT_DOMAIN >&2 || return 1
    [[ "$d" == "-" ]] && d=""
    d=${d#.}
    if preset DEFAULT_DOMAIN && [[ -n "$d" ]] && ! valid_domain "$d"; then
        echo "!!! DEFAULT_DOMAIN='${DEFAULT_DOMAIN}' is not a valid domain (e.g. example.com)." >&2
        return 1
    fi
    printf '%s' "$d"
}

set_typed() {
    local h d
    if preset DEFAULT_HOSTNAME; then
        h=$DEFAULT_HOSTNAME
        echo "New hostname (short, without a domain): ${h} (preset)"
        if ! valid_hostname "$h"; then
            echo "!!! DEFAULT_HOSTNAME='${h}' is not a valid hostname: letters, digits and" >&2
            echo "!!! hyphens; not starting or ending with a hyphen; at most 63 characters." >&2
            exit 1
        fi
    else
        read -rp "New hostname (short, without a domain): " h
        while ! valid_hostname "$h"; do
            echo "  -> letters, digits and hyphens; not starting or ending with a hyphen."
            read -rp "New hostname: " h
        done
    fi
    d=$(ask_domain "$h") || exit 1
    apply_hostname "$h" "$d"
}

set_generated() {
    local p h d
    echo "The name is built as <prefix>-yymmdd-hhmm, so it sorts by date on"
    echo "its own - handy where machines are created and thrown away often."
    echo
    read -rp "Prefix [srv]: " p; p=${p:-srv}
    while ! valid_hostname "$p"; do
        echo "  -> letters, digits and hyphens; not starting or ending with a hyphen."
        read -rp "Prefix [srv]: " p; p=${p:-srv}
    done

    h=$(gen_hostname "$p")
    if ! valid_hostname "$h"; then
        echo "!!! '${h}' is not a valid hostname - pick a shorter prefix."
        pause; return
    fi

    echo
    echo "Suggestion: ${h}"
    echo
    d=$(ask_domain "$h") || exit 1
    apply_hostname "$h" "$d"
}

# --set <hostname> [domain]: no questions, for callers such as base-setup.sh.
# The same validation and the same apply path as the menu.
set_given() {
    BATCH=1
    local h=${1:-${DEFAULT_HOSTNAME:-}} d
    if (( $# >= 2 )); then d=$2; else d=${DEFAULT_DOMAIN:-}; fi
    [[ "$d" == "-" ]] && d=""
    d=${d#.}
    if [[ -z "$h" ]]; then
        echo "!!! No hostname given (--set <hostname> [domain] or DEFAULT_HOSTNAME)." >&2
        return 1
    fi
    if ! valid_hostname "$h"; then
        echo "!!! '${h}' is not a valid hostname: letters, digits and hyphens;" >&2
        echo "!!! not starting or ending with a hyphen; at most 63 characters." >&2
        return 1
    fi
    if [[ -n "$d" ]] && ! valid_domain "$d"; then
        echo "!!! '${d}' is not a valid domain (e.g. example.com)." >&2
        return 1
    fi
    apply_hostname "$h" "$d"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Hostname"
        echo "==========================================="
        show_status
        echo
        echo "1) Set a hostname (typed)"
        echo "2) Generate a hostname from the date and set it"
        echo "3) Quit"
        read -rp "Choice: " CH || exit 0
        case "$CH" in
            1) set_typed ;;
            2) set_generated ;;
            3) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status) show_status ;;
    --set)    shift; set_given "$@" ;;
    "")       main_menu ;;
    *)        echo "Usage: $0 [--status|--set <hostname> [domain]|--version]"; exit 1 ;;
esac
