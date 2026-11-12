#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# security-check.sh - all-round check: is this machine still clean?
#
# Runs the usual Debian tools one after the other and sums them up:
#   debsums     - installed package files changed?
#   rkhunter    - rootkits, changed system binaries, hidden processes
#   chkrootkit  - a second, independent rootkit check
#   lynis       - security audit with hardening score
# plus a few checks with on-board means (failed units, extra root accounts,
# empty passwords, SUID files outside packages, programs running from /tmp,
# listening ports, SSH keys, cron jobs).
#
# Standalone: needs nothing next to it. Missing packages are installed (no
# recommends, so no mail server is pulled in). The full report goes to
# var/security-check/ next to the script; the screen shows the summary.
#
# Usage: sudo ./security-check.sh                run all checks
#        sudo ./security-check.sh --mail ADDR    also mail the report
#        sudo ./security-check.sh --no-install   only use what is installed
#        sudo ./security-check.sh --accept       accept the current state as
#                                                rkhunter baseline (after updates
#                                                and after the findings were checked)
#        sudo ./security-check.sh --schedule     run it regularly (monthly/weekly)
#                                                by cron, mail only on findings
#        sudo ./security-check.sh --unschedule   remove the regular run
#        sudo ./security-check.sh --version
#
# Exit code: 0 nothing found, 1 something to check, 2 a check could not run.
#
# Presets for --schedule: a DEFAULT_* that is set is taken without a question
# (and wins over the stored value); unset ones are asked - in batch mode,
# BATCH=1, nothing is asked and every question takes its default:
#   DEFAULT_SCHEDULE   monthly|weekly|off (monthly, or weekly if stored)
#   DEFAULT_MAIL_TO    recipient of the findings, '-' = none
#                      (unset: the stored one; none: report files only)
set -uo pipefail

# --version must come before the root check so it answers without sudo.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

usage() { sed -n '/^# Usage:/,/^# Exit code/p' "$0" | sed 's/^# \{0,1\}//'; }
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Started from a version directory (<base>/<version>/, see build-bundle.sh):
# paths written into cron and systemd go through <base>/current, so an update
# or a rollback switches them along.
if [[ -L "$DIR/../current" && "$(readlink -f "$DIR/../current")" == "$(readlink -f "$DIR")" ]]; then
    DIR="$(cd "$DIR/../current" && pwd)"
fi
REPORT_DIR="$DIR/var/security-check"
CONF="$DIR/security-check.conf"
CRON_FILE=/etc/cron.d/security-check
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
SCHEDULE="off"          # monthly | weekly | off
SCHED_MAIL=""
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
# A preset wins over the stored value ('-' = no recipient).
[[ -n "${DEFAULT_MAIL_TO:-}" ]] && SCHED_MAIL=$DEFAULT_MAIL_TO
[[ "$SCHED_MAIL" == "-" ]] && SCHED_MAIL=""

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

PKGS=(debsums rkhunter chkrootkit lynis)
EXTRA_PKGS=(lsof unhide)          # rkhunter uses them when present
RKH_LOCAL=/etc/rkhunter.conf.local   # taken over into the generated config
RKH_DB=/var/lib/rkhunter/db/rkhunter.dat
LYNIS_DAT=/var/log/lynis-report.dat

MAIL_TO="" INSTALL=1 MODE=check
while (( $# > 0 )); do
    case "$1" in
        --mail)       MAIL_TO=${2:-}; [[ -n "$MAIL_TO" ]] || { usage; exit 1; }; shift ;;
        --no-install) INSTALL=0 ;;
        --accept)     MODE=accept ;;
        --schedule)   MODE=schedule ;;
        --unschedule) MODE=unschedule ;;
        --cron)       MODE=cron; INSTALL=0 ;;
        *)            usage; exit 1 ;;
    esac
    shift
done

HOST=$(hostname -f 2>/dev/null || hostname)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPORT=""
RESULTS=()          # "name|status|note"; status OK | CHECK | INFO | ERROR

have() { dpkg -s "$1" &>/dev/null; }

result() { RESULTS+=("$1|$2|${3:-}"); }

# section "Title" <file>  - append a tool's output to the report
section() {
    {
        echo
        echo "=== $1 ==="
        if [[ -s "$2" ]]; then cat "$2"; else echo "(nothing)"; fi
    } >> "$REPORT"
}

