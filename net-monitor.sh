#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# net-monitor.sh - watch sustained network throughput per interface
# Modes: (no argument) = interactive menu
#        --check       = one run (for cron)
#        --status      = current throughput on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.2.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/net-monitor.conf"
CRON_FILE=/etc/cron.d/net-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5           # gap between checks, in minutes
N_CONSEC=3               # readings above the threshold before an alert
RETENTION_DAYS=30
ALERT_MAIL=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# A relative data directory would be created wherever the caller happens to
# stand - and cron stands somewhere else than you do, so state would be written
# in one place and looked for in another. Therefore: resolve against the
# script's directory, never against $PWD.
resolve_data_dir() {
    local d=${1%/}
    case "$d" in
        /*) printf '%s' "$d" ;;
        "") printf '%s' "$DIR/var" ;;
        .)  printf '%s' "$DIR" ;;
        *)  printf '%s' "$DIR/${d#./}" ;;
    esac
}
DATA_DIR=$(resolve_data_dir "$DATA_DIR")

BASE="$DATA_DIR/net"
IFACES_DIR="$BASE/ifaces.d"
STATE_DIR="$BASE/state"
LOG_DIR="$BASE/log"
RESULTS_DIR="$BASE/results"
LOCK_FILE="$BASE/.lock"
ALERT_LOG="$LOG_DIR/alerts.log"
RUN_LOG="$LOG_DIR/net.log"

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

# Alerts leave this machine through the local mailer - the same sendmail that
# mail-setup.sh (msmtp) or graph-mailer.sh puts in place. That is deliberately
# the only channel: one path that is properly set up and testable beats two
# half-configured ones, and every other tool here reports the same way.
mailer_ready() {
    command -v mail &>/dev/null || [[ -x /usr/sbin/sendmail ]]
}

# Returns 1 if there is no mailer and the user does not want to continue without
# one - the caller then writes no configuration, so the tool stays "not set up"
# instead of quietly monitoring into a void.
ask_alert_mail() {
    if ! mailer_ready; then
        echo
        echo "!!! No mailer on this machine ('mail' and sendmail are both"
        echo "!!! missing), so alerts cannot go anywhere. Set one up first:"
        echo "!!!     sudo ./mail-setup.sh     (SMTP account)"
        echo "!!!     sudo ./graph-mailer.sh   (Microsoft 365 / Graph)"
        echo
        confirm "Continue anyway - alerts would only go to the log?" || return 1
    fi
    local M
    read -rp "Mail address for alerts [${ALERT_MAIL}]: " M
    [[ -z "$ALERT_MAIL" ]] && echo "  (no address given - alerts only go to the alert log)"
    return 0
}

is_setup() { [[ -f "$CONF" && -d "$IFACES_DIR" ]]; }

make_dirs() { mkdir -p "$IFACES_DIR" "$STATE_DIR" "$LOG_DIR" "$RESULTS_DIR"; }

save_conf() {
    cat > "$CONF" <<EOF
# net-monitor configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
N_CONSEC=${N_CONSEC}
RETENTION_DAYS=${RETENTION_DAYS}
ALERT_MAIL="${ALERT_MAIL}"
EOF
    chmod 644 "$CONF"
}

# cron does not understand "*/60" and rejects the whole line. From an hour on,
# the interval therefore has to be expressed as an hour step, not a minute step.
cron_spec() {
    if (( INTERVAL_MIN >= 60 )); then
        local h=$(( INTERVAL_MIN / 60 ))
        (( h < 1 )) && h=1
        (( h > 23 )) && h=23
        echo "0 */${h} * * *"
    else
        echo "*/${INTERVAL_MIN} * * * *"
    fi
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# net-monitor - network throughput monitoring
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$(cron_spec) root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Interfaces (CRUD)
# ---------------------------------------------------------------------------
target_file() { echo "$IFACES_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

# The kernel counts bytes since the interface came up. What matters here is the
# difference between two runs divided by the time really elapsed - not by the
# nominal interval, because cron can be late and a stretched interval would
# otherwise look like less traffic than there was.
iface_bytes() {
    local i=$1 rx tx
    rx=$(cat "/sys/class/net/${i}/statistics/rx_bytes" 2>/dev/null) || return 1
    tx=$(cat "/sys/class/net/${i}/statistics/tx_bytes" 2>/dev/null) || return 1
    echo "${rx}|${tx}"
}

# Only physical interfaces report a speed; tunnels and bridges answer -1 or
# nothing at all. Then there is no percentage to give, only absolute Mbit/s.
link_speed() {
    local s
    s=$(cat "/sys/class/net/${1}/speed" 2>/dev/null) || return 1
    [[ "$s" =~ ^[0-9]+$ ]] && (( s > 0 )) || return 1
    echo "$s"
}

list_ifaces() {
    if [[ ! -d "$IFACES_DIR" ]] || ! ls "$IFACES_DIR"/*.conf &>/dev/null; then
        echo "(no interfaces created)"
        return
    fi
    printf "%-14s %-10s %-6s %11s %11s %-6s %s\n" \
        "NAME" "INTERFACE" "ACTIVE" "RX Mbit/s" "TX Mbit/s" "STATE" "LAST CHECK"
    printf "%-14s %-10s %-6s %11s %11s %-6s %s\n" \
        "--------------" "----------" "------" "-----------" "-----------" "------" "-------------------"
    local f
    for f in "$IFACES_DIR"/*.conf; do
        ( NAME=""; IFACE=""; ENABLED="1"
          # shellcheck disable=SC1090
          . "$f"
          local rxs txs rxv txv ts st
          rxs="$STATE_DIR/${NAME}.rx.state"
          txs="$STATE_DIR/${NAME}.tx.state"
          rxv="-"; txv="-"; ts="-"; st="-"
          if [[ -f "$rxs" ]]; then
              IFS='|' read -r st ts rxv _ < "$rxs"
          fi
          [[ -f "$txs" ]] && txv=$(cut -d'|' -f3 "$txs")
          printf "%-14s %-10s %-6s %11s %11s %-6s %s\n" \
              "$NAME" "$IFACE" \
              "$([[ "$ENABLED" == "1" ]] && echo yes || echo no)" \
              "${rxv:--}" "${txv:--}" "${st:--}" "${ts:--}"
        )
    done
}

create_iface() {
    echo "--- Existing entries ---"; list_ifaces; echo
    echo "Interfaces on this machine:"
    ip -br link show 2>/dev/null | awk '{printf "  %-12s %s\n", $1, $2}'
    echo

    read -rp "Name for this entry: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(target_file "$NAME")" ]]; do
        echo "Invalid or already taken."
        read -rp "Name for this entry: " NAME
    done

    read -rp "Interface [${NAME}]: " IFACE; IFACE=${IFACE:-$NAME}
    while [[ ! -d "/sys/class/net/${IFACE}" ]]; do
        echo "!!! There is no interface '${IFACE}'."
        read -rp "Interface: " IFACE
    done

    local sp
    if sp=$(link_speed "$IFACE"); then
        echo "  Link speed: ${sp} Mbit/s - as a guide, 80 % of it is $(( sp * 80 / 100 )) Mbit/s."
    else
        echo "  (the interface reports no link speed - thresholds have to be absolute)"
    fi

    echo
    echo "0 switches that direction off. RX is incoming, TX is outgoing."
    read -rp "Warn from RX Mbit/s [0]: " MAX_RX; MAX_RX=${MAX_RX:-0}
    while [[ ! "$MAX_RX" =~ ^[0-9]+$ ]]; do read -rp "  -> a number is expected: " MAX_RX; done
    read -rp "Warn from TX Mbit/s [0]: " MAX_TX; MAX_TX=${MAX_TX:-0}
    while [[ ! "$MAX_TX" =~ ^[0-9]+$ ]]; do read -rp "  -> a number is expected: " MAX_TX; done
    read -rp "Note (optional): " NOTE

    cat > "$(target_file "$NAME")" <<EOF
NAME="${NAME}"
IFACE="${IFACE}"
MAX_RX_MBIT="${MAX_RX}"
MAX_TX_MBIT="${MAX_TX}"
ENABLED="1"
NOTE="${NOTE}"
EOF

    echo
    echo "Created. The first run records the counters, the one after it can measure."
    pause
}

edit_iface() {
    echo "--- Entries ---"; list_ifaces; echo
    read -rp "Name to edit: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    # shellcheck disable=SC1090
    . "$f"
    read -rp "Interface [${IFACE}]: " I; I=${I:-$IFACE}
    read -rp "Warn from RX Mbit/s (0 = off) [${MAX_RX_MBIT}]: " RX; RX=${RX:-$MAX_RX_MBIT}
    read -rp "Warn from TX Mbit/s (0 = off) [${MAX_TX_MBIT}]: " TX; TX=${TX:-$MAX_TX_MBIT}
    read -rp "Active (1/0) [${ENABLED}]: " E; E=${E:-$ENABLED}
    read -rp "Note [${NOTE}]: " O; O=${O:-$NOTE}

    cat > "$f" <<EOF
NAME="${NAME}"
IFACE="${I}"
MAX_RX_MBIT="${RX}"
MAX_TX_MBIT="${TX}"
ENABLED="${E}"
NOTE="${O}"
EOF
    echo "Updated."
    pause
}

delete_iface() {
    echo "--- Entries ---"; list_ifaces; echo
    read -rp "Name to delete: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    if confirm "Really delete '$N'?"; then
        rm -f "$f" "$STATE_DIR/${N}.rx.state" "$STATE_DIR/${N}.tx.state" \
              "$STATE_DIR/${N}.counters"
        if confirm "Delete the samples (${RESULTS_DIR}/${N}.csv) as well?"; then
            rm -f "$RESULTS_DIR/${N}.csv"
        fi
        echo "Deleted."
    else
        echo "Cancelled."
    fi
    pause
}

iface_menu() {
    while true; do
        clear
        echo "=== Manage interfaces ==="
        list_ifaces
        echo
        echo "1) Add an interface"
        echo "2) Edit an entry"
        echo "3) Delete an entry"
        echo "4) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1) create_iface ;;
            2) edit_iface ;;
            3) delete_iface ;;
            4) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
notify() {
    local subject=$1 body=$2
    echo "$(date '+%F %T') ${subject}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_MAIL" ]]; then
        if command -v mail &>/dev/null; then
            printf '%s\n' "$body" | mail -s "$subject" "$ALERT_MAIL" \
                || echo "$(date '+%F %T') !!! sending mail failed" >> "$ALERT_LOG"
        else
            echo "$(date '+%F %T') !!! 'mail' missing - nothing sent" >> "$ALERT_LOG"
        fi
    fi
}

# ---------------------------------------------------------------------------
# One axis: debounce, state, change detection
# ---------------------------------------------------------------------------
# RX and TX are kept apart deliberately. A saturated downlink and a saturated
# uplink are different incidents with different causes - a backup pushing data
# out is not the same as a flood coming in - and adding them up would hide
# whichever of the two is the smaller number.
#
# The debounce counter is what makes this "constant" throughput rather than a
# spike: a nightly backup or a container image pull saturates the line for a
# few minutes without anything being wrong. Only N_CONSEC readings in a row
# above the threshold move the state; one reading back inside the range resets
# the counter.
#
# Appends to the global arrays 'changes' and 'worst'.
axis_update() {
    local name=$1 axis=$2 mbit=$3 limit=$4 pct=$5

    local sf="$STATE_DIR/${name}.${axis}.state"
    local prev="-" consec=0
    if [[ -f "$sf" ]]; then
        IFS='|' read -r prev _ _ consec < "$sf"
        prev=${prev:--}
        consec=${consec:-0}
        [[ "$consec" =~ ^[0-9]+$ ]] || consec=0
    fi

    local new_state=ok reason=""
    if (( limit > 0 )) && awk -v m="$mbit" -v l="$limit" 'BEGIN{exit !(m >= l)}'; then
        new_state=warn
        reason="${axis^^} ${mbit} Mbit/s >= ${limit} Mbit/s"
        [[ -n "$pct" ]] && reason+=" (${pct}% of the link)"
    fi

    if [[ "$new_state" == "ok" ]]; then consec=0; else consec=$(( consec + 1 )); fi

    local eff="$new_state"
    if [[ "$new_state" != "ok" ]] && (( consec < N_CONSEC )); then
        if [[ "$prev" == "-" ]]; then eff="ok"; else eff="$prev"; fi
    fi

    printf '%s|%s|%s|%s\n' "$eff" "$NOW" "$mbit" "$consec" > "$sf"

    [[ "$eff" != "ok" ]] && RC=1

    # A first reading in the normal state is not an incident.
    if [[ "$prev" == "-" && "$eff" == "ok" ]]; then return 0; fi

    if [[ "$prev" != "$eff" ]]; then
        if [[ "$eff" == "ok" ]]; then
            changes+=("RECOVERED ${name} ${axis^^}: back below the threshold (${mbit} Mbit/s)")
        else
            changes+=("${eff^^} ${name}: ${reason}")
            worst+=("$name")
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Check one interface
# ---------------------------------------------------------------------------
check_one() {
    local f=$1 verbose=${2:-}
    local NAME="" IFACE="" MAX_RX_MBIT=0 MAX_TX_MBIT=0 ENABLED="1" NOTE=""
    # shellcheck disable=SC1090
    . "$f"
    [[ "$ENABLED" == "1" ]] || return 0

    local cf="$STATE_DIR/${NAME}.counters"
    local now_s; now_s=$(date +%s)

    # An interface that is gone is not zero traffic - it is a different problem,
    # and silently dropping it out of the run would hide it.
    local raw
    if ! raw=$(iface_bytes "$IFACE"); then
        local sf="$STATE_DIR/${NAME}.rx.state" prev="-"
        [[ -f "$sf" ]] && prev=$(cut -d'|' -f1 "$sf")
        printf 'gone|%s|-|0\n' "$NOW" > "$sf"
        if [[ "$prev" != "gone" && "$prev" != "-" ]]; then
            changes+=("GONE ${NAME}: the interface ${IFACE} no longer exists")
            RC=1
        fi
        [[ -n "$verbose" ]] && printf '%-14s %s\n' "$NAME" "interface ${IFACE} is gone"
        return 0
    fi

    local rx tx
    IFS='|' read -r rx tx <<<"$raw"

    if [[ ! -f "$cf" ]]; then
        echo "${now_s}|${rx}|${tx}" > "$cf"
        [[ -n "$verbose" ]] && printf '%-14s %s\n' "$NAME" "baseline recorded"
        return 0
    fi

    local p_time p_rx p_tx
    IFS='|' read -r p_time p_rx p_tx < "$cf"
    echo "${now_s}|${rx}|${tx}" > "$cf"

    local d_sec=$(( now_s - ${p_time:-0} ))
    local d_rx=$(( rx - ${p_rx:-0} ))
    local d_tx=$(( tx - ${p_tx:-0} ))

    # A negative delta is not traffic. The counters reset when the link goes
    # down, when the driver reloads or on a 32-bit wrap - reporting that as a
    # multi-gigabit burst would be a fabricated alert, so the sample is dropped
    # and only the baseline renewed.
    if (( d_sec <= 0 || d_rx < 0 || d_tx < 0 )); then
        [[ -n "$verbose" ]] && printf '%-14s %s\n' "$NAME" "counter reset - sample discarded"
        return 0
    fi

    local rx_mbit tx_mbit
    rx_mbit=$(awk -v b="$d_rx" -v s="$d_sec" 'BEGIN{printf "%.2f", b*8/s/1000000}')
    tx_mbit=$(awk -v b="$d_tx" -v s="$d_sec" 'BEGIN{printf "%.2f", b*8/s/1000000}')

    local sp rx_pct="" tx_pct=""
    if sp=$(link_speed "$IFACE"); then
        rx_pct=$(awk -v m="$rx_mbit" -v s="$sp" 'BEGIN{printf "%d", m*100/s}')
        tx_pct=$(awk -v m="$tx_mbit" -v s="$sp" 'BEGIN{printf "%d", m*100/s}')
    fi

    local csv="$RESULTS_DIR/${NAME}.csv"
    [[ -f "$csv" ]] || echo "timestamp,rx_mbit,tx_mbit,rx_pct,tx_pct" > "$csv"
    echo "${NOW},${rx_mbit},${tx_mbit},${rx_pct:--},${tx_pct:--}" >> "$csv"

    axis_update "$NAME" rx "$rx_mbit" "${MAX_RX_MBIT:-0}" "$rx_pct"
    axis_update "$NAME" tx "$tx_mbit" "${MAX_TX_MBIT:-0}" "$tx_pct"

    if [[ -n "$verbose" ]]; then
        printf '%-14s %-10s RX %8s Mbit/s   TX %8s Mbit/s%s\n' \
            "$NAME" "$IFACE" "$rx_mbit" "$tx_mbit" \
            "$([[ -n "$rx_pct" ]] && echo "   (${rx_pct}%/${tx_pct}% of the link)")"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Check run
# ---------------------------------------------------------------------------
run_check() {
    local verbose=${1:-}
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    make_dirs

    # Two runs at once would each consume the other's counters and compute
    # nonsense rates. Without flock it simply runs - better than not running.
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "$(date '+%F %T') run skipped (lock)" >> "$RUN_LOG"
            return 0
        fi
    fi

    NOW=$(date '+%F %T')
    local host; host=$(hostname -f 2>/dev/null || hostname)
    RC=0

    if ! ls "$IFACES_DIR"/*.conf &>/dev/null; then
        [[ -n "$verbose" ]] && echo "No interfaces created."
        return 0
    fi

    local -a changes=() worst=()
    local f
    for f in "$IFACES_DIR"/*.conf; do
        check_one "$f" "$verbose"
    done

    if (( ${#changes[@]} > 0 )); then
        local body
        body="Network throughput on ${host}"$'\n'"As of: ${NOW}"$'\n'
        body+=$'\n'"Changes:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Interfaces:"$'\n'
        body+=$(list_ifaces | sed 's/^/  /')

        local subject="[net] ${host}: ${changes[0]}"
        (( ${#changes[@]} > 1 )) && subject+=" (+$(( ${#changes[@]} - 1 )) more)"

        notify "$subject" "$body"
        [[ -n "$verbose" ]] && { echo; echo "$body"; } || true
    elif [[ -n "$verbose" ]]; then
        echo
        echo "No state change - no mail would be sent."
    fi

    echo "$(date '+%F %T') run finished, ${#changes[@]} change(s)" >> "$RUN_LOG"
    tail -n 2000 "$RUN_LOG" > "$RUN_LOG.tmp" 2>/dev/null && mv "$RUN_LOG.tmp" "$RUN_LOG"

    prune_old
    return $RC
}

prune_old() {
    local cutoff csv
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    ls "$RESULTS_DIR"/*.csv &>/dev/null || return 0
    for csv in "$RESULTS_DIR"/*.csv; do
        awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$csv" > "$csv.tmp" && mv "$csv.tmp" "$csv"
    done
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
show_status() {
    if ! is_setup; then
        echo "net-monitor: not set up"
        return 0
    fi
    list_ifaces
    echo
    echo "Alert only after ${N_CONSEC} readings in a row, every ${INTERVAL_MIN} min"
}

show_results() {
    echo "--- Entries ---"; list_ifaces; echo
    read -rp "Name (empty = back): " N
    [[ -n "$N" ]] || return
    local csv="$RESULTS_DIR/${N}.csv"
    [[ -f "$csv" ]] || { echo "No samples for '$N'."; pause; return; }

    echo
    column -t -s, "$csv" 2>/dev/null | tail -n 21 || tail -n 21 "$csv"
    echo
    awk -F, 'NR>1 {r+=$2; t+=$3; n++; if ($2>rx) rx=$2; if ($3>tx) tx=$3}
             END {if (n) printf "Mean over %d samples: RX %.2f Mbit/s (max %.2f), TX %.2f Mbit/s (max %.2f)\n",
                                 n, r/n, rx, t/n, tx}' "$csv"
    pause
}

show_alerts() {
    echo "--- Last state changes ---"
    tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(none)"
    pause
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo ">>> Settings for net-monitor"
    echo

    local D I NC R M WH
    read -rp "Gap between checks in minutes [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    echo
    echo "A backup or an image pull saturates the line for a few minutes without"
    echo "anything being wrong. Only this many readings in a row above the"
    echo "threshold count as an incident."
    read -rp "Readings in a row before an alert [${N_CONSEC}]: " NC
    N_CONSEC=${NC:-$N_CONSEC}
    (( N_CONSEC < 1 )) && N_CONSEC=1
    echo "  -> alert after about $(( N_CONSEC * INTERVAL_MIN )) minutes of sustained traffic"

    echo
    ask_alert_mail || return 1

    read -rp "Keep samples for (days) [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    BASE="$DATA_DIR/net"
    IFACES_DIR="$BASE/ifaces.d"
    STATE_DIR="$BASE/state"
    LOG_DIR="$BASE/log"
    RESULTS_DIR="$BASE/results"
    LOCK_FILE="$BASE/.lock"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/net.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Check: every ${INTERVAL_MIN} min   ($CRON_FILE)"
    echo ">>> Set up. Add the interfaces to watch through menu item 1."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall net-monitor"
    echo
    local n=0
    [[ -d "$IFACES_DIR" ]] && n=$(ls "$IFACES_DIR"/*.conf 2>/dev/null | wc -l)
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (every ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -d "$BASE" ]]      && echo "  - data $BASE (${n} interface(s), samples, state, alert log)   [asked]"
    echo
    echo "No packages were installed, nothing is left behind."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup net-monitor "$CONF" "$BASE" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -d "$BASE" ]] && confirm "Delete the interfaces, samples and state in $BASE as well?"; then
        rm -rf "$BASE"
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
        echo " Network throughput monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Cron:      $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo '!!! not installed')"
            echo "Alerts to: ${ALERT_MAIL:-(no mail)}"
            echo
            list_ifaces
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Manage interfaces"
        echo "2) Check all now"
        echo "3) Show samples and statistics"
        echo "4) Show alerts"
        echo "5) Settings"
        echo "6) Uninstall"
        echo "7) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) is_setup || configure; iface_menu ;;
            2) is_setup || configure; echo; run_check verbose; echo; pause ;;
            3) is_setup || configure; show_results ;;
            4) show_alerts ;;
            5) configure ;;
            6) uninstall ;;
            7) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--check|--status|--uninstall|--version]"; exit 1 ;;
esac
