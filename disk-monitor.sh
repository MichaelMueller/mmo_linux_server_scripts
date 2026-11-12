#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# disk-monitor.sh - watch disk space and alert on a state change
# Modes: (no argument) = interactive menu
#        --check       = one run (for cron)
#        --status      = usage on stdout
#        --setup       = run the setup dialogue once, without the menu
#        --uninstall   = uninstall
#
# Presets: a DEFAULT_* that is set is taken without a question (and wins over
# the stored value); unset ones are asked - in batch mode, BATCH=1, nothing is
# asked and every question takes its default:
#   DEFAULT_MIN_FS_SIZE_GB   list filesystems from this total size on (20)
#   DEFAULT_FS_SELECTION     'a' = all listed, or numbers / mountpoints,
#                            space- or comma-separated (a)
#   DEFAULT_FREE_MIN_GB      alert below this many GB free (5); also the
#                            threshold offered per filesystem
#   DEFAULT_MOUNT_MIN_GB     own thresholds, "MOUNT=GB ..." e.g. "/=5 /data=150" -
#                            the filesystems named are not asked
#                            (none: the general threshold)
#   DEFAULT_ALERT_MAIL       recipient, '-' = none (alert log only)
#   DEFAULT_NO_MAILER_OK     Y|N - set up even without a mailer (N)
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

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
# Presets of a caller (e.g. base-setup) win over the stored values.
[[ -n "${DEFAULT_ALERT_MAIL:-}" ]] && ALERT_MAIL=$DEFAULT_ALERT_MAIL
[[ "$ALERT_MAIL" == "-" ]] && ALERT_MAIL=""
[[ -n "${DEFAULT_MIN_FS_SIZE_GB:-}" ]] && MIN_FS_SIZE_GB=$DEFAULT_MIN_FS_SIZE_GB
[[ -n "${DEFAULT_FREE_MIN_GB:-}" ]] && FREE_MIN_GB=$DEFAULT_FREE_MIN_GB

