#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# resource-monitor.sh - watch sustained CPU and RAM load, alert on a state change
# Modes: (no argument) = interactive menu
#        --check       = one run (for cron)
#        --status      = current load on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.4.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/resource-monitor.conf"
CRON_FILE=/etc/cron.d/resource-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5           # gap between checks, in minutes
CPU_WARN=85              # busy % across the interval
CPU_CRIT=95
MEM_WARN=85              # used % (MemAvailable against MemTotal)
MEM_CRIT=95
SWAP_RATE_WARN=200       # swapped pages per second, in+out; 0 = check off
N_CONSEC=3               # readings above the threshold before an alert
RETENTION_DAYS=30
TOP_PROCS=1              # write the biggest processes into the alert
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

STATE_DIR="$DATA_DIR/resources/state"
LOG_DIR="$DATA_DIR/resources/log"
RESULTS="$DATA_DIR/resources/results/resources.csv"
COUNTER_FILE="$STATE_DIR/counters"
LOCK_FILE="$DATA_DIR/resources/.lock"
ALERT_LOG="$LOG_DIR/alerts.log"
RUN_LOG="$LOG_DIR/resources.log"

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
    ALERT_MAIL=${M:-$ALERT_MAIL}
    [[ -z "$ALERT_MAIL" ]] && echo "  (no address given - alerts only go to the alert log)"
    return 0
}

is_setup() { [[ -f "$CONF" ]]; }

make_dirs() { mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$RESULTS")"; }

