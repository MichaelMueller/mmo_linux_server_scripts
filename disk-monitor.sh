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
FREE_MIN_GB=""           # set below: the general threshold, in GB free
# Filesystems below this total size are not watched at all. /boot is 2-4 GB and
# /boot/efi half of one - with a 10 GB threshold they would report "low" for
# ever, which is the fastest way to teach someone to ignore the alerts.
MIN_FS_SIZE_GB=20
# Threshold per mountpoint, overriding FREE_MIN_GB. An entry here also means the
# filesystem is watched regardless of MIN_FS_SIZE_GB: naming it explicitly is a
# decision, and a decision beats a blanket rule.
declare -A MOUNT_MIN_GB=()
DATA_DIR="$DIR/var"
INTERVAL_MIN=60          # gap between checks, in minutes
INODE_WARN=90            # inodes % that also counts as full; 0 = off
EXCLUDE=""               # mountpoints, space-separated
RETENTION_DAYS=90
TOP_DIRS=1               # write the largest directories into the alert
ALERT_MAIL=""

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

# Serialises MOUNT_MIN_GB back into the conf file. printf %q on the key, so a
# mountpoint containing spaces survives the round trip.
dump_mount_thresholds() {
    local k
    printf 'declare -A MOUNT_MIN_GB=('
    for k in "${!MOUNT_MIN_GB[@]}"; do
        printf ' [%q]="%s"' "$k" "${MOUNT_MIN_GB[$k]}"
    done
    printf ' )\n'
}

# The threshold that applies to a mountpoint: its own if it has one, otherwise
# the general value.
threshold_for() {
    echo "${MOUNT_MIN_GB[$1]:-$FREE_MIN_GB}"
}

# Is this filesystem watched at all? Everything from MIN_FS_SIZE_GB total size
# on - plus anything that was given a threshold of its own, because naming a
# filesystem explicitly is a decision and a decision beats the blanket rule.
# That is how a deliberately watched /boot gets in.
monitored() {
    local mnt=$1 total=$2
    # Root is always watched, whatever its size. A small VPS has a 15 or 20 GB
    # root, so the size filter would drop exactly the filesystem whose running
    # full takes the whole machine with it.
    [[ "$mnt" == "/" ]] && return 0
    [[ -n "${MOUNT_MIN_GB[$mnt]:-}" ]] && return 0
    awk -v t="$total" -v m="$MIN_FS_SIZE_GB" 'BEGIN{exit !(t >= m)}'
}

is_setup() { [[ -f "$CONF" ]]; }

make_dirs() { mkdir -p "$STATE_DIR" "$LOG_DIR" "$(dirname "$RESULTS")"; }