# show <file> - the first lines on screen, the rest is in the report
show() {
    [[ -s "$1" ]] || return 0
    grep -v -E '^[[:space:]]*$' "$1" | head -n 12 | sed 's/^/    /'
    local n; n=$(wc -l < "$1")
    (( n > 12 )) && echo "    ... $((n - 12)) more line(s) in the report"
    return 0
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
ensure_packages() {
    local -a missing=() p
    for p in "${PKGS[@]}"; do have "$p" || missing+=("$p"); done
    (( ${#missing[@]} == 0 )) && return 0
    if (( INSTALL == 0 )); then
        echo "Not installed, skipped: ${missing[*]}"
        return 0
    fi
    echo ">>> Installing: ${missing[*]}"
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${missing[@]}" >/dev/null 2>&1 || echo "!!! Not all packages could be installed."
    for p in "${EXTRA_PKGS[@]}"; do
        have "$p" || DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "$p" >/dev/null 2>&1 || true
    done
}

# The packaged rkhunter configuration breaks on some systems: WEB_CMD="/bin/false"
# is rejected by current rkhunter, and whitelist entries for files that do not
# exist on this machine (e.g. /usr/sbin/adduser) abort the whole run. Instead of
# editing /etc, a cleaned copy is used: those entries dropped, WEB_CMD emptied,
# and PKGMGR=DPKG so that package updates are no findings. A local
# rkhunter.conf.local is taken over as it is.
RKH_CONF=/var/lib/rkhunter/security-check.conf
rkhunter_prepare() {
    local src=/etc/rkhunter.conf line key val
    [[ -f "$src" ]] || return 1
    mkdir -p "$(dirname "$RKH_CONF")"
    {
        echo "# generated by security-check.sh from ${src} - do not edit"
        cat "$src" "$RKH_LOCAL" /etc/rkhunter.d/*.conf 2>/dev/null | while IFS= read -r line; do
            key=${line%%=*}; val=${line#*=}
            case "$key" in
                WEB_CMD|PKGMGR) continue ;;
                SCRIPTWHITELIST|ALLOWHIDDENFILE|ALLOWHIDDENDIR|ALLOWDEVFILE|ALLOWPROCDELFILE)
                    [[ "$val" == /* && ! -e "${val%% *}" ]] && continue ;;
            esac
            printf '%s\n' "$line"
        done
        echo 'WEB_CMD=""'
        echo 'PKGMGR=DPKG'
    } > "$RKH_CONF"
    chmod 600 "$RKH_CONF"
}

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------
check_debsums() {
    echo ">>> debsums: package files (a few minutes)..."
    have debsums || { result "Package files" "ERROR" "debsums not installed"; return; }
    local out="$WORK/debsums"
    # -s: only deviations; config files are not checked (they are meant to change)
    debsums -s > "$out.raw" 2>&1
    grep -v -E 'no md5sums for|^debsums: missing file /usr/share/(doc|man|locale)/' "$out.raw" > "$out" || true
    section "debsums -s (changed or missing package files)" "$out"
    if [[ -s "$out" ]]; then
        result "Package files" "CHECK" "$(wc -l < "$out") changed/missing file(s)"
        show "$out"
    else
        result "Package files" "OK" "debsums: no changes"
    fi
}

check_rkhunter() {
    echo ">>> rkhunter: rootkits and system binaries (a few minutes)..."
    have rkhunter || { result "Rootkits (rkhunter)" "ERROR" "not installed"; return; }
    rkhunter_prepare || { result "Rootkits (rkhunter)" "ERROR" "/etc/rkhunter.conf missing"; return; }
    local out="$WORK/rkhunter" first=0
    if [[ ! -s "$RKH_DB" ]]; then
        # Without a baseline the file property check has nothing to compare.
        rkhunter --configfile "$RKH_CONF" --propupd --nocolors >/dev/null 2>&1
        first=1
    fi
    rkhunter --configfile "$RKH_CONF" -c --sk --rwo --nocolors > "$out" 2>&1
    section "rkhunter -c --rwo (warnings only; details: /var/log/rkhunter.log)" "$out"
    if grep -q -E 'Invalid .* configuration option|Unknown configuration' "$out"; then
        result "Rootkits (rkhunter)" "ERROR" "configuration error, see report"
    elif [[ -s "$out" ]]; then
        result "Rootkits (rkhunter)" "CHECK" "$(grep -c '^Warning' "$out") warning(s), details in /var/log/rkhunter.log"
        show "$out"
    else
        result "Rootkits (rkhunter)" "OK" "$( ((first)) && echo "baseline created now - file changes count from the next run" || echo "no warnings")"
    fi
}

check_chkrootkit() {
    echo ">>> chkrootkit: second rootkit check..."
    have chkrootkit || { result "Rootkits (chkrootkit)" "ERROR" "not installed"; return; }
    local out="$WORK/chkrootkit"
    chkrootkit -q > "$out" 2>&1
    section "chkrootkit -q (only suspicious items)" "$out"
    if [[ -s "$out" ]]; then
        result "Rootkits (chkrootkit)" "CHECK" "$(wc -l < "$out") line(s) - often false alarms, see report"
        show "$out"
    else
        result "Rootkits (chkrootkit)" "OK" "nothing found"
    fi
}

check_lynis() {
    echo ">>> lynis: security audit (1-3 minutes)..."
    have lynis || { result "Audit (lynis)" "ERROR" "not installed"; return; }
    local out="$WORK/lynis" score warn sugg
    lynis audit system --cronjob > "$out.raw" 2>&1
    if [[ ! -f "$LYNIS_DAT" ]]; then
        cp "$out.raw" "$out"; section "lynis" "$out"
        result "Audit (lynis)" "ERROR" "no report written"
        return
    fi
    score=$(awk -F= '$1=="hardening_index" {print $2}' "$LYNIS_DAT")
    warn=$(grep -c '^warning\[\]=' "$LYNIS_DAT" || true)
    sugg=$(grep -c '^suggestion\[\]=' "$LYNIS_DAT" || true)
    {
        echo "Hardening index: ${score:-?}/100"
        echo "Warnings:"
        grep '^warning\[\]=' "$LYNIS_DAT" | sed 's/^warning\[\]=/  /' || echo "  none"
        echo "Suggestions (${sugg}): lynis show details <ID>, full list in ${LYNIS_DAT}"
        grep '^suggestion\[\]=' "$LYNIS_DAT" | sed 's/^suggestion\[\]=/  /' || true
    } > "$out"
    section "lynis audit system" "$out"
    if (( warn > 0 )); then
        result "Audit (lynis)" "CHECK" "score ${score:-?}, ${warn} warning(s), ${sugg} suggestion(s)"
        grep '^warning\[\]=' "$LYNIS_DAT" | sed 's/^warning\[\]=/    /' | head -8
    else
        result "Audit (lynis)" "INFO" "score ${score:-?}, no warnings, ${sugg} suggestion(s)"
    fi
}

# Checks with on-board means
check_system() {
    echo ">>> System checks..."
    local out

    out="$WORK/failed"
    systemctl list-units --failed --no-legend --plain 2>/dev/null > "$out" || true
    section "Failed systemd units" "$out"
    if [[ -s "$out" ]]; then result "Failed services" "CHECK" "$(awk '{print $1}' "$out" | tr '\n' ' ')"
    else result "Failed services" "OK" ""; fi

    out="$WORK/uid0"
    awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd > "$out"
    section "Accounts with UID 0 besides root" "$out"
    if [[ -s "$out" ]]; then result "Extra root accounts" "CHECK" "$(tr '\n' ' ' < "$out")"
    else result "Extra root accounts" "OK" ""; fi

    out="$WORK/emptypw"
    awk -F: '$2 == "" {print $1}' /etc/shadow > "$out"
    section "Accounts with an empty password" "$out"
    if [[ -s "$out" ]]; then result "Empty passwords" "CHECK" "$(tr '\n' ' ' < "$out")"
    else result "Empty passwords" "OK" ""; fi

    # SUID/SGID files no package knows about. Container layers are skipped:
    # images bring their own (packaged) SUID files.
    out="$WORK/suid"
    : > "$out"
    local f
    while IFS= read -r f; do
        # merged /usr: dpkg may know the file under /bin, /sbin or /lib
        dpkg -S "$f" &>/dev/null || dpkg -S "${f#/usr}" &>/dev/null || echo "$f" >> "$out"
    done < <(find / -xdev \( -path /var/lib/docker -o -path /var/lib/containerd \
                -o -path /proc -o -path /snap \) -prune -o \
                -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null)
    section "SUID/SGID files that belong to no package" "$out"
    if [[ -s "$out" ]]; then result "SUID outside packages" "CHECK" "$(wc -l < "$out") file(s)"
    else result "SUID outside packages" "OK" ""; fi

    # Programs started from world-writable places - a classic for miners/droppers.
    out="$WORK/tmpexe"
    local p exe
    for p in /proc/[0-9]*; do
        exe=$(readlink "$p/exe" 2>/dev/null) || continue
        case "$exe" in
            /tmp/*|/var/tmp/*|/dev/shm/*)
                echo "PID ${p#/proc/} $exe  ($(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-80))" >> "$out" ;;
        esac
    done
    find /tmp /var/tmp /dev/shm -xdev -type f -perm -u+x 2>/dev/null | head -50 \
        | sed 's/^/executable file: /' >> "$out"
    section "Programs / executables in /tmp, /var/tmp, /dev/shm" "$out"
    if [[ -s "$out" ]]; then result "Executables in tmp" "CHECK" "$(wc -l < "$out") item(s)"
    else result "Executables in tmp" "OK" ""; fi

    # Information - nothing to judge automatically, but worth a look.
    out="$WORK/listen"
    ss -tulpnH 2>/dev/null | awk '{print $1, $5, $7}' | sort -u > "$out" || true
    section "Listening ports (proto address process)" "$out"
    result "Listening ports" "INFO" "$(wc -l < "$out") socket(s), list in the report"

    out="$WORK/keys"
    local h u
    while IFS=: read -r u _ _ _ _ h _; do
        for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
            [[ -f "$f" ]] && echo "$u: $f ($(grep -c -v -E '^\s*(#|$)' "$f") key(s))" >> "$out"
        done
    done < /etc/passwd
    section "SSH authorized_keys" "$out"
    result "SSH keys" "INFO" "$( [[ -s "$out" ]] && wc -l < "$out" || echo 0) file(s), list in the report"

    out="$WORK/cron"
    {
        ls -1 /etc/cron.d 2>/dev/null | sed 's|^|/etc/cron.d/|'
        for f in /var/spool/cron/crontabs/*; do
            [[ -f "$f" ]] && echo "user crontab: $(basename "$f")" && sed 's/^/    /' "$f" | grep -v -E '^\s*#|^\s*$'
        done
    } > "$out" 2>/dev/null || true
    section "Cron jobs" "$out"
    result "Cron jobs" "INFO" "list in the report"

    out="$WORK/logins"
    journalctl --since "-7 days" -q _COMM=sshd 2>/dev/null \
        | grep -E 'Failed password|Invalid user|Accepted ' \
        | awk '/Accepted/ {a++} /Failed password|Invalid user/ {f++} END {printf "accepted logins: %d, failed attempts: %d (last 7 days)\n", a, f}' > "$out" || true
    section "SSH logins" "$out"
    result "SSH logins" "INFO" "$(cat "$out" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# The regular run: monthly or weekly at 04:40, mails only when something was
# found or a check could not run. Packages are installed now, not at 04:40.
if [[ "$MODE" == "schedule" ]]; then
    echo "Regular security check by cron - mails only when there is something to look at."
    echo "  1) monthly (1st, 04:40)   (recommended)"
    echo "  2) weekly  (Sunday, 04:40)"
    echo "  3) off"
    def=1; [[ "$SCHEDULE" == weekly ]] && def=2
    # A preset is taken without a question.
    if preset DEFAULT_SCHEDULE; then
        case "$DEFAULT_SCHEDULE" in
            monthly) def=1 ;; weekly) def=2 ;; off) def=3 ;;
            *) echo "!!! DEFAULT_SCHEDULE: '${DEFAULT_SCHEDULE}' is not monthly|weekly|off (preset)" >&2
               exit 2 ;;
        esac
    fi
    if [[ -n "${BATCH:-}" ]] || preset DEFAULT_SCHEDULE; then
        c=$def
        case "$def" in 2) echo -n "Choice: weekly" ;; 3) echo -n "Choice: off" ;; *) echo -n "Choice: monthly" ;; esac
        echo "$(preset_tag DEFAULT_SCHEDULE)"
    else
        read -rp "Choice [${def}]: " c
    fi
    case "${c:-$def}" in 2) SCHEDULE=weekly ;; 3) SCHEDULE=off ;; *) SCHEDULE=monthly ;; esac
    if [[ "$SCHEDULE" != off ]]; then
        r=$SCHED_MAIL; ask r "Mail findings to" "$SCHED_MAIL" "" DEFAULT_MAIL_TO
        [[ "$r" == "-" ]] && r=""
        SCHED_MAIL=$r
        [[ -n "$SCHED_MAIL" ]] || echo "(no recipient - the reports only go to ${REPORT_DIR})"
        ensure_packages
        spec="40 4 1 * *"; [[ "$SCHEDULE" == weekly ]] && spec="40 4 * * 0"
        printf '%s\n' "# security-check - regular run (written by ${SELF})" \
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            "${spec} root ${SELF} --cron >/dev/null 2>&1" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
    else
        rm -f "$CRON_FILE"
    fi
    printf '%s\n' "# security-check configuration" "SCHEDULE=\"${SCHEDULE}\"" "SCHED_MAIL=\"${SCHED_MAIL}\"" > "$CONF"
    echo "Regular run: ${SCHEDULE}${SCHED_MAIL:+, findings to ${SCHED_MAIL}}."
    exit 0
fi
if [[ "$MODE" == "unschedule" ]]; then
    rm -f "$CRON_FILE"
    [[ -f "$CONF" ]] && sed -i 's/^SCHEDULE=.*/SCHEDULE="off"/' "$CONF"
    echo "Regular run removed."
    exit 0
fi
[[ "$MODE" == "cron" ]] && MAIL_TO=$SCHED_MAIL

if [[ "$MODE" == "accept" ]]; then
    have rkhunter || { echo "rkhunter is not installed."; exit 2; }
    rkhunter_prepare || { echo "/etc/rkhunter.conf is missing."; exit 2; }
    echo "The current state of the system files becomes the rkhunter baseline."
    echo "Do this only after the findings were checked (or right after updates)."
    confirm "Accept?" || { echo "Cancelled."; exit 0; }
    rkhunter --configfile "$RKH_CONF" --propupd --nocolors && echo "Baseline updated."
    exit 0
fi

mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/$(hostname -s)-$(date +%Y%m%d-%H%M).txt"
{
    echo "security-check ${VERSION} on ${HOST}"
    echo "Date:   $(date '+%F %T')"
    echo "OS:     $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"), kernel $(uname -r)"
} > "$REPORT"
chmod 600 "$REPORT"

echo "security-check ${VERSION} on ${HOST} - takes about 5 to 15 minutes."
echo
ensure_packages
check_debsums
check_rkhunter
check_chkrootkit
check_lynis
check_system

# Summary
summary="$WORK/summary"
{
    printf '%-24s %-6s %s\n' "CHECK" "RESULT" "NOTE"
    printf '%-24s %-6s %s\n' "------------------------" "------" "----"
    for line in "${RESULTS[@]}"; do
        IFS='|' read -r name status note <<<"$line"
        printf '%-24s %-6s %s\n' "$name" "$status" "$note"
    done
} > "$summary"
{ echo; echo "=== Summary ==="; cat "$summary"; } >> "$REPORT"

ncheck=$(printf '%s\n' "${RESULTS[@]}" | grep -c '|CHECK|' || true)
nerr=$(printf '%s\n' "${RESULTS[@]}" | grep -c '|ERROR|' || true)

echo
echo "==========================================================="
echo " Summary"
echo "==========================================================="
cat "$summary"
echo
echo "Full report: ${REPORT}"
if (( ncheck > 0 )); then
    cat <<'EOF'

CHECK means: look at it, not necessarily compromised. Typical false alarms:
rkhunter after package updates (then: --accept), chkrootkit "PACKET SNIFFER"
for dhclient/systemd-networkd, scripts in /tmp from an installer.
On a real suspicion: do not clean up on the machine, take it off the net
and escalate - a compromised system can fool all of these tools.
EOF
fi

# The cron run keeps the last 12 reports and mails only when there is
# something to look at.
if [[ "$MODE" == "cron" ]]; then
    ls -1t "$REPORT_DIR"/*.txt 2>/dev/null | tail -n +13 | xargs -r rm -f
    (( ncheck + nerr > 0 )) || MAIL_TO=""
fi

if [[ -n "$MAIL_TO" ]]; then
    if command -v mail &>/dev/null; then
        mail -s "security-check ${HOST}: ${ncheck} to check, ${nerr} error(s)" "$MAIL_TO" < "$REPORT" \
            && echo "Report mailed to ${MAIL_TO}." || echo "!!! Sending the mail failed."
    else
        echo "!!! 'mail' is not available - report not mailed."
    fi
fi

if (( nerr > 0 )); then exit 2; elif (( ncheck > 0 )); then exit 1; else exit 0; fi
