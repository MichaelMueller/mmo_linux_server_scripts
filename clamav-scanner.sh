#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# clamav-scanner.sh - ClamAV: signature updates and scheduled scans with alerts
# Modes: (no argument) = interactive menu
#        --check       = one scan run (for cron)
#        --update      = update the signatures now
#        --status      = signatures and last result on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.3.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/clamav-scanner.conf"
CRON_FILE=/etc/cron.d/clamav-scanner
SIG_DIR=/var/lib/clamav

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var/clamav"
SCAN_PATHS="/home /root /srv /opt /var/www /tmp"
EXCLUDE_DIRS="/var/lib/clamav /proc /sys /dev /run /snap"
SCAN_TIME="03:30"        # daily, local server time
ALERT_MODE="findings"    # findings | always
ALERT_MAIL=""
KEEP_REPORTS=30

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# A relative data directory would be created wherever the caller happens to
# stand - and cron stands somewhere else than you do. Resolve against the
# script's directory, never against $PWD.
resolve_data_dir() {
    local d=${1%/}
    case "$d" in
        /*) printf '%s' "$d" ;;
        "") printf '%s' "$DIR/var/clamav" ;;
        .)  printf '%s' "$DIR" ;;
        *)  printf '%s' "$DIR/${d#./}" ;;
    esac
}
DATA_DIR=$(resolve_data_dir "$DATA_DIR")

LOG_DIR="$DATA_DIR/log"
REPORT_DIR="$DATA_DIR/reports"
STATE_FILE="$DATA_DIR/last-result"
ALERT_LOG="$LOG_DIR/alerts.log"

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

make_dirs() { mkdir -p "$LOG_DIR" "$REPORT_DIR"; }

save_conf() {
    cat > "$CONF" <<EOF
# clamav-scanner configuration
DATA_DIR="${DATA_DIR}"
SCAN_PATHS="${SCAN_PATHS}"
EXCLUDE_DIRS="${EXCLUDE_DIRS}"
SCAN_TIME="${SCAN_TIME}"
ALERT_MODE="${ALERT_MODE}"
ALERT_MAIL="${ALERT_MAIL}"
KEEP_REPORTS=${KEEP_REPORTS}
EOF
    chmod 644 "$CONF"
}

write_cron() {
    local hh=${SCAN_TIME%%:*} mm=${SCAN_TIME##*:}
    cat > "$CRON_FILE" <<EOF
# clamav-scanner - daily virus scan
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${mm#0} ${hh#0} * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Installation and signatures
# ---------------------------------------------------------------------------
install_pkg() {
    if ! command -v clamscan &>/dev/null; then
        echo ">>> Installing ClamAV (the signature download is ~300 MB on first run)..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y clamav clamav-freshclam >/dev/null
        systemctl enable --now clamav-freshclam >/dev/null 2>&1 || true
    fi
}

# Age of the newest signature file, in hours. Empty when none exists yet.
sig_age_hours() {
    local newest=0 f mtime
    for f in "$SIG_DIR"/daily.cld "$SIG_DIR"/daily.cvd; do
        [[ -f "$f" ]] || continue
        mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
        (( mtime > newest )) && newest=$mtime
    done
    (( newest == 0 )) && return 0
    echo $(( ($(date +%s) - newest) / 3600 ))
}

sigs_present() { [[ -f "$SIG_DIR/daily.cld" || -f "$SIG_DIR/daily.cvd" ]]; }

# The clamav-freshclam service keeps the signatures current on its own and
# holds the freshclam log lock. A manual run therefore has to stop it first,
# otherwise freshclam only reports "locked by another process".
update_signatures() {
    install_pkg
    echo ">>> Updating signatures..."
    if systemctl is-active clamav-freshclam &>/dev/null; then
        systemctl stop clamav-freshclam
        freshclam || echo "!!! freshclam reported an error."
        systemctl start clamav-freshclam
    else
        freshclam || echo "!!! freshclam reported an error."
    fi
    local age; age=$(sig_age_hours)
    [[ -n "$age" ]] && echo "Signatures are now ${age} h old."
}

# ---------------------------------------------------------------------------
# Alerting (same channel as the monitors: 'mail' via msmtp or graph-mailer)
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
# Scan run
# ---------------------------------------------------------------------------
run_check() {
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    install_pkg
    make_dirs

    if ! sigs_present; then
        echo "No signatures yet - fetching them first (can take a while)..."
        update_signatures
        sigs_present || { echo "!!! Still no signatures - aborting." >&2; return 1; }
    fi

    local now host report rc p
    now=$(date '+%F %T')
    host=$(hostname -f 2>/dev/null || hostname)
    report="$REPORT_DIR/scan-$(date +%Y%m%d-%H%M%S).log"

    local -a args=(--recursive --infected --stdout)
    for p in $EXCLUDE_DIRS; do
        args+=(--exclude-dir="^${p}")
    done

    # clamscan exits 2 for a path it cannot access, and it makes no difference
    # to it whether that is a permission problem or a directory that simply is
    # not there. A configured path that does not exist on this machine would
    # therefore turn every nightly run into a "scan failed" mail - and /srv,
    # /opt and /var/www are missing on a perfectly normal server. So missing
    # paths are skipped and only noted in the report.
    local -a scan=() missing=()
    # shellcheck disable=SC2086  # deliberate word splitting: it is a path list
    for p in $SCAN_PATHS; do
        if [[ -e "$p" ]]; then scan+=("$p"); else missing+=("$p"); fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "Not present, skipped: ${missing[*]}"
    fi

    # Nothing left to scan is a real problem - but a different one, and saying
    # so beats an exit code that looks like a broken ClamAV.
    if (( ${#scan[@]} == 0 )); then
        local msg="None of the configured paths exists: ${SCAN_PATHS}"
        echo "!!! ${msg}"
        echo "${now}|2|0|-" > "$STATE_FILE"
        notify "[clamav] ${host}: nothing to scan" \
            "ClamAV scan on ${host}"$'\n'"As of: ${now}"$'\n\n'"${msg}"$'\n'"Adjust the paths: menu item 4."
        return 2
    fi

    echo "Scan of: ${scan[*]}"
    echo "Report:  $report"
    echo

    # nice/ionice: a full clamscan is CPU- and IO-hungry; the services on this
    # machine matter more than the scan finishing fast.
    nice -n 19 ionice -c3 clamscan "${args[@]}" "${scan[@]}" > "$report" 2>&1
    rc=$?
    # clamscan: 0 = clean, 1 = findings, anything else = error

    local infected scanned
    infected=$(awk -F': ' '/^Infected files:/ {print $2; exit}' "$report")
    scanned=$(awk -F': '  '/^Scanned files:/  {print $2; exit}' "$report")
    infected=${infected:-?}

    echo "${now}|${rc}|${infected}|${report}" > "$STATE_FILE"

    local subject body
    body="ClamAV scan on ${host}"$'\n'"As of: ${now}"$'\n'
    body+="Paths: ${scan[*]}"$'\n'
    (( ${#missing[@]} > 0 )) && body+="Not present, skipped: ${missing[*]}"$'\n'
    body+="Scanned files: ${scanned:-?}, findings: ${infected}"$'\n'
    body+="Full report: ${report}"$'\n'

    if (( rc == 1 )); then
        body+=$'\n'"Findings:"$'\n'
        body+=$(grep 'FOUND$' "$report" | head -n 50 | sed 's/^/  /')
        body+=$'\n\n'"Nothing was deleted or moved - assess the findings first."
        subject="[clamav] ${host}: ${infected} finding(s)"
        notify "$subject" "$body"
        echo "!!! ${infected} finding(s) - see ${report}"
    elif (( rc != 0 )); then
        subject="[clamav] ${host}: scan failed (exit code ${rc})"
        body+=$'\n'"Last lines:"$'\n'"$(tail -n 10 "$report" | sed 's/^/  /')"
        notify "$subject" "$body"
        echo "!!! Scan failed with exit code ${rc} - see ${report}"
    else
        echo "Clean: ${scanned:-?} files scanned, no findings."
        if [[ "$ALERT_MODE" == "always" ]]; then
            notify "[clamav] ${host}: clean (${scanned:-?} files)" "$body"
        fi
    fi

    # keep the newest KEEP_REPORTS reports, remove the rest
    ls -1t "$REPORT_DIR"/scan-*.log 2>/dev/null | tail -n +$((KEEP_REPORTS + 1)) \
        | while read -r f; do rm -f "$f"; done

    return $rc
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
show_status() {
    local age
    if command -v clamscan &>/dev/null; then
        echo "ClamAV:     $(clamscan --version 2>/dev/null || echo installed)"
    else
        echo "ClamAV:     not installed"
    fi

    if sigs_present; then
        age=$(sig_age_hours)
        echo "Signatures: ${age} h old   (freshclam service: $(systemctl is-active clamav-freshclam 2>/dev/null || echo -))"
    else
        echo "Signatures: none yet"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        local ts rc infected report
        IFS='|' read -r ts rc infected report < "$STATE_FILE"
        local verdict="clean"
        (( rc == 1 )) && verdict="${infected} FINDING(S)"
        (( rc > 1 ))  && verdict="failed (exit code ${rc})"
        echo "Last scan:  ${ts} - ${verdict}"
        echo "Report:     ${report}"
    else
        echo "Last scan:  never"
    fi

    if [[ -f "$CRON_FILE" ]]; then
        echo "Cron:       daily at ${SCAN_TIME}"
    else
        echo "Cron:       not installed"
    fi
}

show_report() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No scan has run yet."
        pause; return
    fi
    local ts rc infected report
    IFS='|' read -r ts rc infected report < "$STATE_FILE"
    if [[ -f "$report" ]]; then
        less "$report"
    else
        echo "Report no longer exists: $report"
        pause
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    install_pkg

    echo ">>> Settings for clamav-scanner"
    echo

    local D P E T A M WH K p
    echo
    echo "Paths to scan, space-separated. '/' works but takes hours - the"
    echo "default covers the places where foreign files usually arrive."
    # Only offer what is actually there. /srv, /opt and /var/www are missing on
    # plenty of servers, and a path that does not exist is worth nothing in the
    # list - the scan skips it anyway.
    local -a cand=() have=()
    read -r -a cand <<<"$SCAN_PATHS"
    for p in "${cand[@]}"; do [[ -e "$p" ]] && have+=("$p"); done
    if (( ${#have[@]} > 0 )) && (( ${#have[@]} < ${#cand[@]} )); then
        echo "Not present on this machine, left out: $(
            for p in "${cand[@]}"; do [[ -e "$p" ]] || printf '%s ' "$p"; done)"
        SCAN_PATHS="${have[*]}"
    fi
    read -rp "Paths [${SCAN_PATHS}]: " P; SCAN_PATHS=${P:-$SCAN_PATHS}
    read -rp "Excluded directories [${EXCLUDE_DIRS}]: " E; EXCLUDE_DIRS=${E:-$EXCLUDE_DIRS}

    echo
    while true; do
        read -rp "Daily scan at (HH:MM) [${SCAN_TIME}]: " T; T=${T:-$SCAN_TIME}
        [[ "$T" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && { SCAN_TIME=$T; break; }
        echo "Please use HH:MM, e.g. 03:30."
    done

    echo
    echo "Alerting:"
    echo "  1) only on findings or errors (recommended)"
    echo "  2) after every scan, including clean ones"
    read -rp "Choice [1]: " A
    [[ "${A:-1}" == "2" ]] && ALERT_MODE="always" || ALERT_MODE="findings"

    ask_alert_mail || return 1

    read -rp "Keep the last N reports [${KEEP_REPORTS}]: " K
    KEEP_REPORTS=${K:-$KEEP_REPORTS}

    LOG_DIR="$DATA_DIR/log"
    REPORT_DIR="$DATA_DIR/reports"
    STATE_FILE="$DATA_DIR/last-result"
    ALERT_LOG="$LOG_DIR/alerts.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Scan: daily at ${SCAN_TIME}   ($CRON_FILE)"
    echo "Findings are reported, never deleted or moved automatically."
    echo ">>> Set up."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall clamav-scanner"
    echo
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (daily at ${SCAN_TIME})"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -d "$DATA_DIR" ]]  && echo "  - data directory $DATA_DIR (reports, alert log)   [asked]"
    echo "  - the clamav packages and their signatures (~1 GB)             [asked]"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup clamav-scanner "$CONF" "$DATA_DIR" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Delete the reports and state in $DATA_DIR as well?"; then
        rm -rf "$DATA_DIR"
    fi

    if command -v clamscan &>/dev/null; then
        if confirm "Remove the clamav packages and signatures as well (apt purge)?"; then
            systemctl disable --now clamav-freshclam >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt purge -y clamav clamav-freshclam clamav-base >/dev/null 2>&1 || true
            apt autoremove -y >/dev/null 2>&1 || true
            rm -rf "$SIG_DIR"
            echo "Packages removed."
        else
            echo "The packages stay. Manually: apt purge clamav clamav-freshclam clamav-base"
        fi
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
        echo " Virus scan (ClamAV)"
        echo "==========================================="
        show_status
        echo
        echo "1) Set up / edit settings"
        echo "2) Update the signatures now"
        echo "3) Scan now"
        echo "4) Show the last report"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) update_signatures; pause ;;
            3) is_setup || configure; echo; run_check; echo; pause ;;
            4) show_report ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --update)    update_signatures ;;
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--check|--update|--status|--uninstall|--version]"; exit 1 ;;
esac
