#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# fail2ban-setup.sh - fail2ban: ban hosts after repeated failed attempts
# Modes: (no argument) = interactive menu
#        --status      = jails and bans on stdout
#        --uninstall   = uninstall
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.4.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$DIR/fail2ban-setup.conf"

F2B_DIR=/etc/fail2ban
JAIL_DIR="$F2B_DIR/jail.d"
FILTER_DIR="$F2B_DIR/filter.d"
# Everything this tool writes carries the '-mmo' suffix or lives in one of the
# three files below: jail.conf and jail.local are never touched, so a package
# update and a hand-written jail of your own both stay untouched.
DEFAULTS_FILE="$JAIL_DIR/00-mmo-defaults.local"
CADDY_FILTER="$FILTER_DIR/caddy-mmo.conf"

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
BANTIME="1h"
FINDTIME="10m"
MAXRETRY=5
IGNOREIP="127.0.0.1/8 ::1"
BANACTION=""              # empty = leave fail2ban's own default alone
BACKEND="systemd"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# The tailnet is the way back in when a rule locks you out, so it belongs in
# ignoreip - and it is not covered by anything else, because Tailscale hands
# out CGNAT addresses.
TAILNET_CIDR="100.64.0.0/10"

# The jails this tool knows. nginx is deliberately absent: the nginx in this
# repo (nginx-manager.sh) is a pure TCP relay that passes TLS through, so it
# never sees an HTTP request and has nothing to match on.
JAILS="sshd recidive caddy"

pause() { read -rp "Press Enter to continue..." _; }

# confirm "Question" [Y]   -> default Y instead of N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
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

save_conf() {
    cat > "$CONF" <<EOF
# fail2ban-setup configuration
BANTIME="${BANTIME}"
FINDTIME="${FINDTIME}"
MAXRETRY=${MAXRETRY}
IGNOREIP="${IGNOREIP}"
BANACTION="${BANACTION}"
BACKEND="${BACKEND}"
EOF
    chmod 644 "$CONF"
}

is_setup() { [[ -f "$DEFAULTS_FILE" ]]; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# The port the SSH daemon really listens on. With a moved port and a jail that
# still says 'ssh', the ban rule blocks port 22 while the attacker keeps
# knocking on 2222 - the jail looks busy and stops nothing.
ssh_port() {
    local p=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    fi
    if [[ -z "$p" ]] && command -v sshd &>/dev/null; then
        p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}' || true)
    fi
    echo "${p:-22}"
}

ufw_active() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"
}

f2b_running() { systemctl is-active --quiet fail2ban 2>/dev/null; }

# Debian 12 stopped installing a syslog daemon, so /var/log/auth.log often does
# not exist at all and the packaged 'backend = auto' then matches nothing -
# quietly, which is the whole problem: an empty jail looks exactly like a quiet
# server. Hence the systemd backend, which reads the journal directly.
suggest_backend() {
    [[ -s /var/log/auth.log ]] && echo "auto" || echo "systemd"
}

# The systemd backend needs the python binding, and the Debian package only
# recommends it - without it fail2ban starts and every jail dies with
# "No module named 'systemd'".
have_pysystemd() {
    python3 -c 'import systemd.journal' >/dev/null 2>&1
}

install_pkgs() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo ">>> Installing fail2ban..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y fail2ban >/dev/null
    fi
    if [[ "$BACKEND" == "systemd" ]] && ! have_pysystemd; then
        echo ">>> Installing python3-systemd (the systemd backend needs it)..."
        DEBIAN_FRONTEND=noninteractive apt install -y python3-systemd >/dev/null || true
        have_pysystemd || echo "!!! python3-systemd is still missing - jails will fail to start."
    fi
}