save_conf() {
    cat > "$CONF" <<EOF
# resource-monitor configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
CPU_WARN=${CPU_WARN}
CPU_CRIT=${CPU_CRIT}
MEM_WARN=${MEM_WARN}
MEM_CRIT=${MEM_CRIT}
SWAP_RATE_WARN=${SWAP_RATE_WARN}
N_CONSEC=${N_CONSEC}
RETENTION_DAYS=${RETENTION_DAYS}
TOP_PROCS=${TOP_PROCS}
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
# resource-monitor - CPU and RAM monitoring
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$(cron_spec) root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------
# Everything here is a delta between two runs, and that is the whole point of
# this tool: a momentary reading tells you what the machine is doing in this
# instant, which for "is it constantly under load?" is exactly the wrong
# question. /proc/stat counts jiffies since boot, so the difference against the
# previous run is the average across the entire interval - one hard-working
# minute inside a quiet hour disappears in it, as it should.
#
# Sets: R_CPU R_IOWAIT R_MEM R_SWAP_RATE R_SWAP_USED_PCT R_HAVE_PREV
read_counters() {
    R_HAVE_PREV=0
    R_CPU=0; R_IOWAIT=0; R_SWAP_RATE=0

    local now_s cpu_line user nice system idle iowait irq softirq steal
    now_s=$(date +%s)

    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    local busy_now total_now
    busy_now=$(( user + nice + system + irq + softirq + steal ))
    total_now=$(( busy_now + idle + iowait ))

    local sw_now
    sw_now=$(awk '/^pswpin |^pswpout /{s+=$2} END{print s+0}' /proc/vmstat)

    # RAM is a level, not a counter - it needs no previous value.
    local memtotal memavail swaptotal swapfree
    memtotal=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    memavail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    swaptotal=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swapfree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    : "${memtotal:=0}" "${memavail:=0}" "${swaptotal:=0}" "${swapfree:=0}"

    if (( memtotal > 0 )); then
        R_MEM=$(( (memtotal - memavail) * 100 / memtotal ))
    else
        R_MEM=0
    fi
    if (( swaptotal > 0 )); then
        R_SWAP_USED_PCT=$(( (swaptotal - swapfree) * 100 / swaptotal ))
    else
        R_SWAP_USED_PCT=0
    fi

    if [[ -f "$COUNTER_FILE" ]]; then
        local p_time p_busy p_total p_iow p_sw
        IFS='|' read -r p_time p_busy p_total p_iow p_sw < "$COUNTER_FILE"
        local d_total=$(( total_now - ${p_total:-0} ))
        local d_busy=$(( busy_now - ${p_busy:-0} ))
        local d_iow=$(( iowait - ${p_iow:-0} ))
        local d_sw=$(( sw_now - ${p_sw:-0} ))
        local d_sec=$(( now_s - ${p_time:-0} ))

        # A counter that went backwards means a reboot: the jiffies start at
        # zero again. Reporting that as a negative or absurd load would be a
        # lie, so the sample is dropped and only the baseline renewed.
        if (( d_total > 0 && d_busy >= 0 && d_sec > 0 )); then
            R_CPU=$(( d_busy * 100 / d_total ))
            (( R_CPU > 100 )) && R_CPU=100
            (( d_iow >= 0 )) && R_IOWAIT=$(( d_iow * 100 / d_total ))
            (( d_sw < 0 )) && d_sw=0
            R_SWAP_RATE=$(( d_sw / d_sec ))
            R_HAVE_PREV=1
        fi
    fi

    echo "${now_s}|${busy_now}|${total_now}|${iowait}|${sw_now}" > "$COUNTER_FILE"
}

# ---------------------------------------------------------------------------
# Assessment
# ---------------------------------------------------------------------------
# Sets the globals STATE and REASON for one axis.
evaluate_cpu() {
    local pct=$1
    STATE=ok; REASON=""
    if (( pct >= CPU_CRIT )); then
        STATE=crit; REASON="CPU ${pct}% >= ${CPU_CRIT}%"
    elif (( pct >= CPU_WARN )); then
        STATE=warn; REASON="CPU ${pct}% >= ${CPU_WARN}%"
    fi
    (( R_IOWAIT >= 20 )) && REASON="${REASON:+$REASON; }iowait ${R_IOWAIT}%"
}

# Swap occupancy is not a problem in itself - a few hundred MB parked there and
# never touched again costs nothing. What hurts is swap *traffic*: pages going
# in and out continuously means the machine is short of memory right now and is
# spending its time moving pages instead of working. Hence the rate, not the
# fill level, is an alerting criterion; the fill level is only reported.
evaluate_mem() {
    local pct=$1 rate=$2
    STATE=ok; REASON=""
    if (( pct >= MEM_CRIT )); then
        STATE=crit; REASON="RAM ${pct}% >= ${MEM_CRIT}%"
    elif (( pct >= MEM_WARN )); then
        STATE=warn; REASON="RAM ${pct}% >= ${MEM_WARN}%"
    fi
    if (( SWAP_RATE_WARN > 0 && rate >= SWAP_RATE_WARN )); then
        [[ "$STATE" == "ok" ]] && STATE=warn
        REASON="${REASON:+$REASON; }swapping ${rate} pages/s (>= ${SWAP_RATE_WARN})"
    fi
}

top_procs() {
    local by=$1
    if [[ "$by" == "mem" ]]; then
        echo "  Biggest processes by memory:"
        ps -eo pid,user,comm,pcpu,pmem --sort=-pmem 2>/dev/null | head -n 11 | sed 's/^/    /'
    else
        echo "  Biggest processes by CPU:"
        ps -eo pid,user,comm,pcpu,pmem --sort=-pcpu 2>/dev/null | head -n 11 | sed 's/^/    /'
    fi
}

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
# The debounce counter is what separates this tool from the other monitors. A
# compile job, a backup, a nightly import - all of them push the CPU to 100 %
# for a while, and none of them is an incident. The state therefore only moves
# once N_CONSEC readings in a row were above the threshold; a single reading
# back inside the range resets the counter to zero. At the default (5 min
# interval, 3 readings) that is a quarter of an hour of genuinely sustained
# load before anyone is woken up.
#
# Appends to the global arrays 'changes' and 'worst'.
axis_update() {
    local axis=$1 value=$2 new_state=$3 reason=$4 label=$5

    local sf="$STATE_DIR/${axis}.state"
    local prev="-" consec=0
    if [[ -f "$sf" ]]; then
        IFS='|' read -r prev _ _ consec < "$sf"
        prev=${prev:--}
        consec=${consec:-0}
        [[ "$consec" =~ ^[0-9]+$ ]] || consec=0
    fi

    if [[ "$new_state" == "ok" ]]; then
        consec=0
    else
        consec=$(( consec + 1 ))
    fi

    # Below the debounce threshold the breach is recorded but not yet acted on:
    # the effective state stays what it was, so nothing is reported.
    local eff="$new_state"
    if [[ "$new_state" != "ok" ]] && (( consec < N_CONSEC )); then
        if [[ "$prev" == "-" ]]; then eff="ok"; else eff="$prev"; fi
    fi

    printf '%s|%s|%s|%s\n' "$eff" "$NOW" "$value" "$consec" > "$sf"

    [[ "$eff" != "ok" ]] && RC=1

    # A first reading in the normal state is not an incident.
    if [[ "$prev" == "-" && "$eff" == "ok" ]]; then return 0; fi

    if [[ "$prev" != "$eff" ]]; then
        if [[ "$eff" == "ok" ]]; then
            changes+=("RECOVERED ${label}: back below the threshold (${value})")
        else
            changes+=("${eff^^} ${label}: ${reason}")
            worst+=("$axis")
        fi
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

    # Two runs at once would each see the other's counters and compute nonsense
    # deltas. Without flock it simply runs - that is better than not running.
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

    read_counters

    # The very first run has nothing to compare against: counters were just
    # written, a delta needs two points. Record and leave.
    if (( R_HAVE_PREV == 0 )); then
        echo "$(date '+%F %T') baseline recorded, no evaluation yet" >> "$RUN_LOG"
        if [[ -n "$verbose" ]]; then
            echo "First run - counters recorded. The next run can compare and evaluate."
        fi
        return 0
    fi

    [[ -f "$RESULTS" ]] || echo "timestamp,cpu_pct,iowait_pct,mem_pct,swap_rate" > "$RESULTS"
    echo "${NOW},${R_CPU},${R_IOWAIT},${R_MEM},${R_SWAP_RATE}" >> "$RESULTS"

    local -a changes=() worst=()
    local body=""

    evaluate_cpu "$R_CPU"
    axis_update cpu "${R_CPU}%" "$STATE" "$REASON" "CPU"

    evaluate_mem "$R_MEM" "$R_SWAP_RATE"
    axis_update mem "${R_MEM}%" "$STATE" "$REASON" "RAM"

    if [[ -n "$verbose" ]]; then
        printf 'CPU  %3s%%   (iowait %s%%)\n' "$R_CPU" "$R_IOWAIT"
        printf 'RAM  %3s%%   swap used %s%%, %s pages/s\n' \
            "$R_MEM" "$R_SWAP_USED_PCT" "$R_SWAP_RATE"
    fi

    if (( ${#changes[@]} > 0 )); then
        body="Resource load on ${host}"$'\n'"As of: ${NOW}"$'\n'
        body+=$'\n'"Changes:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Current:"$'\n'
        body+="  CPU ${R_CPU}% (iowait ${R_IOWAIT}%), averaged over the last ${INTERVAL_MIN} min"$'\n'
        body+="  RAM ${R_MEM}%, swap ${R_SWAP_USED_PCT}% used, ${R_SWAP_RATE} pages/s"$'\n'
        body+="  Load average: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

        # The expensive evidence is only collected for the axis that actually
        # alerted - and only if it was asked for.
        if (( TOP_PROCS == 1 )); then
            local a
            for a in "${worst[@]}"; do
                case "$a" in
                    cpu) body+=$'\n\n'"$(top_procs cpu)" ;;
                    mem) body+=$'\n\n'"$(top_procs mem)" ;;
                esac
            done
        fi

        local subject
        if (( ${#worst[@]} > 0 )); then
            subject="[resources] ${host}: ${changes[0]}"
        else
            subject="[resources] ${host}: recovered"
        fi
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
    [[ -f "$RESULTS" ]] || return 0
    local cutoff
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$RESULTS" > "$RESULTS.tmp" \
        && mv "$RESULTS.tmp" "$RESULTS"
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
axis_line() {
    local axis=$1 label=$2
    local sf="$STATE_DIR/${axis}.state"
    local st="-" ts="" val="-" consec=0
    [[ -f "$sf" ]] && IFS='|' read -r st ts val consec < "$sf"
    printf '%-6s %-8s %-6s %s\n' "$label" "${val:--}" "${st:--}" \
        "$( (( ${consec:-0} > 0 )) && echo "${consec}/${N_CONSEC} above the threshold" || echo "" )"
}

show_status() {
    if ! is_setup; then
        echo "resource-monitor: not set up"
        return 0
    fi
    printf '%-6s %-8s %-6s %s\n' "AXIS" "LAST" "STATE" "NOTE"
    printf '%-6s %-8s %-6s %s\n' "------" "--------" "------" "----"
    axis_line cpu "CPU"
    axis_line mem "RAM"
    echo
    echo "Thresholds: CPU warn ${CPU_WARN}% crit ${CPU_CRIT}%, RAM warn ${MEM_WARN}% crit ${MEM_CRIT}%"
    echo "Alert only after ${N_CONSEC} readings in a row, every ${INTERVAL_MIN} min"
}

show_results() {
    echo "--- Last samples ---"
    if [[ -f "$RESULTS" ]]; then
        column -t -s, "$RESULTS" 2>/dev/null | tail -n 21 || tail -n 21 "$RESULTS"
        echo
        awk -F, 'NR>1 {c+=$2; m+=$4; n++; if ($2>cx) cx=$2; if ($4>mx) mx=$4}
                 END {if (n) printf "Mean over %d samples: CPU %.1f%% (max %d%%), RAM %.1f%% (max %d%%)\n",
                                     n, c/n, cx, m/n, mx}' "$RESULTS"
    else
        echo "(no samples yet)"
    fi
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
    echo ">>> Settings for resource-monitor"
    echo

    local D I CW CC MW MC SR NC R M WH
    read -rp "Gap between checks in minutes [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    echo
    echo "--- CPU ---"
    echo "Measured is the average across the whole interval, not a momentary"
    echo "value - that is what makes it 'constant' load."
    read -rp "Warn from a CPU load of % [${CPU_WARN}]: " CW; CPU_WARN=${CW:-$CPU_WARN}
    read -rp "Critical from a CPU load of % [${CPU_CRIT}]: " CC; CPU_CRIT=${CC:-$CPU_CRIT}
    if (( CPU_CRIT <= CPU_WARN )); then
        echo "!!! Critical has to be above warning - setting it to $((CPU_WARN + 5))."
        CPU_CRIT=$((CPU_WARN + 5))
    fi

    echo
    echo "--- RAM ---"
    read -rp "Warn from a memory usage of % [${MEM_WARN}]: " MW; MEM_WARN=${MW:-$MEM_WARN}
    read -rp "Critical from a memory usage of % [${MEM_CRIT}]: " MC; MEM_CRIT=${MC:-$MEM_CRIT}
    if (( MEM_CRIT <= MEM_WARN )); then
        echo "!!! Critical has to be above warning - setting it to $((MEM_WARN + 5))."
        MEM_CRIT=$((MEM_WARN + 5))
    fi
    echo
    echo "Swap that merely sits there is harmless. What hurts is constant paging"
    echo "in and out - that is the machine running out of memory right now."
    read -rp "Warn from swapped pages per second (0 = off) [${SWAP_RATE_WARN}]: " SR
    SWAP_RATE_WARN=${SR:-$SWAP_RATE_WARN}

    echo
    echo "--- Debounce ---"
    echo "A backup or a build pushes the CPU to 100 % without anything being"
    echo "wrong. Only this many readings in a row above the threshold count as"
    echo "an incident."
    read -rp "Readings in a row before an alert [${N_CONSEC}]: " NC
    N_CONSEC=${NC:-$N_CONSEC}
    (( N_CONSEC < 1 )) && N_CONSEC=1
    echo "  -> alert after about $(( N_CONSEC * INTERVAL_MIN )) minutes of sustained load"

    echo
    ask_alert_mail || return 1

    echo
    confirm "Write the biggest processes into the alert (ps)?" \
        "$([[ $TOP_PROCS -eq 1 ]] && echo Y || echo N)" && TOP_PROCS=1 || TOP_PROCS=0

    read -rp "Keep samples for (days) [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    STATE_DIR="$DATA_DIR/resources/state"
    LOG_DIR="$DATA_DIR/resources/log"
    RESULTS="$DATA_DIR/resources/results/resources.csv"
    COUNTER_FILE="$STATE_DIR/counters"
    LOCK_FILE="$DATA_DIR/resources/.lock"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/resources.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Check: every ${INTERVAL_MIN} min   ($CRON_FILE)"
    echo "Alert after ${N_CONSEC} readings in a row above the threshold."
    echo ">>> Set up."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall resource-monitor"
    echo
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (every ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -d "$DATA_DIR/resources" ]] && echo "  - data $DATA_DIR/resources (samples, state, alert log)   [asked]"
    echo
    echo "No packages were installed, nothing is left behind."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup resource-monitor "$CONF" "$DATA_DIR/resources" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -d "$DATA_DIR/resources" ]] \
        && confirm "Delete the sample history and state in $DATA_DIR/resources as well?"; then
        rm -rf "$DATA_DIR/resources"
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
        echo " CPU and RAM monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Cron:      $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo '!!! not installed')"
            echo "Alerts to: ${ALERT_MAIL:-(no mail)}"
            echo
            show_status
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Set up / edit settings"
        echo "2) Check now"
        echo "3) Show samples and statistics"
        echo "4) Show alerts"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || configure; echo; run_check verbose; echo; pause ;;
            3) is_setup || configure; show_results ;;
            4) show_alerts ;;
            5) uninstall ;;
            6) exit 0 ;;
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
