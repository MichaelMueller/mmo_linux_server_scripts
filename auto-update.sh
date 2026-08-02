#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# auto-update.sh - automatic apt updates via cron, with a mail report
# Modes: (no argument) = interactive menu
#        --run         = one update run (for cron)
#        --status      = short status on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end instead of aborting mid-run and swallowing the report.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.0.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/auto-update.conf"
CRON_FILE=/etc/cron.d/auto-update

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
SCHEDULE="daily"        # daily | weekly
WEEKDAY=0               # 0=Sunday ... 6=Saturday (only for weekly)
HOUR=4
MINUTE=17
MODE="security"         # security | all
AUTOREMOVE=1
AUTO_REBOOT=0           # allow a reboot when one becomes necessary
MAIL_TO=""
MAIL_ON_INSTALL=1       # mail when packages were updated
MAIL_ON_ERROR=1         # mail when something went wrong
MAIL_ON_NOOP=0          # mail even when there was nothing to do
LOG_FILE="$DIR/var/auto-update.log"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# Configurations from older versions had a single MAIL_WHEN instead of the
# three switches. Translate it once, so nobody has to set things up again.
if [[ -n "${MAIL_WHEN:-}" ]]; then
    case "$MAIL_WHEN" in
        always)  MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=1 ;;
        errors)  MAIL_ON_INSTALL=0; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
        *)       MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
    esac
fi

DAYS=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

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

is_setup() { [[ -f "$CONF" ]]; }

save_conf() {
    cat > "$CONF" <<EOF
# auto-update configuration
SCHEDULE="${SCHEDULE}"
WEEKDAY=${WEEKDAY}
HOUR=${HOUR}
MINUTE=${MINUTE}
MODE="${MODE}"
AUTOREMOVE=${AUTOREMOVE}
AUTO_REBOOT=${AUTO_REBOOT}
MAIL_TO="${MAIL_TO}"
MAIL_ON_INSTALL=${MAIL_ON_INSTALL}
MAIL_ON_ERROR=${MAIL_ON_ERROR}
MAIL_ON_NOOP=${MAIL_ON_NOOP}
LOG_FILE="${LOG_FILE}"
EOF
    chmod 644 "$CONF"
}

cron_spec() {
    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "${MINUTE} ${HOUR} * * ${WEEKDAY}"
    else
        echo "${MINUTE} ${HOUR} * * *"
    fi
}

schedule_text() {
    local t
    t=$(printf '%02d:%02d' "$HOUR" "$MINUTE")
    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "weekly, ${DAYS[$WEEKDAY]} at ${t}"
    else
        echo "daily at ${t}"
    fi
}