reload_f2b() {
    systemctl enable fail2ban >/dev/null 2>&1 || true
    if systemctl restart fail2ban 2>/dev/null; then
        # The daemon starts even when a jail is broken; the failure only shows
        # in its log, so a plain "restarted" would be a false all-clear.
        sleep 1
        if f2b_running; then
            return 0
        fi
    fi
    echo "!!! fail2ban did not come up:"
    journalctl -u fail2ban -n 15 --no-pager 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Jail files
# ---------------------------------------------------------------------------
# jail_file <jail>
jail_file() { printf '%s/%s-mmo.local\n' "$JAIL_DIR" "$1"; }

# jail_val <jail> <key> [default]
jail_val() {
    local f v
    f=$(jail_file "$1")
    [[ -f "$f" ]] || { printf '%s' "${3:-}"; return 0; }
    v=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$f" | head -1)
    printf '%s' "${v:-${3:-}}"
}

jail_on() { [[ "$(jail_val "$1" enabled false)" == "true" ]]; }

write_defaults() {
    mkdir -p "$JAIL_DIR"
    {
        echo "# written by fail2ban-setup.sh - do not edit by hand, it is rewritten"
        echo "[DEFAULT]"
        echo "bantime  = ${BANTIME}"
        echo "findtime = ${FINDTIME}"
        echo "maxretry = ${MAXRETRY}"
        echo "ignoreip = ${IGNOREIP}"
        # Only written when we actually know better than the distribution:
        # Debian 13 defaults to nftables, Debian 12 to iptables, and either is
        # right on its own system. With ufw in front, its own action is the one
        # that keeps the rules in one place.
        [[ -n "$BANACTION" ]] && echo "banaction = ${BANACTION}"
    } > "$DEFAULTS_FILE"
    chmod 644 "$DEFAULTS_FILE"
}

write_jail_sshd() {
    local retry=$1 find=$2 ban=$3 port
    port=$(ssh_port)
    {
        echo "# written by fail2ban-setup.sh"
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ${port}"
        echo "backend  = ${BACKEND}"
        # No logpath on purpose: with the systemd backend a logpath makes
        # fail2ban read a file instead of the journal, and on a Debian without
        # syslog that file is empty or missing.
        echo "maxretry = ${retry}"
        echo "findtime = ${find}"
        echo "bantime  = ${ban}"
    } > "$(jail_file sshd)"
}

# Bans whoever keeps coming back after their ban expires. It feeds on
# fail2ban's own log, so it needs no filter of ours.
write_jail_recidive() {
    local retry=$1 find=$2 ban=$3
    {
        echo "# written by fail2ban-setup.sh"
        echo "[recidive]"
        echo "enabled  = true"
        echo "logpath  = /var/log/fail2ban.log"
        echo "backend  = auto"
        echo "maxretry = ${retry}"
        echo "findtime = ${find}"
        echo "bantime  = ${ban}"
    } > "$(jail_file recidive)"
}

# fail2ban ships no filter for Caddy, and Caddy writes JSON. This one matches
# the access log that caddy-manager.sh configures: a 401 is a failed basic auth,
# a 403 is our own access restriction turning someone away.
write_caddy_filter() {
    mkdir -p "$FILTER_DIR"
    cat > "$CADDY_FILTER" <<'EOF'
# written by fail2ban-setup.sh
# Caddy writes its access log as one JSON object per line. This matches the
# client address of requests answered with 401 (failed basic auth) or 403
# (turned away by an access restriction).
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403).*$
ignoreregex =
# Caddy's "ts" is a UNIX timestamp with a fraction, not a formatted date.
datepattern = {EPOCH}
EOF
    chmod 644 "$CADDY_FILTER"
}

write_jail_caddy() {
    local retry=$1 find=$2 ban=$3
    write_caddy_filter
    {
        echo "# written by fail2ban-setup.sh"
        echo "[caddy-mmo]"
        echo "enabled  = true"
        echo "filter   = caddy-mmo"
        echo "port     = http,https"
        echo "logpath  = /var/log/caddy/*.log"
        echo "backend  = auto"
        echo "maxretry = ${retry}"
        echo "findtime = ${find}"
        echo "bantime  = ${ban}"
    } > "$(jail_file caddy)"
}

