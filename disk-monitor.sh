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
VERSION="2.2.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/disk-monitor.conf"
CRON_FILE=/etc/cron.d/disk-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
# The one thing this tool is about: how much room is left on a filesystem.
# Everything else has a default and is not asked for - it can be edited in the
# conf file, but nobody should have to answer six questions to find out when a
# disk is running out.
FREE_MIN_GB=""           # set below: the alert threshold, in GB free
DATA_DIR="$DIR/var"
INTERVAL_MIN=60          # gap between checks, in minutes
INODE_WARN=90            # inodes % that also counts as full; 0 = off
EXCLUDE=""               # mountpoints, space-separated
RETENTION_DAYS=90
TOP_DIRS=1               # write the largest directories into the alert
ALERT_MAIL=""
ALERT_WEBHOOK=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# Configurations written before 2.2.0 sized the alert in percent (WARN_PCT,
# CRIT_PCT) and carried MIN_FREE_GB only as an optional extra bound. The
# criterion is now the free space itself, so an existing MIN_FREE_GB is taken
# over as the threshold rather than the file being declared invalid.
if [[ -z "$FREE_MIN_GB" ]]; then
    if [[ -n "${MIN_FREE_GB:-}" ]] && (( MIN_FREE_GB > 0 )); then
        FREE_MIN_GB=$MIN_FREE_GB
    else
        FREE_MIN_GB=10
    fi
fi

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
FREE_MIN_GB=${FREE_MIN_GB}
INODE_WARN=${INODE_WARN}
EXCLUDE="${EXCLUDE}"
RETENTION_DAYS=${RETENTION_DAYS}
TOP_DIRS=${TOP_DIRS}
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
#
# One criterion: the space left on the filesystem, in GB. Percentages are
# deliberately not part of it - 5 % of a 4 TB disk is 200 GB and perfectly
# fine, 5 % of a 20 GB root is one gigabyte and already too late. What you
# actually want to know is whether there is still room, and that is a number
# in GB, the same one for every filesystem.
evaluate() {
    local mnt=$1 pct=$2 ipct=$3 free=$4
    STATE=ok
    REASON=""

    if awk -v f="$free" -v m="$FREE_MIN_GB" 'BEGIN{exit !(f < m)}'; then
        STATE=low
        REASON="only ${free} GB free (below ${FREE_MIN_GB} GB)"
    fi

    # Inodes can be full while space is still free - then nothing works either,
    # and df -h shows none of it. Costs no question, so it stays; INODE_WARN=0
    # in the conf switches it off.
    if (( INODE_WARN > 0 && ipct >= INODE_WARN )); then
        [[ "$STATE" == "ok" ]] && STATE=low
        REASON="${REASON:+$REASON; }inodes ${ipct}% used"
    fi
}