# Configurations written before 2.2.0 sized the alert in percent (WARN_PCT,
# CRIT_PCT) and carried MIN_FREE_GB only as an optional extra bound. The
# criterion is now the free space itself, so an existing MIN_FREE_GB is taken
# over as the threshold rather than the file being declared invalid.
if [[ -z "$FREE_MIN_GB" ]]; then
    if [[ -n "${MIN_FREE_GB:-}" ]] && (( MIN_FREE_GB > 0 )); then
        FREE_MIN_GB=$MIN_FREE_GB
    else
        FREE_MIN_GB=5
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

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# Presets: a DEFAULT_* variable that is set (not empty) is a fixed value - its
# question is not asked, neither interactively nor in batch mode; the tool
# prints "<question>: <value> (preset)" instead. An invalid preset is an error.
# Unset ones are asked; in batch mode (BATCH=1, set by base-setup.sh) every
# such question takes its default - the built-in or stored one - and prints
# what it took. A required value without a default is an error.
# preset NAME -> 0 when the caller set that DEFAULT_* variable (non-empty)
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# preset_tag NAME -> " (preset)" when NAME is a preset, else nothing
preset_tag() { if preset "${1:-}"; then echo " (preset)"; fi; }
# yn_value VALUE -> Y or N; fails for anything that is not yes/no
yn_value() {
    case "${1:-}" in
        Y|y|[Yy]es|YES|J|j|[Jj]a|1|[Tt]rue) echo Y ;;
        N|n|[Nn]o|NO|[Nn]ein|0|[Ff]alse)    echo N ;;
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
# batch_bad "what" "value" "allowed" [DEFAULT_NAME]  - an unusable preset or
# batch-mode default
batch_bad() {
    if preset "${4:-}"; then echo "!!! ${1}: '${2}' is not ${3} (preset ${4})" >&2
    else echo "!!! ${1}: '${2}' is not ${3} (batch mode)" >&2; fi
    return 1
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
        confirm "Continue anyway - alerts would only go to the log?" \
            "$( [[ "${DEFAULT_NO_MAILER_OK:-N}" =~ ^([YyJj1]|[Yy]es)$ ]] && echo Y || echo N)" \
            DEFAULT_NO_MAILER_OK || return 1
    fi
    local M=$ALERT_MAIL
    ask M "Mail address for alerts" "$ALERT_MAIL" "" DEFAULT_ALERT_MAIL
    [[ "$M" == "-" ]] && M=""
    ALERT_MAIL=$M
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

# The threshold that applies to a mountpoint: its own if it has a numeric one,
# otherwise the general value. "off" is not a threshold, it means not watched.
threshold_for() {
    local v=${MOUNT_MIN_GB[$1]:-}
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; else echo "$FREE_MIN_GB"; fi
}

# Four cases, in this order:
#   /              always watched, whatever its size. A small VPS has a 15 GB
#                  root, and that is the filesystem whose running full takes the
#                  whole machine with it - it must not fall out of any filter.
#   entry "off"    deselected by hand during the setup: never watched.
#   a number       selected by hand: watched, with that threshold.
#   no entry       nobody has decided about it yet - typically a filesystem
#                  mounted after the last setup. The size rule applies, so a new
#                  disk is watched without anyone having to remember it.
monitored() {
    local mnt=$1 total=$2
    local v=${MOUNT_MIN_GB[$mnt]:-}
    [[ "$mnt" == "/" ]] && return 0
    [[ "$v" == "off" ]] && return 1
    [[ -n "$v" ]] && return 0
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

        local sf
        sf="$STATE_DIR/$(slug "$mnt").state"
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
    local mnt pct ipct free total note skipped=0
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        if ! monitored "$mnt" "$total"; then
            # Say which of the two reasons it is: a deliberate decision reads
            # very differently from a filesystem that simply fell below a limit.
            if [[ "${MOUNT_MIN_GB[$mnt]:-}" == "off" ]]; then
                note="not watched (switched off in the setup)"
            else
                note="not watched (below ${MIN_FS_SIZE_GB} GB total)"
            fi
            printf '%-24s %9s %9s %8s  %s\n' "$mnt" "$free" "$total" "-" "$note"
            skipped=1
            continue
        fi
        evaluate "$mnt" "$pct" "$ipct" "$free"
        printf '%-24s %9s %9s %8s  %-4s %s\n' \
            "$mnt" "$free" "$total" "$(threshold_for "$mnt")" "$STATE" "$(forecast "$mnt")"
    done < <(collect)

    echo
    echo "Default threshold ${FREE_MIN_GB} GB; filesystems are listed in the setup from ${MIN_FS_SIZE_GB} GB total size on."
    (( skipped == 1 )) && echo "Menu item 1 selects what is watched and sets the threshold per filesystem."
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

    local S G M sel i n mnt total free pct ipct cur
    local -a cand_m=() cand_t=() cand_f=() chosen=()

    # Thresholds of their own from a caller: "MOUNT=GB MOUNT=GB ..." - checked
    # before anything is asked.
    local -A dmount=()
    local tok
    local -a toks=()
    read -r -a toks <<<"${DEFAULT_MOUNT_MIN_GB:-}"
    for tok in "${toks[@]}"; do
        if [[ "$tok" =~ ^/.*=[0-9]+$ ]] && (( 10#${tok##*=} >= 1 )); then
            dmount["${tok%=*}"]=${tok##*=}
        else
            batch_bad "DEFAULT_MOUNT_MIN_GB entry" "$tok" "MOUNT=GB (GB at least 1)" DEFAULT_MOUNT_MIN_GB; return 1
        fi
    done

    # Step 1: the size limit, before anything is listed. Small system partitions
    # are the reason it exists: /boot has 2-4 GB altogether and /boot/efi half a
    # gigabyte, so any sensible threshold would mark them low for ever - and an
    # alert that is always on is one nobody reads.
    echo "--- Which filesystems to consider ---"
    echo "Filesystems below a certain total size are not worth watching -"
    echo "/boot has 2-4 GB in total, /boot/efi half of one."
    echo "/ is always watched, whatever its size."
    S=$MIN_FS_SIZE_GB
    ask S "List filesystems from this total size on (GB)" "$MIN_FS_SIZE_GB" "" DEFAULT_MIN_FS_SIZE_GB
    MIN_FS_SIZE_GB=$S
    while [[ ! "$MIN_FS_SIZE_GB" =~ ^[0-9]+$ ]]; do
        if [[ -n "${BATCH:-}" ]] || preset DEFAULT_MIN_FS_SIZE_GB; then
            batch_bad "Minimum filesystem size" "$MIN_FS_SIZE_GB" "a whole number of GB" DEFAULT_MIN_FS_SIZE_GB; return 1
        fi
        read -rp "  -> a whole number of GB (0 = list everything): " MIN_FS_SIZE_GB
    done

    # Step 2: list what passes that limit. Nothing is typed in here - the
    # filesystems come from df, so the list is whatever is mounted right now.
    while IFS="|" read -r mnt pct ipct free total; do
        [[ -n "$mnt" ]] || continue
        if [[ "$mnt" == "/" ]] \
            || awk -v t="$total" -v m="$MIN_FS_SIZE_GB" 'BEGIN{exit !(t >= m)}'; then
            cand_m+=("$mnt"); cand_t+=("$total"); cand_f+=("$free")
        fi
    done < <(collect)

    if (( ${#cand_m[@]} == 0 )); then
        echo
        echo "!!! No filesystem reaches ${MIN_FS_SIZE_GB} GB. Lower the limit."
        pause
        return 1
    fi

    echo
    echo "--- Found ---"
    for i in "${!cand_m[@]}"; do
        cur=""
        case "${MOUNT_MIN_GB[${cand_m[$i]}]:-}" in
            off)        cur="(so far: not watched)" ;;
            ""|*[!0-9]*) ;;
            *)          cur="(so far: below ${MOUNT_MIN_GB[${cand_m[$i]}]} GB)" ;;
        esac
        printf '  %2d) %-24s %8s GB free of %8s GB  %s\n' \
            $((i + 1)) "${cand_m[$i]}" "${cand_f[$i]}" "${cand_t[$i]}" "$cur"
    done

    # Step 3: pick. Empty means all of them, which is the common case.
    echo
    echo "Which of these should be watched? Numbers separated by space or comma,"
    echo "'a' or empty = all of them."
    local seldef=${DEFAULT_FS_SELECTION:-a} j k
    while true; do
        sel=$seldef
        ask sel "Selection" "$seldef" "" DEFAULT_FS_SELECTION
        sel=${sel:-a}
        chosen=()
        if [[ "$sel" =~ ^([aA]|all)$ ]]; then
            for i in "${!cand_m[@]}"; do chosen+=("$i"); done
            break
        fi
        sel=${sel//,/ }
        local bad=0
        for n in $sel; do
            # a mountpoint instead of its number (for a caller's default)
            if [[ "$n" == /* ]]; then
                k=""
                for j in "${!cand_m[@]}"; do [[ "${cand_m[$j]}" == "$n" ]] && k=$((j + 1)); done
                [[ -n "$k" ]] || { echo "  !!! '${n}' is not one of the listed filesystems."; bad=1; break; }
                n=$k
            fi
            if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#cand_m[@]} )); then
                echo "  !!! '${n}' is not one of the numbers 1-${#cand_m[@]}."
                bad=1; break
            fi
            chosen+=($((n - 1)))
        done
        (( bad == 0 && ${#chosen[@]} > 0 )) && break
        (( ${#chosen[@]} == 0 )) && echo "  !!! Nothing selected."
        if [[ -n "${BATCH:-}" ]] || preset DEFAULT_FS_SELECTION; then
            batch_bad "Selection" "$seldef" "usable" DEFAULT_FS_SELECTION; return 1
        fi
    done

    # Step 4: the general threshold first - it is the default offered per
    # filesystem below, and it also applies to anything mounted later.
    echo
    echo "--- Threshold ---"
    echo "Offered as the default for each selected filesystem below, and used"
    echo "for filesystems that only appear later."
    G=$FREE_MIN_GB
    ask G "Alert below how many GB free?" "$FREE_MIN_GB" "" DEFAULT_FREE_MIN_GB
    FREE_MIN_GB=$G
    while [[ ! "$FREE_MIN_GB" =~ ^[0-9]+$ ]] || (( FREE_MIN_GB < 1 )); do
        if [[ -n "${BATCH:-}" ]] || preset DEFAULT_FREE_MIN_GB; then
            batch_bad "Threshold" "$FREE_MIN_GB" "a whole number of GB, at least 1" DEFAULT_FREE_MIN_GB; return 1
        fi
        read -rp "  -> a whole number of GB, at least 1: " FREE_MIN_GB
    done

    # Step 5: per selected filesystem. A 2 TB backup disk wants 150 GB, a small
    # root maybe 5 - that is the whole point of doing this per mountpoint.
    echo
    echo "--- Per selected filesystem ---"
    echo "Enter keeps the general ${FREE_MIN_GB} GB."
    local -A picked=()
    for i in "${chosen[@]}"; do
        mnt=${cand_m[$i]}
        picked["$mnt"]=1
        cur=$(threshold_for "$mnt")
        # A preset general threshold replaces the stored per-filesystem one
        # as the default offered here.
        preset DEFAULT_FREE_MIN_GB && cur=$FREE_MIN_GB
        if [[ -n "${dmount[$mnt]:-}" ]]; then
            # named in DEFAULT_MOUNT_MIN_GB: a preset, not asked (checked above)
            G=${dmount[$mnt]}
            echo "  ${mnt} (${cand_t[$i]} GB total), alert below: ${G} GB (preset)"
        elif [[ -n "${BATCH:-}" ]]; then
            G=$cur
            echo "  ${mnt} (${cand_t[$i]} GB total), alert below: ${G} GB"
        else
            read -rp "  ${mnt} (${cand_t[$i]} GB total), alert below [${cur}] GB: " G
            G=${G:-$cur}
        fi
        while [[ ! "$G" =~ ^[0-9]+$ ]] || (( G < 1 )); do
            [[ -n "${BATCH:-}" ]] && { batch_bad "Threshold for ${mnt}" "$G" "a whole number of GB, at least 1"; return 1; }
            read -rp "    -> a whole number of GB, at least 1: " G
        done
        MOUNT_MIN_GB["$mnt"]=$G
    done

    # Everything that was listed but not picked is switched off explicitly. That
    # is a decision and has to survive; leaving no entry would hand it back to
    # the size rule, which is what put it on the list in the first place.
    for i in "${!cand_m[@]}"; do
        mnt=${cand_m[$i]}
        [[ -n "${picked[$mnt]:-}" ]] && continue
        [[ "$mnt" == "/" ]] && continue
        MOUNT_MIN_GB["$mnt"]="off"
        echo "  ${mnt}: not watched"
    done

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
        clear 2>/dev/null || true
        echo "=== Excluded mountpoints ==="
        if [[ -z "$EXCLUDE" ]]; then echo "(none)"; else printf '  %s\n' $EXCLUDE; fi
        echo
        echo "Currently monitored:"
        collect | cut -d'|' -f1 | sed 's/^/  /'
        echo
        echo "1) Exclude a mountpoint"
        echo "2) Remove an exclusion"
        echo "3) Back"
        read -rp "Choice: " CH || exit 0
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
        clear 2>/dev/null || true
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
        read -rp "Choice: " CH || exit 0
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
    --setup)     configure ;;
    --status)    show_usage ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--check|--setup|--status|--uninstall|--version]"; exit 1 ;;
esac