# The name fail2ban knows a jail by is not always our file name.
jail_section() {
    case "$1" in
        caddy) echo "caddy-mmo" ;;
        *)     echo "$1" ;;
    esac
}

jail_purpose() {
    case "$1" in
        sshd)     echo "failed SSH logins" ;;
        recidive) echo "repeat offenders (banned again after their ban expired)" ;;
        caddy)    echo "401/403 in Caddy's access log" ;;
    esac
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo ">>> Settings for fail2ban"
    echo

    local b
    b=$(suggest_backend)
    echo "Log source: Debian stopped shipping a syslog daemon, so /var/log/auth.log"
    echo "is often missing and the packaged default then matches nothing at all."
    echo "  1) systemd journal (recommended)"
    echo "  2) log files (auto)"
    local c
    read -rp "Choice [$([[ "$BACKEND" == systemd ]] && echo 1 || echo 2)]: " c
    c=${c:-$([[ "$BACKEND" == systemd ]] && echo 1 || echo 2)}
    [[ "$c" == "2" ]] && BACKEND="auto" || BACKEND="systemd"
    [[ "$BACKEND" == "systemd" && "$b" == "auto" ]] \
        && echo "  (auth.log exists here as well - the journal works either way)"

    echo
    echo "How the ban is enforced:"
    if ufw_active; then
        echo "  ufw is active. Its own action keeps the rules where you can see"
        echo "  them with 'ufw status' instead of in a chain of their own."
        confirm "Ban through ufw?" Y && BANACTION="ufw" || BANACTION=""
    else
        echo "  ufw is not active - fail2ban's own default is right for this"
        echo "  system (nftables on Debian 13, iptables before that)."
        BANACTION=""
    fi

    echo
    local t
    read -rp "Ban duration [${BANTIME}]: " t;  BANTIME=${t:-$BANTIME}
    read -rp "Window for the attempts [${FINDTIME}]: " t; FINDTIME=${t:-$FINDTIME}
    read -rp "Attempts before a ban [${MAXRETRY}]: " t;   MAXRETRY=${t:-$MAXRETRY}

    echo
    echo "--- Never banned (ignoreip) ---"
    echo "This is the list that decides whether a mistake costs you the server."
    echo "The tailnet belongs in it: it is the way back in when a rule shuts the"
    echo "front door, and no other entry covers it."
    local def="$IGNOREIP"
    [[ "$def" != *"$TAILNET_CIDR"* ]] && def="$def $TAILNET_CIDR"
    read -rp "Networks [${def}]: " t
    IGNOREIP=${t:-$def}

    install_pkgs
    write_defaults
    save_conf

    # Without a single jail fail2ban runs and does nothing - so the sshd jail
    # is offered right here rather than being left as a separate step.
    if ! jail_on sshd; then
        echo
        if confirm "Switch on the sshd jail now?" Y; then
            write_jail_sshd "$MAXRETRY" "$FINDTIME" "$BANTIME"
        fi
    fi

    if reload_f2b; then
        echo
        echo ">>> Set up. SSH port in the jail: $(ssh_port)"
        show_status
    fi
    pause
}

