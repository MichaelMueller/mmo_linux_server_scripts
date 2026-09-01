#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# hostname-setup.sh - set the hostname, typed or generated from the date
# Modes: (no argument) = interactive menu
#        --status      = current names on stdout
#
# There is no --uninstall: a hostname cannot be "removed", only replaced. The
# previous value is in the backup that every change writes.
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.4.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

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

set_typed() {
    local h d
    read -rp "New hostname (short, without a domain): " h
    while ! valid_hostname "$h"; do
        echo "  -> letters, digits and hyphens; not starting or ending with a hyphen."
        read -rp "New hostname: " h
    done
    read -rp "Domain for the FQDN (optional, e.g. example.com): " d
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
    read -rp "Domain for the FQDN (optional, e.g. example.com): " d
    apply_hostname "$h" "$d"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Hostname"
        echo "==========================================="
        show_status
        echo
        echo "1) Set a hostname (typed)"
        echo "2) Generate a hostname from the date and set it"
        echo "3) Quit"
        read -rp "Choice: " CH
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
    "")       main_menu ;;
    *)        echo "Usage: $0 [--status|--version]"; exit 1 ;;
esac
