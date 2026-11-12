#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# anomaly-monitor.sh - detect abnormal behaviour at runtime with Falco, mail it
#
# Falco (CNCF) watches the system calls of every process through eBPF and
# matches them against a maintained rule set: a shell in a container, writes
# below /etc or into binary directories, reading /etc/shadow, a new SUID file,
# unexpected outbound connections, privilege escalation and more. It runs with
# its default rules - nothing to configure; the rules are updated
# automatically (falcoctl).
#
# This tool installs Falco from the official repository with the "modern
# eBPF" driver (no kernel module, no headers), checks the journal every few
# minutes and mails new events from priority Warning upward, grouped.
#
# Modes: (no argument) = interactive menu
#        --setup       = install / configure (asks only the mail recipient)
#        --check       = mail new events (for cron)
#        --status      = status on stdout
#        --test        = trigger a harmless test event and show it
#        --uninstall   = uninstall
# Presets: a DEFAULT_* that is set is taken without a question (and wins over
# the stored value); unset ones are asked - in batch mode, BATCH=1, nothing is
# asked and every question takes its default. Only the recipient is a
# question; the other three are only set by a preset or in the conf file:
#   DEFAULT_ALERT_MAIL          recipient(s), comma-separated, '-' = none (log only)
#   DEFAULT_MIN_PRIORITY        Emergency|Alert|Critical|Error|Warning|Notice|
#                               Informational|Debug - mailed from (Warning)
#   DEFAULT_CHECK_INTERVAL_MIN  minutes between checks, 1-59 (10)
#   DEFAULT_IGNORE_RULES        extended regex of event texts never mailed,
#                               '-' = none (empty)
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
CONF="$DIR/anomaly-monitor.conf"
STATE_DIR="$DIR/var/anomaly-monitor"
CURSOR="$STATE_DIR/journal.cursor"
LOG_FILE="$DIR/var/anomaly-monitor.log"
CRON_FILE=/etc/cron.d/anomaly-monitor
LOCK_FILE=/run/anomaly-monitor.lock

KEYRING=/usr/share/keyrings/falco-archive-keyring.gpg
REPO_LIST=/etc/apt/sources.list.d/falcosecurity.list
REPO_KEY_URL=https://falco.org/repo/falcosecurity-packages.asc
REPO_LINE="deb [signed-by=${KEYRING}] https://download.falco.org/packages/deb stable main"
UNITS=(falco-modern-bpf.service falco-kmod.service falco-bpf.service)

ALERT_MAIL=""
MIN_PRIORITY="Warning"     # Emergency Alert Critical Error Warning Notice Informational Debug
CHECK_INTERVAL_MIN=10
IGNORE_RULES=""            # extended regex of event texts never mailed, e.g. 'Read sensitive file.*backup'

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
# Presets win over the stored values ('-' = none).
[[ -n "${DEFAULT_ALERT_MAIL:-}" ]] && ALERT_MAIL=$DEFAULT_ALERT_MAIL
[[ -n "${DEFAULT_MIN_PRIORITY:-}" ]] && MIN_PRIORITY=$DEFAULT_MIN_PRIORITY
[[ -n "${DEFAULT_CHECK_INTERVAL_MIN:-}" ]] && CHECK_INTERVAL_MIN=$DEFAULT_CHECK_INTERVAL_MIN
[[ -n "${DEFAULT_IGNORE_RULES:-}" ]] && IGNORE_RULES=$DEFAULT_IGNORE_RULES
[[ "$ALERT_MAIL" == "-" ]] && ALERT_MAIL=""
[[ "$IGNORE_RULES" == "-" ]] && IGNORE_RULES=""

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

save_conf() {
    cat > "$CONF" <<EOF
# anomaly-monitor configuration
ALERT_MAIL="${ALERT_MAIL}"
MIN_PRIORITY="${MIN_PRIORITY}"
CHECK_INTERVAL_MIN=${CHECK_INTERVAL_MIN}
IGNORE_RULES="${IGNORE_RULES}"
EOF
    chmod 644 "$CONF"
}