# ---------------------------------------------------------------------------
# Jails
# ---------------------------------------------------------------------------
edit_jail() {
    local j=$1
    local retry find ban
    retry=$(jail_val "$j" maxretry "$MAXRETRY")
    find=$(jail_val "$j" findtime "$FINDTIME")
    ban=$(jail_val "$j" bantime "$BANTIME")

    echo
    echo "--- ${j}: $(jail_purpose "$j") ---"
    if [[ "$j" == "caddy" ]]; then
        echo "Reads /var/log/caddy/*.log. The filter is ours, not upstream:"
        echo "test it (menu item 4) before relying on it."
        if [[ ! -d /var/log/caddy ]]; then
            echo "!!! /var/log/caddy does not exist - nothing to read yet."
        fi
    fi
    if [[ "$j" == "recidive" && ! -f /var/log/fail2ban.log ]]; then
        echo "!!! /var/log/fail2ban.log is missing. On a journal-only system"
        echo "!!! this jail has nothing to read; leave it off there."
    fi

    if jail_on "$j"; then
        if ! confirm "Keep it switched on?" Y; then
            rm -f "$(jail_file "$j")"
            reload_f2b || true
            echo "Switched off."
            pause
            return
        fi
    else
        confirm "Switch it on?" Y || return
    fi

    local t
    read -rp "  Attempts before a ban [${retry}]: " t; retry=${t:-$retry}
    read -rp "  Window [${find}]: " t;                 find=${t:-$find}
    read -rp "  Ban duration [${ban}]: " t;            ban=${t:-$ban}

    case "$j" in
        sshd)     write_jail_sshd     "$retry" "$find" "$ban" ;;
        recidive) write_jail_recidive "$retry" "$find" "$ban" ;;
        caddy)    write_jail_caddy    "$retry" "$find" "$ban" ;;
    esac

    if reload_f2b; then
        echo "Active."
        fail2ban-client status "$(jail_section "$j")" 2>/dev/null || true
    fi
    pause
}

jail_menu() {
    while true; do
        clear
        echo "=== Jails ==="
        printf "%-4s %-10s %-9s %-8s %-8s %s\n" "#" "JAIL" "STATE" "RETRY" "WINDOW" "BAN"
        local i=0 j
        for j in $JAILS; do
            i=$((i + 1))
            printf "%-4s %-10s %-9s %-8s %-8s %s\n" "$i)" "$j" \
                "$(jail_on "$j" && echo on || echo off)" \
                "$(jail_val "$j" maxretry '-')" \
                "$(jail_val "$j" findtime '-')" \
                "$(jail_val "$j" bantime '-')"
        done
        echo "$((i + 1))) Back"
        echo
        local CH
        read -rp "Choice: " CH
        i=0
        local picked=""
        for j in $JAILS; do
            i=$((i + 1))
            [[ "$CH" == "$i" ]] && picked=$j
        done
        if [[ -n "$picked" ]]; then
            edit_jail "$picked"
        elif [[ "$CH" == "$((i + 1))" ]]; then
            return
        else
            sleep 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Status, test, unban
# ---------------------------------------------------------------------------
show_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "fail2ban is not installed."
        return
    fi
    echo "Service: $(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
    echo "Never banned: ${IGNOREIP}"
    echo
    printf "%-14s %-8s %-8s %s\n" "JAIL" "FAILED" "BANNED" "CURRENTLY BANNED"
    printf "%-14s %-8s %-8s %s\n" "--------------" "--------" "--------" "--------------------"

    local j sec out failed banned ips
    for j in $JAILS; do
        jail_on "$j" || continue
        sec=$(jail_section "$j")
        out=$(fail2ban-client status "$sec" 2>/dev/null) || {
            printf "%-14s %s\n" "$sec" "not running (see the log)"
            continue
        }
        failed=$(awk -F: '/Currently failed/ {gsub(/ /,"",$2); print $2}' <<<"$out")
        banned=$(awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2}' <<<"$out")
        ips=$(awk -F: '/Banned IP list/ {sub(/^[[:space:]]*/,"",$2); print $2}' <<<"$out")
        printf "%-14s %-8s %-8s %s\n" "$sec" "${failed:-0}" "${banned:-0}" "${ips:- -}"
    done
}