# Linear extrapolation from the oldest and the newest sample, on the free space
# itself. Rough, but exactly the question you have when the alert arrives: how
# long do I have?
forecast() {
    local mnt=$1
    [[ -f "$RESULTS" ]] || return 0
    awk -F, -v m="$mnt" -v thr="$FREE_MIN_GB" '
        $2 == m {
            if (first == "") { first = $1; ff = $5 }
            last = $1; lf = $5
        }
        END {
            if (first == "" || first == last) exit
            cmd = "date -d \"" first "\" +%s"; cmd | getline t0; close(cmd)
            cmd = "date -d \"" last  "\" +%s"; cmd | getline t1; close(cmd)
            days = (t1 - t0) / 86400
            if (days < 1) exit
            rate = (ff - lf) / days          # GB lost per day
            if (rate <= 0.01) { printf "stable"; exit }
            if (lf <= thr) { printf "-%.2f GB/day, already below the threshold", rate; exit }
            printf "-%.2f GB/day, threshold in about %d days", rate, int((lf - thr) / rate)
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
        echo "${STATE}|${now}|${free}|${ipct}" > "$sf"

        [[ "$STATE" != "ok" ]] && rc=1

        if [[ -n "$verbose" ]]; then
            printf '%-24s free %8s GB of %8s GB   %-4s %s\n' \
                "$mnt" "$free" "$total" "$STATE" "$REASON"
        fi

        # A first reading in the normal state is not an incident.
        if [[ "$prev" == "-" && "$STATE" == "ok" ]]; then continue; fi

        if [[ "$prev" != "$STATE" ]]; then
            if [[ "$STATE" == "ok" ]]; then
                changes+=("RECOVERED ${mnt}: ${free} GB free again")
            else
                changes+=("LOW ${mnt}: ${REASON}")
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
    printf '%-24s %10s %10s  %-4s %s\n' \
        "MOUNTPOINT" "FREE GB" "TOTAL GB" "STATE" "TREND"
    printf '%-24s %10s %10s  %-4s %s\n' \
        "------------------------" "----------" "----------" "----" "-----"
    local mnt pct ipct free total
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        evaluate "$mnt" "$pct" "$ipct" "$free"
        printf '%-24s %10s %10s  %-4s %s\n' \
            "$mnt" "$free" "$total" "$STATE" "$(forecast "$mnt")"
    done < <(collect)

    echo
    echo "Alert below ${FREE_MIN_GB} GB free."
    if [[ -n "$EXCLUDE" ]]; then
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

    # Two questions, and the second one is optional. Everything else has a
    # default that is right on almost every server; all of it can still be
    # edited in disk-monitor.conf, it just does not need to be asked.
    local G M
    local OLD_DATA_DIR=$DATA_DIR

    echo "Alert when a filesystem has less than this much room left."
    echo "The same number applies to every filesystem - that is the point of"
    echo "measuring in GB rather than in percent."
    read -rp "Alert below how many GB free? [${FREE_MIN_GB}]: " G
    FREE_MIN_GB=${G:-$FREE_MIN_GB}
    while [[ ! "$FREE_MIN_GB" =~ ^[0-9]+$ ]] || (( FREE_MIN_GB < 1 )); do
        read -rp "  -> a whole number of GB, at least 1: " FREE_MIN_GB
    done

    echo
    read -rp "Mail address for alerts (empty = none) [${ALERT_MAIL}]: " M
    ALERT_MAIL=${M:-$ALERT_MAIL}

    echo
    echo "Checked every ${INTERVAL_MIN} min, samples kept ${RETENTION_DAYS} days,"
    echo "excluded: ${EXCLUDE:-nothing}. All of that lives in ${CONF} and rarely"
    echo "needs touching - menu item 3 manages the exclusions."

    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    RESULTS="$DATA_DIR/results/usage.csv"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/disk.log"

    # Without this the samples stay behind in the old directory and the history
    # starts from scratch, without anything saying why.
    if [[ "$DATA_DIR" != "$OLD_DATA_DIR" && -d "$OLD_DATA_DIR/state" ]]; then
        echo
        echo "So far the data lives in ${OLD_DATA_DIR}."
        if confirm "Move state, results and log to ${DATA_DIR}?" Y; then
            mkdir -p "$DATA_DIR"
            local sub
            for sub in state results log; do
                [[ -d "$OLD_DATA_DIR/$sub" ]] || continue
                if [[ -d "$DATA_DIR/$sub" ]]; then
                    cp -a "$OLD_DATA_DIR/$sub/." "$DATA_DIR/$sub/" && rm -rf "$OLD_DATA_DIR/$sub"
                else
                    mv "$OLD_DATA_DIR/$sub" "$DATA_DIR/$sub"
                fi
            done
            echo "Moved."
        else
            echo "Careful: the history stays in ${OLD_DATA_DIR} and is not read any more."
        fi
    fi

    make_dirs
    save_conf
    write_cron

    echo
    echo "Check: every ${INTERVAL_MIN} min   ($CRON_FILE)"
    echo "Alert below ${FREE_MIN_GB} GB free, on every filesystem."
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
            echo "Alert:      below ${FREE_MIN_GB} GB free"
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
