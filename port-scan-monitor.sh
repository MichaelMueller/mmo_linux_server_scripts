#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# port-scan-monitor.sh - scan servers from OUTSIDE and alert on unexpected ports
#
# Runs on a separate scanner host (not on the servers it checks: a server that
# scans its own public IP goes over loopback and sees past its firewall). Scans
# every target's public address with nmap, compares the open ports with the
# expected ones and mails when that changes:
#   unexpected open  - something listens publicly that should not (firewall
#                      gap, a Docker -p port, a forgotten service)
#   expected closed  - an application port is not reachable (service down,
#                      firewall too strict)
#
# Modes: (no argument) = interactive menu
#        --setup                         = settings dialogue once
#        --add NAME ADDRESS [TCP] [UDP]  = add/replace a target
#                                          TCP/UDP: expected ports, e.g. 80,443;
#                                          '-' = none (default TCP 80,443)
#        --remove NAME                   = remove a target (all its addresses)
#        --list                          = list targets and their last result
#        --check [NAME]                  = scan all (or one) target(s) (cron)
#        --status                        = short status on stdout
#        --uninstall                     = uninstall
set -uo pipefail

# --version must come before the root check so it answers without sudo.
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
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/port-scan-monitor.conf"
CRON_FILE=/etc/cron.d/port-scan-monitor
LOCK_FILE=/run/port-scan-monitor.lock

# ---------------------------------------------------------------------------
# Configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
SCHEDULE="daily"          # daily | hourly | off
SCAN_TIME="04:30"         # HH:MM for daily - after the update and reboot windows
TCP_SCOPE="all"           # all (1-65535) | top1000
UDP_SCAN=1                # 1 = also the 50 most common UDP ports
NMAP_OPTS="-T4 --max-retries 2"
ALERT_MAIL=""
REMIND_DAYS=7             # repeat an unresolved alert after N days, 0 = never

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