# The question a jail cannot answer by looking healthy: does its filter match
# anything that is really in the log? An empty jail and a jail whose regex is
# wrong look exactly the same from the outside.
test_filter() {
    local j=$1 sec filter src
    sec=$(jail_section "$j")
    echo "--- Test: ${j} ---"
    case "$j" in
        sshd)
            filter="$FILTER_DIR/sshd.conf"
            if [[ "$BACKEND" == "systemd" ]]; then src="systemd-journal"; else src=/var/log/auth.log; fi
            ;;
        caddy)
            filter="$CADDY_FILTER"
            src=$(ls -1t /var/log/caddy/*.log 2>/dev/null | head -1 || true)
            [[ -z "$src" ]] && { echo "No log under /var/log/caddy."; pause; return; }
            ;;
        recidive)
            filter="$FILTER_DIR/recidive.conf"
            src=/var/log/fail2ban.log
            ;;
    esac
    [[ -f "$filter" ]] || { echo "Filter ${filter} not found."; pause; return; }
    [[ "$src" == "systemd-journal" || -f "$src" ]] || { echo "Log source ${src} not found."; pause; return; }

    echo "Filter: ${filter}"
    echo "Source: ${src}"
    echo
    # Only the summary: the full output lists every matched line and scrolls
    # the interesting number off the screen.
    fail2ban-regex "$src" "$filter" 2>&1 | grep -E 'Failregex|Lines:|matched|missed' | head -20 || true
    echo
    echo "'Failregex: N total' above 0 means the filter sees real attempts."
    echo "0 with a busy log means the regex does not fit - the jail would never"
    echo "ban anyone while looking perfectly healthy."
    pause
}

unban_ip() {
    show_status
    echo
    local ip
    read -rp "IP address to unban (empty = cancel): " ip
    ip=$(printf '%s' "$ip" | tr -d '[:space:]')
    [[ -z "$ip" ]] && return

    local j sec done_any=0
    for j in $JAILS; do
        jail_on "$j" || continue
        sec=$(jail_section "$j")
        if fail2ban-client set "$sec" unbanip "$ip" >/dev/null 2>&1; then
            echo "  unbanned in ${sec}"
            done_any=1
        fi
    done
    (( done_any == 0 )) && echo "  ${ip} was not banned anywhere."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall fail2ban-setup"
    echo

    local n=0
    n=$(find "$JAIL_DIR" -name '*-mmo.local' 2>/dev/null | wc -l) || n=0

    echo "The following will be removed:"
    echo "  - ${n} jail file(s) *-mmo.local in $JAIL_DIR"
    echo "  - the defaults $DEFAULTS_FILE"
    [[ -f "$CADDY_FILTER" ]] && echo "  - the Caddy filter $CADDY_FILTER"
    [[ -f "$CONF" ]]         && echo "  - the configuration $CONF"
    echo "  - the fail2ban package                                  [asked]"
    echo
    echo "jail.conf and a jail.local of your own are not touched."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup fail2ban "$JAIL_DIR" "$CADDY_FILTER" "$CONF" || { pause; return; }

    # The bans live in fail2ban's database, not in the config: stopping the
    # service drops the firewall rules, so nobody stays locked out by a tool
    # that is no longer installed.
    rm -f "$JAIL_DIR"/*-mmo.local "$DEFAULTS_FILE" "$CADDY_FILTER" "$CONF"

    if confirm "Remove the fail2ban package as well?"; then
        systemctl stop fail2ban >/dev/null 2>&1 || true
        systemctl disable fail2ban >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt purge -y fail2ban >/dev/null 2>&1 || true
        echo "Package removed - with it every active ban."
    else
        reload_f2b || true
        echo "Package kept; without our jails it now watches nothing of ours."
    fi

    echo
    echo "Removed."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " fail2ban - banning after failed attempts"
        echo "==========================================="
        if is_setup; then
            show_status
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Settings (backend, durations, ignoreip)"
        echo "2) Jails (switch on/off, thresholds)"
        echo "3) Status"
        echo "4) Test a filter against the real log"
        echo "5) Unban an IP address"
        echo "6) Log (journalctl -u fail2ban)"
        echo "7) Uninstall"
        echo "8) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || { echo "Run the setup first."; pause; continue; }
               jail_menu ;;
            3) show_status; pause ;;
            4) echo "Which jail? (sshd / recidive / caddy)"
               read -rp "Jail: " J
               case "$J" in
                   sshd|recidive|caddy) test_filter "$J" ;;
                   *) echo "Unknown."; pause ;;
               esac ;;
            5) unban_ip ;;
            6) journalctl -u fail2ban -n 50 --no-pager || true; pause ;;
            7) uninstall ;;
            8) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
