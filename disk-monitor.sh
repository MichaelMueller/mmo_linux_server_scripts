#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# disk-monitor.sh - watch disk space and alert on a state change
# Modes: (no argument) = interactive menu
#        --check       = one run (for cron)
#        --status      = usage on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.1.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/disk-monitor.conf"
CRON_FILE=/etc/cron.d/disk-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=60          # gap between checks, in minutes
WARN_PCT=85
CRIT_PCT=95
INODE_WARN=90
MIN_FREE_GB=0            # 0 = check off
EXCLUDE=""               # mountpoints, space-separated
RETENTION_DAYS=90
TOP_DIRS=1               # write the largest directories into the alert
ALERT_MODE="change"      # change | always
ALERT_MAIL=""
ALERT_WEBHOOK=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
RESULTS="$DATA_DIR/results/usage.csv"
ALERT_LOG="$LOG_DIR/alerts.log"
RUN_LOG="$LOG_DIR/disk.log"

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

is_setup() { [[ -f "$CONF" ]]; }

make_dirs() { mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$RESULTS")"; }

save_conf() {
    cat > "$CONF" <<EOF
# disk-monitor configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
WARN_PCT=${WARN_PCT}
CRIT_PCT=${CRIT_PCT}
INODE_WARN=${INODE_WARN}
MIN_FREE_GB=${MIN_FREE_GB}
EXCLUDE="${EXCLUDE}"
RETENTION_DAYS=${RETENTION_DAYS}
TOP_DIRS=${TOP_DIRS}
ALERT_MODE="${ALERT_MODE}"
ALERT_MAIL="${ALERT_MAIL}"
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
EOF
    chmod 644 "$CONF"
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# disk-monitor - disk space monitoring
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Collect the filesystems
# ---------------------------------------------------------------------------
# Pseudo filesystems are of no interest: tmpfs never runs "full" in the sense
# of a problem, and squashfs (snap) is 100 % used by definition.
PSEUDO='^(tmpfs|devtmpfs|squashfs|overlay|iso9660|efivarfs|proc|sysfs|cgroup2?|ramfs|autofs|fuse[.]snapfuse|nsfs|tracefs|debugfs|configfs|securityfs|pstore|bpf|hugetlbfs|mqueue|devpts)$'

excluded() {
    local m=$1 e
    for e in $EXCLUDE; do [[ "$m" == "$e" ]] && return 0; done
    return 1
}

# Prints one line per filesystem:  mountpoint|used%|inode%|free_gb|total_gb
#
# 'df --output' instead of the classic columns: that way the mountpoint is
# reliably at the end of the line (it may contain spaces and would otherwise
# shift every field), and the inode usage comes from the same call. The device
# is deliberately left out - it too can contain spaces, and it is not needed.
collect() {
    df -B1K --output=fstype,pcent,ipcent,avail,size,target 2>/dev/null \
    | awk -v p="$PSEUDO" '
        NR > 1 && $1 !~ p {
            pct = $2; sub(/%/, "", pct); if (pct == "-" || pct == "") pct = 0
            ip  = $3; sub(/%/, "", ip);  if (ip  == "-" || ip  == "") ip  = 0
            mnt = $6; for (i = 7; i <= NF; i++) mnt = mnt " " $i
            printf "%s|%s|%s|%.1f|%.1f\n", mnt, pct, ip, $4/1048576, $5/1048576
        }' \
    | while IFS='|' read -r mnt rest; do
        excluded "$mnt" && continue
        printf '%s|%s\n' "$mnt" "$rest"
      done
}

slug() { echo "${1//\//_}" | sed 's/^_$/root/; s/^_//'; }

# ---------------------------------------------------------------------------
# Assessment
# ---------------------------------------------------------------------------
# Sets the globals STATE and REASON.
evaluate() {
    local mnt=$1 pct=$2 ipct=$3 free=$4
    STATE=ok
    REASON=""

    if (( pct >= CRIT_PCT )); then
        STATE=crit; REASON="usage ${pct}% >= ${CRIT_PCT}%"
    elif (( pct >= WARN_PCT )); then
        STATE=warn; REASON="usage ${pct}% >= ${WARN_PCT}%"
    fi

    # Inodes can be full while space is still free - then nothing works either,
    # and df -h shows none of it.
    if (( ipct >= INODE_WARN )); then
        [[ "$STATE" == "ok" ]] && STATE=warn
        REASON="${REASON:+$REASON; }inodes ${ipct}% >= ${INODE_WARN}%"
    fi

    if (( MIN_FREE_GB > 0 )); then
        if awk -v f="$free" -v m="$MIN_FREE_GB" 'BEGIN{exit !(f < m)}'; then
            [[ "$STATE" == "ok" ]] && STATE=warn
            REASON="${REASON:+$REASON; }only ${free} GB free left (< ${MIN_FREE_GB} GB)"
        fi
    fi
}

# Linear extrapolation from the oldest and the newest sample.
# Rough, but exactly the question you have when a warning arrives: will it last?
forecast() {
    local mnt=$1
    [[ -f "$RESULTS" ]] || return 0
    awk -F, -v m="$mnt" '
        $2 == m {
            if (first == "") { first = $1; fp = $3 }
            last = $1; lp = $3
        }
        END {
            if (first == "" || first == last) exit
            cmd = "date -d \"" first "\" +%s"; cmd | getline t0; close(cmd)
            cmd = "date -d \"" last  "\" +%s"; cmd | getline t1; close(cmd)
            days = (t1 - t0) / 86400
            if (days < 1) exit
            rate = (lp - fp) / days
            if (rate <= 0.01) { printf "stable or falling (%.2f %%/day)", rate; exit }
            printf "+%.2f %%/day, full in about %d days", rate, int((100 - lp) / rate)
        }' "$RESULTS"
}

top_dirs() {
    local mnt=$1
    echo "  Largest directories under ${mnt} (max. 2 levels, no other filesystems):"
    du -x -h --max-depth=2 "$mnt" 2>/dev/null | sort -h | tail -n 12 | sed 's/^/    /'
}

notify() {
    local subject=$1 body=$2
    echo "$(date '+%F %T') ${subject}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":$(printf '%s' "$subject" | sed 's/"/\\"/g; s/^/"/; s/$/"/')}" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi
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
# Check run
# ---------------------------------------------------------------------------
run_check() {
    local verbose=${1:-}
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    make_dirs

    local now host mnt pct ipct free total prev
    now=$(date '+%F %T')
    host=$(hostname -f 2>/dev/null || hostname)

    [[ -f "$RESULTS" ]] || echo "timestamp,mount,pct,inode_pct,free_gb" > "$RESULTS"

    local -a changes=() worst=()
    local body="" rc=0

    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue

        evaluate "$mnt" "$pct" "$ipct" "$free"
        echo "${now},${mnt},${pct},${ipct},${free}" >> "$RESULTS"

        local sf="$STATE_DIR/$(slug "$mnt").state"
        prev="-"
        [[ -f "$sf" ]] && prev=$(cut -d'|' -f1 "$sf")
        echo "${STATE}|${now}|${pct}|${ipct}" > "$sf"

        [[ "$STATE" != "ok" ]] && rc=1

        if [[ -n "$verbose" ]]; then
            printf '%-24s %5s%%  inodes %4s%%  free %8s GB   %-5s %s\n' \
                "$mnt" "$pct" "$ipct" "$free" "$STATE" "$REASON"
        fi

        # A first reading in the normal state is not an incident.
        if [[ "$prev" == "-" && "$STATE" == "ok" ]]; then continue; fi

        if [[ "$prev" != "$STATE" || "$ALERT_MODE" == "always" ]]; then
            if [[ "$STATE" == "ok" ]]; then
                changes+=("RECOVERED ${mnt}: back below the threshold (${pct}%)")
            else
                changes+=("${STATE^^} ${mnt}: ${REASON}")
                worst+=("$mnt")
            fi
        fi
    done < <(collect)

    if (( ${#changes[@]} > 0 )); then
        body="Disk space on ${host}"$'\n'"As of: ${now}"$'\n'
        body+=$'\n'"Changes:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Usage:"$'\n'
        body+=$(df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/  /')

        local m fc
        for m in "${worst[@]}"; do
            fc=$(forecast "$m")
            body+=$'\n\n'"${m}"
            [[ -n "$fc" ]] && body+=$'\n'"  Trend: ${fc}"
            if (( TOP_DIRS == 1 )); then
                body+=$'\n'"$(top_dirs "$m")"
            fi
        done

        local subject
        if (( ${#worst[@]} > 0 )); then
            subject="[disk] ${host}: ${changes[0]}"
        else
            subject="[disk] ${host}: recovered"
        fi
        (( ${#changes[@]} > 1 )) && subject+=" (+$(( ${#changes[@]} - 1 )) more)"

        notify "$subject" "$body"
        [[ -n "$verbose" ]] && { echo; echo "$body"; } || true
    elif [[ -n "$verbose" ]]; then
        echo
        echo "No state change - no mail would be sent."
    fi

    {
        echo "$(date '+%F %T') run finished, $(printf '%s' "${#changes[@]}") change(s)"
    } >> "$RUN_LOG"
    tail -n 2000 "$RUN_LOG" > "$RUN_LOG.tmp" 2>/dev/null && mv "$RUN_LOG.tmp" "$RUN_LOG"

    prune_old
    return $rc
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
show_usage() {
    printf '%-24s %7s %8s %10s %10s  %-5s %s\n' \
        "MOUNTPOINT" "USED" "INODES" "FREE GB" "TOTAL GB" "STATE" "TREND"
    printf '%-24s %7s %8s %10s %10s  %-5s %s\n' \
        "------------------------" "-------" "--------" "----------" "----------" "-----" "-----"
    local mnt pct ipct free total
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        evaluate "$mnt" "$pct" "$ipct" "$free"
        printf '%-24s %6s%% %7s%% %10s %10s  %-5s %s\n' \
            "$mnt" "$pct" "$ipct" "$free" "$total" "$STATE" "$(forecast "$mnt")"
    done < <(collect)

    if [[ -n "$EXCLUDE" ]]; then
        echo
        echo "Excluded: $EXCLUDE"
    fi
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
    echo ">>> Settings for disk-monitor"
    echo

    local D I W C IN MF R T
    read -rp "Data directory [${DATA_DIR}]: " D; DATA_DIR=${D:-$DATA_DIR}
    read -rp "Gap between checks in minutes [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}

    echo
    read -rp "Warn from a usage of % [${WARN_PCT}]: " W; WARN_PCT=${W:-$WARN_PCT}
    read -rp "Critical from a usage of % [${CRIT_PCT}]: " C; CRIT_PCT=${C:-$CRIT_PCT}
    read -rp "Warn from an inode usage of % [${INODE_WARN}]: " IN; INODE_WARN=${IN:-$INODE_WARN}
    read -rp "Additionally warn below X GB free (0 = off) [${MIN_FREE_GB}]: " MF
    MIN_FREE_GB=${MF:-$MIN_FREE_GB}

    if (( CRIT_PCT <= WARN_PCT )); then
        echo "!!! Critical has to be above warning - setting it to $((WARN_PCT + 5))."
        CRIT_PCT=$((WARN_PCT + 5))
    fi

    echo
    echo "Alerting:"
    echo "  1) only on a state change (recommended)"
    echo "  2) on every run, as long as something is above the threshold"
    local A; read -rp "Choice [1]: " A
    [[ "${A:-1}" == "2" ]] && ALERT_MODE="always" || ALERT_MODE="change"

    read -rp "Mail address for alerts (empty = none) [${ALERT_MAIL}]: " M
    ALERT_MAIL=${M:-$ALERT_MAIL}
    read -rp "Webhook URL (empty = none) [${ALERT_WEBHOOK}]: " WH
    ALERT_WEBHOOK=${WH:-$ALERT_WEBHOOK}

    echo
    confirm "Write the largest directories into the alert (du, can take a while)?" \
        "$([[ $TOP_DIRS -eq 1 ]] && echo Y || echo N)" && TOP_DIRS=1 || TOP_DIRS=0

    read -rp "Keep samples for (days) [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    RESULTS="$DATA_DIR/results/usage.csv"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/disk.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Check: every ${INTERVAL_MIN} min   ($CRON_FILE)"
    echo "Thresholds: warn ${WARN_PCT}%, critical ${CRIT_PCT}%, inodes ${INODE_WARN}%"
    echo ">>> Set up."
    pause
}

edit_excludes() {
    while true; do
        clear
        echo "=== Excluded mountpoints ==="
        if [[ -z "$EXCLUDE" ]]; then echo "(none)"; else printf '  %s\n' $EXCLUDE; fi
        echo
        echo "Currently monitored:"
        collect | cut -d'|' -f1 | sed 's/^/  /'
        echo
        echo "1) Exclude a mountpoint"
        echo "2) Remove an exclusion"
        echo "3) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1) read -rp "Mountpoint: " M
               [[ -n "$M" ]] && EXCLUDE="${EXCLUDE:+$EXCLUDE }$M" && save_conf ;;
            2) read -rp "Mountpoint: " M
               EXCLUDE=$(echo "$EXCLUDE" | tr ' ' '\n' | grep -vxF "$M" | tr '\n' ' ')
               EXCLUDE=${EXCLUDE% }
               save_conf ;;
            3) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall disk-monitor"
    echo
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (every ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -d "$DATA_DIR" ]]  && echo "  - data directory $DATA_DIR (sample history, state, alert log)   [asked]"
    echo
    echo "No packages were installed, nothing is left behind."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup disk-monitor "$CONF" "$DATA_DIR" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Delete the sample history and state in $DATA_DIR as well?"; then
        rm -rf "$DATA_DIR"
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
        echo " Disk space monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Thresholds: warn ${WARN_PCT}%  critical ${CRIT_PCT}%  inodes ${INODE_WARN}%"
            echo "Cron:       $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo '!!! not installed')"
            echo "Alerts to:  ${ALERT_MAIL:-(no mail)}${ALERT_WEBHOOK:+ + webhook}"
            echo
            show_usage
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Set up / edit settings"
        echo "2) Check now"
        echo "3) Manage exclusions"
        echo "4) Show alerts"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || configure; echo; run_check verbose; echo; pause ;;
            3) is_setup || configure; edit_excludes ;;
            4) show_alerts ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --status)    show_usage ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--check|--status|--uninstall|--version]"; exit 1 ;;
esac