case "${DATA_DIR%/}" in
    /*) ;;
    "") DATA_DIR="$DIR/var" ;;
    *)  DATA_DIR="$DIR/${DATA_DIR#./}" ;;
esac
BASE="$DATA_DIR/port-scan"
TARGETS="$BASE/targets.txt"     # NAME ADDRESS TCP UDP  (one line per address)
STATE_DIR="$BASE/state"
LOG="$BASE/scan.log"

save_conf() {
    cat > "$CONF" <<EOF
# port-scan-monitor configuration
DATA_DIR="${DATA_DIR}"
SCHEDULE="${SCHEDULE}"
SCAN_TIME="${SCAN_TIME}"
TCP_SCOPE="${TCP_SCOPE}"
UDP_SCAN=${UDP_SCAN}
NMAP_OPTS="${NMAP_OPTS}"
ALERT_MAIL="${ALERT_MAIL}"
REMIND_DAYS=${REMIND_DAYS}
EOF
    chmod 644 "$CONF"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

is_setup() { [[ -f "$CONF" ]]; }
log() { mkdir -p "$BASE"; echo "$(date '+%F %T') $*" >> "$LOG"; }

ensure_nmap() {
    command -v nmap &>/dev/null && return 0
    echo ">>> Installing nmap..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nmap >/dev/null \
        || { echo "!!! nmap could not be installed." >&2; return 1; }
}

# "80,443,8080:8090" / "-" / "" -> sorted, comma-separated, "-" when empty.
# Ranges (a:b or a-b) are expanded, up to 1000 ports each.
norm_ports() {
    local p=${1:-} t a b out=""
    [[ "$p" == "-" ]] && p=""
    for t in $(tr ', ' '  ' <<<"$p"); do
        if [[ "$t" =~ ^([0-9]+)[:-]([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            (( b >= a && b - a <= 1000 )) && out+=" $(seq -s ' ' "$a" "$b")"
        elif [[ "$t" =~ ^[0-9]+$ ]]; then
            out+=" $t"
        fi
    done
    p=$(tr ' ' '\n' <<<"$out" | grep -E '^[0-9]+$' | sort -n -u | paste -sd, -)
    echo "${p:--}"
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_addr() { [[ "$1" =~ ^[0-9A-Za-z.:-]+$ ]]; }

state_file() { echo "$STATE_DIR/$(tr -c 'A-Za-z0-9._-' '_' <<<"$1_$2" | sed 's/_$//')"; }

write_cron() {
    if [[ "$SCHEDULE" == "off" ]]; then rm -f "$CRON_FILE"; return 0; fi
    local spec h m
    h=$((10#${SCAN_TIME%%:*})); m=$((10#${SCAN_TIME##*:}))
    if [[ "$SCHEDULE" == "hourly" ]]; then spec="${m} * * * *"; else spec="${m} ${h} * * *"; fi
    cat > "$CRON_FILE" <<EOF
# port-scan-monitor - external port scan of the servers
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${spec} root flock -n ${LOCK_FILE} ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

schedule_text() {
    case "$SCHEDULE" in
        hourly) echo "hourly at minute $((10#${SCAN_TIME##*:}))" ;;
        off)    echo "off (only manual scans)" ;;
        *)      echo "daily at ${SCAN_TIME}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo "This host scans the servers from outside. It must NOT be one of them"
    echo "and should sit in a different network (other provider or location),"
    echo "so the scan sees what the internet sees."
    echo
    echo "--- Schedule ---"
    echo "  1) daily     (recommended - a full scan takes a few minutes per server)"
    echo "  2) hourly    (only with TCP scope 'top1000' and few servers)"
    echo "  3) off       (only manual scans)"
    local def=1 c
    case "$SCHEDULE" in hourly) def=2 ;; off) def=3 ;; esac
    read -rp "Choice [${def}]: " c
    case "${c:-$def}" in 2) SCHEDULE="hourly" ;; 3) SCHEDULE="off" ;; *) SCHEDULE="daily" ;; esac
    if [[ "$SCHEDULE" != "off" ]]; then
        echo "Time of the scan - after the update and reboot windows (02:00/03:00),"
        echo "so a reboot does not show up as 'expected port closed'."
        local T; read -rp "Time (HH:MM; for hourly only the minute counts) [${SCAN_TIME}]: " T
        T=${T:-$SCAN_TIME}
        while [[ ! "$T" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; do read -rp "  -> format HH:MM: " T; done
        SCAN_TIME=$(printf '%02d:%02d' "$((10#${T%%:*}))" "$((10#${T##*:}))")
    fi

    echo
    echo "--- TCP scope ---"
    echo "  1) all ports 1-65535   (recommended - forgotten services rarely sit"
    echo "                          on well-known ports)"
    echo "  2) top 1000 ports      (much faster)"
    def=1; [[ "$TCP_SCOPE" == "top1000" ]] && def=2
    read -rp "Choice [${def}]: " c
    [[ "${c:-$def}" == "2" ]] && TCP_SCOPE="top1000" || TCP_SCOPE="all"

    echo
    echo "UDP: the 50 most common UDP ports (DNS, NTP, SNMP, WireGuard ...)."
    echo "Only ports that clearly answer count as open."
    confirm "Scan UDP as well?" "$([[ $UDP_SCAN -eq 1 ]] && echo Y || echo N)" && UDP_SCAN=1 || UDP_SCAN=0

    echo
    echo "--- Alerts ---"
    echo "Recipient(s) for alerts - several separated by a comma. A mail goes out"
    echo "when the result of a server changes (new unexpected port, port gone,"
    echo "back to OK), not on every scan."
    local r; read -rp "Alert mail [${ALERT_MAIL}]: " r
    ALERT_MAIL=${r:-$ALERT_MAIL}
    read -rp "Repeat an unresolved alert after N days (0 = never) [${REMIND_DAYS}]: " r
    [[ "${r:-}" =~ ^[0-9]+$ ]] && REMIND_DAYS=$r
    command -v mail &>/dev/null || echo "Note: 'mail' is missing - set up mail-setup.sh or graph-mailer.sh."

    ensure_nmap || return 1
    mkdir -p "$STATE_DIR"; touch "$TARGETS"
    save_conf
    write_cron
    echo
    echo "Schedule: $(schedule_text); TCP: ${TCP_SCOPE}; UDP: $([[ $UDP_SCAN -eq 1 ]] && echo top 50 || echo off)"
    echo "Targets:  ${TARGETS} - add servers via the menu or:"
    echo "          sudo ${SELF} --add <name> <public-ip> 80,443"
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
add_target() {
    local name=${1:-} addr=${2:-} tcp udp
    tcp=$(norm_ports "${3:-80,443}"); udp=$(norm_ports "${4:--}")
    valid_name "$name" || { echo "Invalid name '${name}'." >&2; return 1; }
    valid_addr "$addr" || { echo "Invalid address '${addr}'." >&2; return 1; }
    mkdir -p "$STATE_DIR"; touch "$TARGETS"
    # one line per name+address: replace an existing one
    awk -v n="$name" -v a="$addr" '!($1 == n && $2 == a)' "$TARGETS" > "$TARGETS.tmp"
    printf '%s %s %s %s\n' "$name" "$addr" "$tcp" "$udp" >> "$TARGETS.tmp"
    sort -o "$TARGETS" "$TARGETS.tmp"; rm -f "$TARGETS.tmp"
    echo "Target ${name} ${addr}: expected TCP ${tcp}, UDP ${udp}"
}

remove_target() {
    local name=${1:-}
    [[ -f "$TARGETS" ]] && grep -q "^${name} " "$TARGETS" || { echo "No target '${name}'." >&2; return 1; }
    awk -v n="$name" '$1 != n' "$TARGETS" > "$TARGETS.tmp" && mv "$TARGETS.tmp" "$TARGETS"
    rm -f "$STATE_DIR/$(tr -c 'A-Za-z0-9._-' '_' <<<"${name}_" | sed 's/_$//')"*
    echo "Removed ${name}."
}

list_targets() {
    if [[ ! -s "$TARGETS" ]]; then echo "(no targets)"; return 0; fi
    printf '%-20s %-28s %-14s %-8s %s\n' NAME ADDRESS "EXPECTED TCP" UDP "LAST RESULT"
    local n a t u s
    while read -r n a t u; do
        [[ -z "$n" || "$n" == \#* ]] && continue
        s=$(cat "$(state_file "$n" "$a")" 2>/dev/null | head -1)
        printf '%-20s %-28s %-14s %-8s %s\n' "$n" "$a" "$t" "$u" "${s:-not scanned yet}"
    done < "$TARGETS"
}

interactive_add() {
    local n a t u
    echo "Name: the server's hostname, as it appears in alerts."
    read -rp "Name: " n
    echo "Address: the PUBLIC IPv4 or IPv6 address (or a DNS name). For a server"
    echo "with both, add it twice - the firewall has to hold on both."
    read -rp "Address: " a
    echo "Expected open TCP ports, comma-separated ('-' = none), usually 80,443."
    read -rp "TCP [80,443]: " t
    echo "Expected open UDP ports ('-' = none), e.g. 51820 for WireGuard."
    read -rp "UDP [-]: " u
    add_target "$n" "$a" "${t:-80,443}" "${u:--}"
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
# scan_ports <address> <tcp|udp>  -> open ports, comma-separated ("-" = none)
# Only state "open" counts: "open|filtered" (no answer, typical for UDP behind
# a firewall) and "filtered" are not open.
scan_ports() {
    local addr=$1 proto=$2 out
    local -a args=(-Pn -n --open -oG -)
    # shellcheck disable=SC2206
    args+=($NMAP_OPTS)
    [[ "$addr" == *:* ]] && args+=(-6)
    if [[ "$proto" == "udp" ]]; then
        args+=(-sU --top-ports 50)
    else
        args+=(-sS)
        [[ "$TCP_SCOPE" == "all" ]] && args+=(-p-)
    fi
    out=$(nmap "${args[@]}" "$addr" 2>&1) || { echo "ERROR"; return 1; }
    if grep -qE "Failed to resolve|QUITTING|0 IP addresses" <<<"$out"; then echo "ERROR"; return 1; fi
    grep -oE "[0-9]+/open/${proto}" <<<"$out" | cut -d/ -f1 | sort -n -u | paste -sd, - | sed 's/^$/-/'
}

# diff_ports <expected> <found> -> "unexpected|missing" (comma lists or empty)
diff_ports() {
    local e f
    e=$(tr ',' '\n' <<<"${1/#-/}" | grep -v '^$' | sort -u)
    f=$(tr ',' '\n' <<<"${2/#-/}" | grep -v '^$' | sort -u)
    printf '%s|%s\n' \
        "$(comm -13 <(echo "$e") <(echo "$f") | grep -v '^$' | sort -n | paste -sd, -)" \
        "$(comm -23 <(echo "$e") <(echo "$f") | grep -v '^$' | sort -n | paste -sd, -)"
}

notify() {
    local subject=$1 body=$2
    log "ALERT ${subject}"
    [[ -n "$ALERT_MAIL" ]] || return 0
    if command -v mail &>/dev/null; then
        printf '%s\n' "$body" | mail -s "$subject" "$ALERT_MAIL" || log "!!! mail to ${ALERT_MAIL} failed"
    else
        log "!!! 'mail' not available - alert not sent"
    fi
}

# check_target <name> <addr> <tcp> <udp> [verbose]
check_target() {
    local n=$1 a=$2 et=$3 eu=$4 verbose=${5:-} ft fu="-" status detail sf old oldts now
    ft=$(scan_ports "$a" tcp)
    (( UDP_SCAN == 1 )) && fu=$(scan_ports "$a" udp)

    if [[ "$ft" == "ERROR" || "$fu" == "ERROR" ]]; then
        status="SCAN FAILED"
        detail="nmap could not scan ${a} (address unreachable or not resolvable)."
    else
        local tu tm uu um
        IFS='|' read -r tu tm <<<"$(diff_ports "$et" "$ft")"
        uu=""; um=""
        (( UDP_SCAN == 1 )) && IFS='|' read -r uu um <<<"$(diff_ports "$eu" "$fu")"
        status="OK"; detail=""
        if [[ -n "$tu$uu" ]]; then
            status="UNEXPECTED OPEN:${tu:+ tcp ${tu}}${uu:+ udp ${uu}}"
            detail+="Unexpectedly open: ${tu:+TCP ${tu} }${uu:+UDP ${uu}}"$'\n'
            detail+="-> something listens publicly that should not: check the firewall"$'\n'
            detail+="   (ufw status), Docker port mappings (-p binds past ufw), and"$'\n'
            detail+="   'ss -tulpn' on the server."$'\n'
        fi
        if [[ -n "$tm$um" ]]; then
            [[ "$status" == "OK" ]] && status="" || status+="; "
            status+="EXPECTED CLOSED:${tm:+ tcp ${tm}}${um:+ udp ${um}}"
            detail+="Expected but not reachable: ${tm:+TCP ${tm} }${um:+UDP ${um}}"$'\n'
            detail+="-> application down, or the firewall blocks it."$'\n'
        fi
    fi
    log "${n} ${a} tcp=${ft} udp=${fu} -> ${status}"
    [[ -n "$verbose" ]] && printf '  %-20s %-28s tcp %-14s udp %-10s %s\n' "$n" "$a" "$ft" "$fu" "$status"

    mkdir -p "$STATE_DIR"
    sf=$(state_file "$n" "$a")
    old=$(head -1 "$sf" 2>/dev/null || true)
    oldts=$(sed -n 2p "$sf" 2>/dev/null || echo 0)
    now=$(date +%s)
    local remind=0
    if [[ "$status" != "OK" && "$status" == "$old" ]] && (( REMIND_DAYS > 0 )) \
       && (( now - ${oldts:-0} >= REMIND_DAYS * 86400 )); then
        remind=1
    fi
    if [[ "$status" != "$old" ]] || (( remind == 1 )); then
        # The first scan of a target only alerts when it is not OK.
        if [[ -n "$old" || "$status" != "OK" ]]; then
            local subj body
            if [[ "$status" == "OK" ]]; then
                subj="[OK] port scan ${n} (${a}): back to expected"
            else
                subj="[ALERT] port scan ${n} (${a}): ${status}$( ((remind==1)) && echo " (reminder)")"
            fi
            body="External port scan from $(hostname -f 2>/dev/null || hostname) at $(date '+%F %T')

Target:    ${n} (${a})
Expected:  TCP ${et}, UDP ${eu}
Found:     TCP ${ft}$( ((UDP_SCAN==1)) && echo ", UDP ${fu}")
Before:    ${old:-first scan}

${detail:-Everything as expected.}"
            notify "$subj" "$body"
        fi
        printf '%s\n%s\n' "$status" "$now" > "$sf"
    fi
    [[ "$status" == "OK" ]]
}

run_check() {
    local only=${1:-} verbose=${2:-} n a t u found=0 bad=0
    is_setup || { echo "Not set up - run: $SELF --setup" >&2; return 1; }
    ensure_nmap || return 1
    [[ -s "$TARGETS" ]] || { echo "No targets." >&2; return 0; }
    while read -r n a t u; do
        [[ -z "$n" || "$n" == \#* ]] && continue
        [[ -n "$only" && "$n" != "$only" ]] && continue
        found=1
        check_target "$n" "$a" "$t" "$u" "$verbose" </dev/null || bad=$((bad + 1))
    done < "$TARGETS"
    (( found == 1 )) || { echo "No target '${only}'." >&2; return 1; }
    tail -n 5000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    (( bad == 0 ))
}

show_status() {
    echo "Schedule:  $(schedule_text)"
    echo "Scope:     TCP ${TCP_SCOPE}, UDP $([[ $UDP_SCAN -eq 1 ]] && echo "top 50" || echo off)"
    echo "Alerts to: ${ALERT_MAIL:-(no mail, log only)}"
    local cnt=0
    [[ -f "$TARGETS" ]] && cnt=$(grep -cvE '^[[:space:]]*(#|$)' "$TARGETS" || true)
    echo "Targets:   ${cnt:-0}"
    echo
    list_targets
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo "Removes the cron entry and the configuration; targets and the scan"
    echo "log in ${BASE} are asked for separately. nmap stays installed."
    confirm "Uninstall port-scan-monitor?" || return 0
    rm -f "$CRON_FILE" "$CONF"
    if [[ -d "$BASE" ]] && confirm "Delete the targets and the log (${BASE}) as well?"; then
        rm -rf "$BASE"
    fi
    echo "Removed."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    local ch n
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " External port scan"
        echo "==========================================="
        show_status
        echo
        echo "1) Settings"
        echo "2) Add / replace a target"
        echo "3) Remove a target"
        echo "4) Scan all now"
        echo "5) Show the log"
        echo "6) Uninstall"
        echo "7) Quit"
        read -rp "Choice: " ch
        case "$ch" in
            1) configure; pause ;;
            2) interactive_add; pause ;;
            3) read -rp "Name: " n; remove_target "$n"; pause ;;
            4) echo; run_check "" verbose; echo; pause ;;
            5) tail -n 40 "$LOG" 2>/dev/null || echo "(no log)"; pause ;;
            6) uninstall; pause ;;
            7|q) exit 0 ;;
        esac
    done
}

case "${1:-}" in
    --setup)     configure ;;
    --add)       shift; add_target "$@" ;;
    --remove)    remove_target "${2:-}" ;;
    --list)      list_targets ;;
    --check)     run_check "${2:-}" "$([[ -t 1 ]] && echo verbose)" ;;
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--setup|--add NAME ADDR [TCP] [UDP]|--remove NAME|--list|--check [NAME]|--status|--uninstall|--version]"; exit 1 ;;
esac