installed() { command -v falco &>/dev/null; }

active_unit() {
    local u
    for u in "${UNITS[@]}"; do
        systemctl is-active --quiet "$u" 2>/dev/null && { echo "$u"; return 0; }
    done
    return 1
}

# Priority rank: lower = more severe.
prio_rank() {
    case "$1" in
        Emergency) echo 0 ;; Alert) echo 1 ;; Critical) echo 2 ;; Error) echo 3 ;;
        Warning) echo 4 ;; Notice) echo 5 ;; Informational|Info) echo 6 ;; *) echo 7 ;;
    esac
}

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------
check_requirements() {
    local ok=0 virt arch
    arch=$(uname -m)
    if [[ "$arch" != x86_64 && "$arch" != aarch64 ]]; then
        echo "!!! Falco runs on x86_64 and aarch64 only (this is ${arch})."; ok=1
    fi
    virt=$(systemd-detect-virt --container 2>/dev/null || true)
    if [[ -n "$virt" && "$virt" != none ]]; then
        echo "!!! This is a container (${virt}): Falco needs the host kernel."
        echo "!!! Run it on the host instead."; ok=1
    fi
    if [[ ! -e /sys/kernel/btf/vmlinux ]]; then
        echo "!!! The kernel has no BTF (/sys/kernel/btf/vmlinux) - the modern"
        echo "!!! eBPF driver needs it (Debian 11+, Ubuntu 22.04+ have it)."; ok=1
    fi
    return $ok
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
install_falco() {
    if installed; then
        echo "Falco is installed: $(falco --version 2>/dev/null | head -1)"
    else
        echo ">>> Adding the Falco repository..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gpg ca-certificates >/dev/null 2>&1 || true
        if ! curl -fsSL "$REPO_KEY_URL" | gpg --dearmor --yes -o "$KEYRING"; then
            echo "!!! The repository key could not be fetched."; return 1
        fi
        echo "$REPO_LINE" > "$REPO_LIST"
        apt-get update -qq >/dev/null 2>&1 || true
        echo ">>> Installing Falco (modern eBPF driver, rules auto-update)..."
        if ! env FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                DEBIAN_FRONTEND=noninteractive apt-get install -y falco >/dev/null; then
            echo "!!! The installation failed."; return 1
        fi
    fi
    systemctl enable --now falco-modern-bpf.service >/dev/null 2>&1 || true
    sleep 3
    if active_unit >/dev/null; then
        echo "Falco is running ($(active_unit))."
    else
        echo "!!! Falco does not run - see: journalctl -u falco-modern-bpf -n 30"
        return 1
    fi
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# anomaly-monitor - mail new Falco events (written by ${SELF})
*/${CHECK_INTERVAL_MIN} * * * * root flock -n ${LOCK_FILE} ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

setup() {
    echo ">>> Anomaly detection (Falco)"
    echo "Falco watches what processes do and reports suspicious behaviour:"
    echo "shells in containers, writes into /etc or binary directories, reading"
    echo "/etc/shadow, privilege escalation, unexpected network connections."
    echo "It runs with its maintained default rules - nothing to configure."
    echo
    if [[ -n "${BATCH:-}" ]] || preset DEFAULT_MIN_PRIORITY || preset DEFAULT_CHECK_INTERVAL_MIN \
            || preset DEFAULT_IGNORE_RULES; then
        # Not asked, but they may come from the caller - check them before
        # anything is installed.
        [[ "$MIN_PRIORITY" =~ ^(Emergency|Alert|Critical|Error|Warning|Notice|Informational|Debug)$ ]] \
            || { batch_bad MIN_PRIORITY "$MIN_PRIORITY" \
                     "Emergency|Alert|Critical|Error|Warning|Notice|Informational|Debug" DEFAULT_MIN_PRIORITY; return 1; }
        if [[ ! "$CHECK_INTERVAL_MIN" =~ ^[0-9]+$ ]] || (( CHECK_INTERVAL_MIN < 1 || CHECK_INTERVAL_MIN > 59 )); then
            batch_bad CHECK_INTERVAL_MIN "$CHECK_INTERVAL_MIN" "1-59" DEFAULT_CHECK_INTERVAL_MIN; return 1
        fi
        # grep: 1 = no match (fine), 2 = not a valid regex
        if preset DEFAULT_IGNORE_RULES && [[ -n "$IGNORE_RULES" ]]; then
            (( $(grep -Eq -- "$IGNORE_RULES" </dev/null 2>/dev/null; echo $?) <= 1 )) \
                || { batch_bad IGNORE_RULES "$IGNORE_RULES" "an extended regex" DEFAULT_IGNORE_RULES; return 1; }
        fi
        echo "Priority from: ${MIN_PRIORITY}$(preset_tag DEFAULT_MIN_PRIORITY), every ${CHECK_INTERVAL_MIN} min$(preset_tag DEFAULT_CHECK_INTERVAL_MIN)${IGNORE_RULES:+, ignored: ${IGNORE_RULES}$(preset_tag DEFAULT_IGNORE_RULES)}"
    fi
    check_requirements || { echo "Not possible on this machine."; return 1; }
    install_falco || return 1
    echo
    local r=$ALERT_MAIL
    ask r "Mail events to (comma-separated)" "$ALERT_MAIL" "" DEFAULT_ALERT_MAIL
    [[ "$r" == "-" ]] && r=""
    ALERT_MAIL=$r
    [[ -n "$ALERT_MAIL" ]] || echo "(no recipient - events only go to ${LOG_FILE})"
    command -v mail &>/dev/null || echo "Note: 'mail' is missing - set up a mailer (mail-setup.sh)."
    mkdir -p "$STATE_DIR"
    # Start from now: the events of the installation itself are not news.
    journalctl -n 0 --show-cursor -q 2>/dev/null | sed -n 's/^-- cursor: //p' > "$CURSOR" || true
    save_conf
    write_cron
    echo
    echo "Checked every ${CHECK_INTERVAL_MIN} min, mailed from priority ${MIN_PRIORITY}."
    echo "Try it: $(basename "$0") --test"
}

# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------
# New Falco lines since the last check (journal cursor).
new_events() {
    local -a args=()
    local u
    for u in "${UNITS[@]}"; do args+=(-u "$u"); done
    mkdir -p "$STATE_DIR"
    journalctl "${args[@]}" -o cat -q --no-pager --cursor-file="$CURSOR" 2>/dev/null || true
}

# filter_events: stdin raw lines -> events at or above MIN_PRIORITY, not ignored
filter_events() {
    local max line p
    max=$(prio_rank "$MIN_PRIORITY")
    while IFS= read -r line; do
        # Falco's output, depending on its configuration:
        #   12:00:01.123456789: Warning Sensitive file opened ...      (default)
        #   2026-11-08T12:00:01.123456789+0000: Warning ...            (time_format_iso_8601)
        #   {"output":"12:00:01...: Warning ...","priority":"Warning",...}  (json_output)
        # Startup and info lines ("Sun Nov  8 ...: Falco version ...") match none.
        if [[ "$line" == \{* ]]; then
            p=$(sed -nE 's/.*"priority":"([A-Za-z]+)".*/\1/p' <<<"$line")
            line=$(sed -nE 's/.*"output":"(([^"\\]|\\.)*)".*/\1/p' <<<"$line")
        else
            p=$(sed -nE 's/^[0-9][0-9T:.+-]*: ([A-Z][a-z]+) .*/\1/p' <<<"$line")
        fi
        [[ -n "$p" && -n "$line" ]] || continue
        (( $(prio_rank "$p") <= max )) || continue
        [[ -n "$IGNORE_RULES" ]] && grep -Eq -- "$IGNORE_RULES" <<<"$line" && continue
        echo "$line"
    done
}

check() {
    installed || { echo "Falco is not installed."; return 1; }
    local events host n
    events=$(new_events | filter_events)
    mkdir -p "$(dirname "$LOG_FILE")"
    if ! active_unit >/dev/null; then
        events+=$'\n'"!!! Falco is NOT running - no detection until it is started again."
    fi
    [[ -n "${events//[[:space:]]/}" ]] || return 0
    n=$(grep -c . <<<"$events")
    host=$(hostname -f 2>/dev/null || hostname)
    echo "$events" | sed "s/^/$(date '+%F %T') /" >> "$LOG_FILE"
    tail -n 5000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    if [[ -n "$ALERT_MAIL" ]] && command -v mail &>/dev/null; then
        {
            echo "Falco reported ${n} event(s) on ${host} (priority ${MIN_PRIORITY} and above)."
            echo
            echo "--- Grouped ---"
            sed -E 's/^[0-9][0-9T:.+-]*: //; s/ \(.*//; s/ \|.*//' <<<"$events" | sort | uniq -c | sort -rn
            echo
            echo "--- Events ---"
            echo "$events"
            echo
            echo "Check whether this was a known action (admin work, a deployment)."
            echo "If not: do not clean up on the machine - escalate first."
            echo "Recurring known events can be ignored: IGNORE_RULES in ${CONF}"
        } | mail -s "[anomaly] ${host}: ${n} Falco event(s)" "$ALERT_MAIL" \
            || echo "$(date '+%F %T') !!! mail to ${ALERT_MAIL} failed" >> "$LOG_FILE"
    fi
}

# A harmless action Falco's default rules report: reading /etc/shadow with a
# program that has no business doing so.
test_event() {
    active_unit >/dev/null || { echo "Falco is not running."; return 1; }
    echo ">>> Reading /etc/shadow with 'cat' (Falco: 'Read sensitive file untrusted')"
    cat /etc/shadow >/dev/null
    sleep 3
    local u; u=$(active_unit)
    journalctl -u "$u" --since "-1 min" -o cat -q --no-pager 2>/dev/null | grep -i 'shadow' | tail -3 \
        || echo "(nothing seen yet - wait a few seconds and look: journalctl -u ${u} -n 20)"
    echo "The next check (--check or cron) mails it."
}

show_status() {
    if ! installed; then echo "anomaly-monitor: Falco not installed"; return 0; fi
    echo "anomaly-monitor: Falco $(falco --version 2>/dev/null | awk 'NR==1 {print $NF}'), $(active_unit || echo "NOT running"), mail to ${ALERT_MAIL:-nobody}, from ${MIN_PRIORITY}, every ${CHECK_INTERVAL_MIN} min"
    [[ -f "$LOG_FILE" ]] && { echo "Last events:"; tail -n 5 "$LOG_FILE" | sed 's/^/  /'; }
    return 0
}

uninstall() {
    echo ">>> Uninstall anomaly-monitor"
    echo "Removed: ${CRON_FILE}, ${CONF}, state. Asked: the Falco package and repository."
    confirm "Really remove?" || { echo "Cancelled."; return 0; }
    rm -f "$CRON_FILE" "$CONF"
    rm -rf "$STATE_DIR"
    if installed && confirm "Remove Falco itself (package and repository)?" Y; then
        systemctl disable --now "${UNITS[@]}" falcoctl-artifact-follow.service >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y falco >/dev/null 2>&1 || true
        rm -f "$REPO_LIST" "$KEYRING"
    fi
    echo "Removed."
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Anomaly detection (Falco)"
        echo "==========================================="
        show_status
        echo
        echo "1) Set up"
        echo "2) Check now (mail new events)"
        echo "3) Trigger a test event"
        echo "4) Show the event log"
        echo "5) Uninstall"
        echo "q) Quit"
        local c; read -rp "Choice: " c || exit 0
        case "$c" in
            1) setup || true; pause ;;
            2) check || true; echo "Done."; pause ;;
            3) test_event || true; pause ;;
            4) [[ -f "$LOG_FILE" ]] && tail -n 40 "$LOG_FILE" || echo "(no events yet)"; pause ;;
            5) uninstall; pause ;;
            q|Q) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --setup)     setup ;;
    --check)     check ;;
    --status)    show_status ;;
    --test)      test_event ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--setup|--check|--status|--test|--uninstall|--version]"; exit 1 ;;
esac