save_conf() {
    cat > "$CONF" <<EOF
# disk-monitor configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
FREE_MIN_GB=${FREE_MIN_GB}
MIN_FS_SIZE_GB=${MIN_FS_SIZE_GB}
$(dump_mount_thresholds)
INODE_WARN=${INODE_WARN}
EXCLUDE="${EXCLUDE}"
RETENTION_DAYS=${RETENTION_DAYS}
TOP_DIRS=${TOP_DIRS}
ALERT_MAIL="${ALERT_MAIL}"
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
    local thr; thr=$(threshold_for "$mnt")
    STATE=ok
    REASON=""

    if awk -v f="$free" -v m="$thr" 'BEGIN{exit !(f < m)}'; then
        STATE=low
        REASON="only ${free} GB free (below ${thr} GB)"
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
    local thr; thr=$(threshold_for "$mnt")
    awk -F, -v m="$mnt" -v thr="$thr" '
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
        # Too small to be worth watching and not explicitly named: skip it
        # entirely, no sample and no state, so it cannot alert either.
        monitored "$mnt" "$total" || continue

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
    printf '%-24s %9s %9s %8s  %-4s %s\n' \
        "MOUNTPOINT" "FREE GB" "TOTAL GB" "ALERT<" "STATE" "TREND"
    printf '%-24s %9s %9s %8s  %-4s %s\n' \
        "------------------------" "---------" "---------" "--------" "----" "-----"
    local mnt pct ipct free total skipped=0
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        if ! monitored "$mnt" "$total"; then
            printf '%-24s %9s %9s %8s  %s\n' \
                "$mnt" "$free" "$total" "-" "not watched (below ${MIN_FS_SIZE_GB} GB total)"
            skipped=1
            continue
        fi
        evaluate "$mnt" "$pct" "$ipct" "$free"
        printf '%-24s %9s %9s %8s  %-4s %s\n' \
            "$mnt" "$free" "$total" "$(threshold_for "$mnt")" "$STATE" "$(forecast "$mnt")"
    done < <(collect)

    echo
    echo "Alert below ${FREE_MIN_GB} GB free by default; watched from ${MIN_FS_SIZE_GB} GB total size on."
    (( skipped == 1 )) && echo "A threshold of its own (menu item 3) also brings a smaller filesystem in."
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

    local G S M mnt pct ipct free total thr in
    local -a watch=() small=()

    # Step 1: show what is actually mounted. Nothing has to be typed in here -
    # the filesystems come from df, so a disk added later is found by itself.
    echo "--- Filesystems found ---"
    printf '  %-24s %9s %9s\n' "MOUNTPOINT" "FREE GB" "TOTAL GB"
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        printf '  %-24s %9s %9s\n' "$mnt" "$free" "$total"
    done < <(collect)
    echo
    echo "(Pseudo filesystems - tmpfs, snap, Docker overlays - are never in here.)"

    # Step 2: the size filter. Small system partitions are the reason this
    # exists: /boot has 2-4 GB in total, so a 10 GB threshold would report it
    # as low for ever and train you to ignore the alerts.
    echo
    echo "--- Which of them to watch ---"
    echo "Filesystems below a certain total size are not worth watching: /boot"
    echo "has 2-4 GB altogether, /boot/efi half a gigabyte, and any sensible"
    echo "threshold would mark them low permanently."
    echo "/ is always watched, whatever its size."
    read -rp "Watch filesystems from this total size on (GB) [${MIN_FS_SIZE_GB}]: " S
    MIN_FS_SIZE_GB=${S:-$MIN_FS_SIZE_GB}
    while [[ ! "$MIN_FS_SIZE_GB" =~ ^[0-9]+$ ]]; do
        read -rp "  -> a whole number of GB (0 = watch everything): " MIN_FS_SIZE_GB
    done

    # Step 3: the general threshold. It also applies to filesystems that only
    # appear later, which is why it is asked separately from the per-mount ones.
    echo
    echo "--- Threshold ---"
    echo "Applies to every watched filesystem, including ones mounted later."
    read -rp "Alert below how many GB free? [${FREE_MIN_GB}]: " G
    FREE_MIN_GB=${G:-$FREE_MIN_GB}
    while [[ ! "$FREE_MIN_GB" =~ ^[0-9]+$ ]] || (( FREE_MIN_GB < 1 )); do
        read -rp "  -> a whole number of GB, at least 1: " FREE_MIN_GB
    done

    # Step 4: per mountpoint. Sort the filesystems into those the size filter
    # lets through and those it does not - the second group can still be pulled
    # in by giving it a value.
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        if [[ "$mnt" == "/" ]] || awk -v t="$total" -v m="$MIN_FS_SIZE_GB" 'BEGIN{exit !(t >= m)}'; then
            watch+=("$mnt|$total")
        else
            small+=("$mnt|$total")
        fi
    done < <(collect)

    echo
    echo "--- Per mountpoint ---"
    echo "Enter to keep the general ${FREE_MIN_GB} GB. A backup disk may want"
    echo "100, a small root 5."
    for in in "${watch[@]}"; do
        mnt=${in%|*}; total=${in##*|}
        thr=$(threshold_for "$mnt")
        read -rp "  ${mnt} (${total} GB total), alert below [${thr}] GB: " G
        G=${G:-$thr}
        while [[ ! "$G" =~ ^[0-9]+$ ]] || (( G < 1 )); do
            read -rp "    -> a whole number of GB, at least 1: " G
        done
        # Only store what differs from the general value, so the conf stays
        # readable and a later change of FREE_MIN_GB still reaches these.
        if (( G == FREE_MIN_GB )); then
            unset "MOUNT_MIN_GB[$mnt]"
        else
            MOUNT_MIN_GB["$mnt"]=$G
        fi
    done

    if (( ${#small[@]} > 0 )); then
        echo
        echo "Below ${MIN_FS_SIZE_GB} GB and therefore not watched. A value here"
        echo "watches one anyway; Enter leaves it out."
        for in in "${small[@]}"; do
            mnt=${in%|*}; total=${in##*|}
            thr=${MOUNT_MIN_GB[$mnt]:-}
            read -rp "  ${mnt} (${total} GB total), alert below [${thr:-off}] GB: " G
            G=${G:-$thr}
            if [[ -z "$G" ]]; then
                unset "MOUNT_MIN_GB[$mnt]"
                continue
            fi
            while [[ ! "$G" =~ ^[0-9]+$ ]] || (( G < 1 )); do
                read -rp "    -> a whole number of GB, at least 1 (empty = leave out): " G
                [[ -z "$G" ]] && break
            done
            [[ -z "$G" ]] && { unset "MOUNT_MIN_GB[$mnt]"; continue; }
            MOUNT_MIN_GB["$mnt"]=$G
        done
    fi

    echo
    ask_alert_mail || return 1

    echo
    echo "Checked every ${INTERVAL_MIN} min, samples kept ${RETENTION_DAYS} days,"
    echo "excluded: ${EXCLUDE:-nothing}. All of that lives in ${CONF} and rarely"
    echo "needs touching - menu item 3 manages the exclusions."

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
    echo "Watched:  filesystems from ${MIN_FS_SIZE_GB} GB total size on"
    echo "Alert:    below ${FREE_MIN_GB} GB free"
    if (( ${#MOUNT_MIN_GB[@]} > 0 )); then
        local k
        for k in "${!MOUNT_MIN_GB[@]}"; do
            printf "          %s: below %s GB\n" "$k" "${MOUNT_MIN_GB[$k]}"
        done
    fi
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
            echo "Alert:      below ${FREE_MIN_GB} GB free (${#MOUNT_MIN_GB[@]} of their own), watched from ${MIN_FS_SIZE_GB} GB up"
            echo "Cron:       $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo '!!! not installed')"
            echo "Alerts to:  ${ALERT_MAIL:-(no mail)}"
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