mode_text() {
    [[ "$MODE" == "all" ]] && echo "all packages" || echo "security updates only"
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# auto-update - automatic apt updates
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$(cron_spec) root ${SELF} --run >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo "--- Schedule ---"
    echo "  1) daily"
    echo "  2) weekly"
    local S; read -rp "Choice [$([[ "$SCHEDULE" == "weekly" ]] && echo 2 || echo 1)]: " S
    case "${S:-}" in
        1) SCHEDULE="daily" ;;
        2) SCHEDULE="weekly" ;;
    esac

    if [[ "$SCHEDULE" == "weekly" ]]; then
        echo "  0=Sun 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat"
        local W; read -rp "Weekday [${WEEKDAY}]: " W; W=${W:-$WEEKDAY}
        [[ "$W" =~ ^[0-6]$ ]] && WEEKDAY=$W
    fi

    local T cur
    cur=$(printf '%02d:%02d' "$HOUR" "$MINUTE")
    read -rp "Time (HH:MM) [${cur}]: " T; T=${T:-$cur}
    while [[ ! "$T" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        read -rp "  -> format HH:MM: " T
    done
    HOUR=$((10#${T%%:*}))
    MINUTE=$((10#${T##*:}))

    echo
    echo "--- Scope ---"
    echo "  1) security updates only  (source *-security)"
    echo "  2) all packages           (apt dist-upgrade)"
    local M; read -rp "Choice [$([[ "$MODE" == "all" ]] && echo 2 || echo 1)]: " M
    case "${M:-}" in
        1) MODE="security" ;;
        2) MODE="all" ;;
    esac

    echo
    confirm "Remove packages that are no longer needed (apt autoremove)?" "$([[ $AUTOREMOVE -eq 1 ]] && echo Y || echo N)" \
        && AUTOREMOVE=1 || AUTOREMOVE=0

    echo
    echo "--- Reboot ---"
    echo "After kernel or libc updates a reboot is necessary; apt then leaves"
    echo "/var/run/reboot-required behind. If the reboot is not allowed, it is"
    echo "only reported - the server then stays on the old kernel until someone"
    echo "takes care of it."
    confirm "Allow a reboot?" "$([[ $AUTO_REBOOT -eq 1 ]] && echo Y || echo N)" \
        && AUTO_REBOOT=1 || AUTO_REBOOT=0

    echo
    echo "--- Report ---"
    local R; read -rp "Mail recipient (empty = no mail) [${MAIL_TO}]: " R
    MAIL_TO=${R:-$MAIL_TO}

    if [[ -n "$MAIL_TO" ]]; then
        echo
        confirm "Mail when packages were installed?" \
            "$([[ $MAIL_ON_INSTALL -eq 1 ]] && echo Y || echo N)" \
            && MAIL_ON_INSTALL=1 || MAIL_ON_INSTALL=0
        confirm "Mail when an error occurred?" \
            "$([[ $MAIL_ON_ERROR -eq 1 ]] && echo Y || echo N)" \
            && MAIL_ON_ERROR=1 || MAIL_ON_ERROR=0
        confirm "Mail even when there was nothing to do?" \
            "$([[ $MAIL_ON_NOOP -eq 1 ]] && echo Y || echo N)" \
            && MAIL_ON_NOOP=1 || MAIL_ON_NOOP=0

        if (( MAIL_ON_INSTALL + MAIL_ON_ERROR + MAIL_ON_NOOP == 0 )); then
            echo
            echo "All switched off - so nothing is ever mailed, only written to the log."
        fi
        if ! command -v mail &>/dev/null; then
            echo
            echo "Note: 'mail' is not installed - for now the report only goes to the"
            echo "log. The SMTP mailer (mail-setup.sh) sets that up."
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    save_conf
    write_cron

    echo
    echo "Schedule: $(schedule_text)"
    echo "Scope:    $(mode_text)"
    echo "Cron:     $CRON_FILE"
    echo "Log:      $LOG_FILE"
    echo ">>> Setup complete."
    pause
}

# ---------------------------------------------------------------------------
# Update run
# ---------------------------------------------------------------------------
# Security updates are recognised by the suite name (bookworm-security,
# jammy-security ...). Custom repos without that naming scheme therefore fall
# into the "all packages" mode.
upgradable_packages() {
    if [[ "$MODE" == "security" ]]; then
        apt list --upgradable 2>/dev/null | awk -F/ '/^[a-z0-9]/ && /-security/ {print $1}'
    else
        apt list --upgradable 2>/dev/null | awk -F/ '/^[a-z0-9]/ {print $1}'
    fi
}

show_pending() {
    echo ">>> Updating package lists..."
    apt-get update -qq >/dev/null 2>&1
    echo
    echo "--- Pending updates (${1:-$(mode_text)}) ---"
    local -a pkgs=()
    mapfile -t pkgs < <(upgradable_packages)
    if (( ${#pkgs[@]} == 0 )); then
        echo "(none)"
    else
        printf '  %s\n' "${pkgs[@]}"
        echo
        echo "Total: ${#pkgs[@]} package(s)"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        echo
        echo "!!! A reboot is pending (/var/run/reboot-required)."
    fi
}

run_update() {
    local verbose=${1:-}
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }

    mkdir -p "$(dirname "$LOG_FILE")"

    local tmp rc=0 changed=0 host
    tmp=$(mktemp)
    host=$(hostname -f 2>/dev/null || hostname)

    {
        echo "auto-update on ${host}"
        echo "Start: $(date '+%F %T')"
        echo "Scope: $(mode_text)"
        echo "----------------------------------------"
    } > "$tmp"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq >>"$tmp" 2>&1; then
        echo "!!! 'apt-get update' failed." >> "$tmp"
        rc=1
    fi

    local -a pkgs=()
    mapfile -t pkgs < <(upgradable_packages)

    if (( ${#pkgs[@]} == 0 )); then
        echo "No pending updates." >> "$tmp"
    else
        {
            echo "To be updated (${#pkgs[@]}):"
            printf '  %s\n' "${pkgs[@]}"
            echo
        } >> "$tmp"

        local -a apt_cmd=(apt-get -y
            -o Dpkg::Options::=--force-confdef
            -o Dpkg::Options::=--force-confold)
        if [[ "$MODE" == "all" ]]; then
            apt_cmd+=(dist-upgrade)
        else
            apt_cmd+=(install --only-upgrade "${pkgs[@]}")
        fi

        if "${apt_cmd[@]}" >>"$tmp" 2>&1; then
            changed=1
        else
            echo "!!! The update failed." >> "$tmp"
            rc=1
        fi
    fi

    if (( AUTOREMOVE == 1 )); then
        echo "--- autoremove ---" >> "$tmp"
        apt-get -y autoremove >>"$tmp" 2>&1 || { echo "!!! autoremove failed." >> "$tmp"; rc=1; }
    fi

    local reboot_needed=0
    if [[ -f /var/run/reboot-required ]]; then
        reboot_needed=1
        echo >> "$tmp"
        if (( AUTO_REBOOT == 1 )); then
            echo "Reboot required - the server restarts in 1 minute." >> "$tmp"
        else
            echo "!!! Reboot required (/var/run/reboot-required) - please do it manually." >> "$tmp"
        fi
    fi

    echo "----------------------------------------" >> "$tmp"
    echo "End: $(date '+%F %T')   status: $( ((rc==0)) && echo ok || echo ERROR)" >> "$tmp"

    cat "$tmp" >> "$LOG_FILE"
    # Cap the log so it does not grow without bound
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"

    local subject
    if (( rc != 0 )); then
        subject="[ERROR] auto-update ${host}"
    elif (( changed == 1 )); then
        subject="auto-update ${host}: ${#pkgs[@]} package(s) updated"
    else
        subject="auto-update ${host}: no updates"
    fi

    local do_mail=0
    (( rc != 0     && MAIL_ON_ERROR   == 1 )) && do_mail=1
    (( changed == 1 && MAIL_ON_INSTALL == 1 )) && do_mail=1
    (( changed == 0 && rc == 0 && MAIL_ON_NOOP == 1 )) && do_mail=1

    if (( do_mail == 1 )) && [[ -n "$MAIL_TO" ]]; then
        if command -v mail &>/dev/null; then
            mail -s "$subject" "$MAIL_TO" < "$tmp" \
                || echo "$(date '+%F %T') !!! sending mail to ${MAIL_TO} failed" >> "$LOG_FILE"
        else
            echo "$(date '+%F %T') !!! 'mail' not available - nothing sent" >> "$LOG_FILE"
        fi
    fi

    [[ -n "$verbose" ]] && cat "$tmp"
    rm -f "$tmp"

    if (( reboot_needed == 1 && AUTO_REBOOT == 1 )); then
        shutdown -r +1 "auto-update: reboot after package updates" >/dev/null 2>&1 || reboot
    fi

    return $rc
}

show_log() {
    [[ -f "$LOG_FILE" ]] || { echo "There is no log."; pause; return; }
    tail -n 60 "$LOG_FILE"
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall auto-update"
    echo
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE ($(schedule_text))"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -f "$LOG_FILE" ]]  && echo "  - log $LOG_FILE                              [asked]"
    echo
    echo "Package updates already installed of course stay in place; it is only"
    echo "that no new ones will be applied automatically from now on."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup auto-update "$CONF" "$LOG_FILE" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    if [[ -f "$LOG_FILE" ]] && confirm "Delete the log $LOG_FILE as well?"; then
        rm -f "$LOG_FILE"
    fi
    rmdir "$(dirname "$LOG_FILE")" 2>/dev/null || true

    echo
    echo "Removed. The server no longer gets automatic updates."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Automatic updates (apt)"
        echo "==========================================="
        if is_setup; then
            echo "Schedule:  $(schedule_text)"
            echo "Scope:     $(mode_text)"
            echo "Cron:      $([[ -f "$CRON_FILE" ]] && echo "active" || echo "!!! not installed")"
            echo "Reboot:    $( ((AUTO_REBOOT==1)) && echo "allowed" || echo "only reported")"
            if [[ -n "$MAIL_TO" ]]; then
                local w=""
                (( MAIL_ON_INSTALL == 1 )) && w+="installation, "
                (( MAIL_ON_ERROR   == 1 )) && w+="errors, "
                (( MAIL_ON_NOOP    == 1 )) && w+="every run, "
                w=${w%, }
                echo "Report to: ${MAIL_TO}  (on: ${w:-never})"
            else
                echo "Report to: (no mail)"
            fi
            [[ -f /var/run/reboot-required ]] && echo "!!! A reboot is pending."
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Set up / edit settings"
        echo "2) Apply updates now"
        echo "3) Show pending updates"
        echo "4) Show the log"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) is_setup || configure; echo; run_update verbose; echo; pause ;;
            3) is_setup || configure; show_pending; pause ;;
            4) show_log ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --run)       run_update ;;
    --status)    is_setup && { echo "auto-update: $(schedule_text), $(mode_text)"; } ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Usage: $0 [--run|--status|--uninstall|--version]"; exit 1 ;;
esac
