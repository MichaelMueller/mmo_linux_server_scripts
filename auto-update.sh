#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# auto-update.sh - automatic apt updates via cron, with a mail report
#
# Two kinds of updates:
#   safe updates  - fixes that change nothing in behaviour, unattended:
#                   * the Debian/Ubuntu security sources (unattended-upgrades;
#                     its own timer is switched off, auto-update calls it)
#                   * third-party repositories of this server (Docker,
#                     Tailscale, Caddy, Falco, nginx.org, Apache from Sury):
#                     only versions within the range the project keeps
#                     compatible (TP_SOURCES), checked afterwards and rolled
#                     back when the check fails
#                   Quick ones (the service is back in seconds) run hourly,
#                   noticeable ones (Docker restarts containers, Tailscale cuts
#                   the tailnet connections) in the night window.
#   other updates - everything else, potentially breaking (apt-get
#                   dist-upgrade): by hand, or weekly/daily in the night window.
# A reboot that becomes necessary (new kernel) happens in the night window,
# after the updates - or never (only reported). Mail goes to MAIL_TO on
# errors, on a rollback, and when other updates wait longer than
# OTHER_WAIT_DAYS.
#
# Modes: (no argument)  = interactive menu
#        --setup        = guided setup (four questions)
#        --run security = hourly run: security + quick safe updates (cron)
#        --run night    = night run: safe updates, other updates when due,
#                         reboot when needed (cron)
#        --run safe     = all safe updates now
#        --run all      = the other updates now (dist-upgrade)
#        --upgrade-now  = interactive full upgrade right now (lists, asks)
#        --pending      = pending updates and their kind
#        --overview     = key=value lines for base-setup.sh --check
#        --at-boot      = after a boot (for cron): containers, reboot marker
#        --status       = short status on stdout
#        --uninstall    = uninstall
#
# Presets: a DEFAULT_<KEY> environment variable that is set (e.g.
# DEFAULT_MAIL_TO) is taken without a question and wins over the stored value;
# the tool prints "<question>: <value> (preset)". Unset ones are asked as
# usual. Batch mode (BATCH=1, e.g. from base-setup.sh): --setup and
# --upgrade-now ask nothing - every question takes its default (stored or
# built-in) and prints what it took. Accepted:
#   DEFAULT_SEC_SCHEDULE      interval|daily|off  safe updates: hourly, nightly, off (interval)
#   DEFAULT_SEC_INTERVAL_MIN  10|15|20|30|60      minutes for "interval"             (60)
#   DEFAULT_FULL_SCHEDULE     off|weekly|daily    other updates: by hand, ...        (off)
#   DEFAULT_FULL_WEEKDAY      0-6, 0=Sunday       for "weekly"                       (0)
#   DEFAULT_SEC_REBOOT        window|never|now    a needed reboot                    (window)
#   DEFAULT_FULL_REBOOT       window|never|now    the same after other updates       (window)
#   DEFAULT_REBOOT_TIME       HH:MM               the night window                   (03:00)
#   DEFAULT_SEC_RESTART       0|1                 restart affected services          (1)
#   DEFAULT_FULL_RESTART      0|1                                                    (1)
#   DEFAULT_MAIL_TO           address(es), '-' = none                                (empty)
#   DEFAULT_MAIL_ON_ERROR     0|1                                                    (1)
#   DEFAULT_MAIL_ON_INSTALL   0|1                                                    (0)
#   DEFAULT_MAIL_ON_NOOP      0|1                                                    (0)
#   DEFAULT_ADVANCED          Y|N - show the advanced questions                      (N)
#   DEFAULT_EXCLUDE_PKGS      package globs, '-' = none                              (empty)
#   DEFAULT_AUTOREMOVE        0|1                                                    (1)
#   DEFAULT_RESTORE_CONTAINERS 0|1                                                   (1)
#   DEFAULT_POST_UPDATE_REDEPLOY 0|1                                                 (0)
#   DEFAULT_LOG_FILE          path                                 (var/auto-update.log)
#   DEFAULT_UPGRADE_NOW       Y|N - --upgrade-now installs                           (Y)
# Older keys still read (no longer used - everything runs in the night window):
#   DEFAULT_SEC_TIME, DEFAULT_SEC_WEEKDAY, DEFAULT_FULL_TIME; SEC_SCHEDULE=weekly
#   runs the security updates in the night window on SEC_WEEKDAY.
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end instead of aborting mid-run and swallowing the report.
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
CONF="$DIR/auto-update.conf"
CRON_FILE=/etc/cron.d/auto-update
GITUP_SCRIPT="$DIR/git-updater.sh"
REBOOT_FLAG="$DIR/var/auto-update.reboot-wanted"
CONTAINER_STATE="$DIR/var/auto-update.containers"
# Settings for unattended-upgrades: security sources only, no timer of its
# own, no reboot, no mail - auto-update does that. Sorts after the package's
# 20auto-upgrades and 50unattended-upgrades, so these values win.
UU_CONF=/etc/apt/apt.conf.d/52auto-update
UU_LOG=/var/log/unattended-upgrades/unattended-upgrades.log

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Keys and their defaults. Empty before loading, so that it is visible what
# the configuration file set - for the migration of older formats below.
KEYS=(SEC_SCHEDULE SEC_INTERVAL_MIN SEC_TIME SEC_WEEKDAY SEC_RESTART SEC_REBOOT
      FULL_SCHEDULE FULL_TIME FULL_WEEKDAY FULL_RESTART FULL_REBOOT
      REBOOT_TIME EXCLUDE_PKGS AUTOREMOVE POST_UPDATE_REDEPLOY RESTORE_CONTAINERS
      MAIL_TO MAIL_ON_INSTALL MAIL_ON_ERROR MAIL_ON_NOOP LOG_FILE)
declare -A DEF=(
    [SEC_SCHEDULE]=interval   # interval | daily | weekly | off
    [SEC_INTERVAL_MIN]=60     # 10 15 20 30 60
    [SEC_TIME]="03:30"        # HH:MM for daily/weekly
    [SEC_WEEKDAY]=0           # 0=Sunday ... 6=Saturday
    [SEC_RESTART]=1           # restart affected services (needrestart -r a)
    [SEC_REBOOT]=window       # never | window | now
    [FULL_SCHEDULE]=off       # weekly | daily | off (= by hand)
    [FULL_TIME]="02:00"
    [FULL_WEEKDAY]=0
    [FULL_RESTART]=1
    [FULL_REBOOT]=window
    [REBOOT_TIME]="03:00"     # the nightly reboot window
    [EXCLUDE_PKGS]=""         # package names/globs never updated automatically
    [AUTOREMOVE]=1
    [POST_UPDATE_REDEPLOY]=0  # after an installation: git-updater.sh --redeploy
    [RESTORE_CONTAINERS]=1    # start containers again that ran before
    [MAIL_TO]=""
    # A successful update is the expected outcome; a mail for each one gets
    # filtered away - taking the error mails with it. Errors stay on.
    [MAIL_ON_INSTALL]=0
    [MAIL_ON_ERROR]=1
    [MAIL_ON_NOOP]=0
    [LOG_FILE]="$DIR/var/auto-update.log"
)
for _k in "${KEYS[@]}"; do printf -v "$_k" '%s' ""; done
# Keys of older versions - only read to migrate their configurations.
SCHEDULE="" WEEKDAY=0 INTERVAL_MIN=30 HOUR=3 MINUTE=30 MODE=""
RESTART_SERVICES="" AUTO_REBOOT="" NIGHTLY_REBOOT="" MAIL_WHEN=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# --- Migration of older configurations -------------------------------------
# before 2.3: one schedule with one scope (MODE)
if [[ -z "$SEC_SCHEDULE" && -z "$FULL_SCHEDULE" && -n "$SCHEDULE" ]]; then
    _t=$(printf '%02d:%02d' "$((10#${HOUR}))" "$((10#${MINUTE}))")
    if [[ "$MODE" == "all" ]]; then
        SEC_SCHEDULE=off
        FULL_SCHEDULE=$([[ "$SCHEDULE" == "weekly" ]] && echo weekly || echo daily)
        # shellcheck disable=SC2034  # saved with the other keys (save_conf)
        FULL_TIME=$_t; FULL_WEEKDAY=$WEEKDAY
    else
        SEC_SCHEDULE=$SCHEDULE; SEC_INTERVAL_MIN=$INTERVAL_MIN
        SEC_TIME=$_t; SEC_WEEKDAY=$WEEKDAY; FULL_SCHEDULE=off
    fi
fi
# before 2.3.0: one restart switch and one reboot setting for both kinds
if [[ -n "$RESTART_SERVICES" ]]; then
    [[ -z "$SEC_RESTART" ]] && SEC_RESTART=$RESTART_SERVICES
    [[ -z "$FULL_RESTART" ]] && FULL_RESTART=$RESTART_SERVICES
fi
if [[ -n "$AUTO_REBOOT$NIGHTLY_REBOOT" && -z "$SEC_REBOOT" ]]; then
    if [[ "$AUTO_REBOOT" == 1 ]]; then _r=now
    elif [[ "$NIGHTLY_REBOOT" == required || "$NIGHTLY_REBOOT" == always ]]; then _r=window
    else _r=never; fi
    SEC_REBOOT=$_r; FULL_REBOOT=$_r
fi
# older still: one MAIL_WHEN instead of three switches
case "$MAIL_WHEN" in
    always) MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=1 ;;
    errors) MAIL_ON_INSTALL=0; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
    ?*)     MAIL_ON_INSTALL=1; MAIL_ON_ERROR=1; MAIL_ON_NOOP=0 ;;
esac
unset _t _r

# --- Presets and defaults: a DEFAULT_<KEY> from the caller is a preset and
# wins over the stored value; what is still empty gets the built-in default.
# MAIL_TO and EXCLUDE_PKGS may stay empty on purpose.
for _k in "${KEYS[@]}"; do
    _d="DEFAULT_${_k}"
    if [[ -n "${!_d:-}" ]]; then
        printf -v "$_k" '%s' "${!_d}"; continue
    fi
    [[ -n "${!_k}" ]] && continue
    printf -v "$_k" '%s' "${DEF[$_k]}"
done
unset _k _d
# '-' clears, as in the questions (DEFAULT_MAIL_TO=- : no mail)
[[ "$MAIL_TO" == "-" ]] && MAIL_TO=""
[[ "$EXCLUDE_PKGS" == "-" ]] && EXCLUDE_PKGS=""

# A relative LOG_FILE would land wherever cron happens to stand.
case "$LOG_FILE" in
    /*) ;;
    *)  LOG_FILE="$DIR/${LOG_FILE#./}" ;;
esac

# One lock for the update runs and the reboot window: runs must not pile up,
# and the reboot must not cut an apt run in half.
LOCK_FILE=/run/auto-update.lock
APT_LOCK_WAIT=600       # seconds apt waits for a dpkg lock held by another process

DAYS=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

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
yn() { [[ "$1" == 1 ]] && echo Y || echo N; }
# a Y/N default from a DEFAULT_* variable: Y, y, J, j, 1, yes -> Y, else N
yn_def() { [[ "${1:-}" =~ ^([YyJj1]|[Yy]es)$ ]] && echo Y || echo N; }

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
    {
        echo "# auto-update configuration (auto-update.sh ${VERSION})"
        local k
        for k in "${KEYS[@]}"; do printf '%s="%s"\n' "$k" "${!k}"; done
    } > "$CONF"
    chmod 644 "$CONF"
}

# Save and put the schedule into effect.
apply_settings() {
    mkdir -p "$(dirname "$LOG_FILE")"
    save_conf
    write_cron
    if [[ "$SEC_SCHEDULE" != off ]]; then ensure_uu; else write_uu_conf; fi
    if (( SEC_RESTART + FULL_RESTART > 0 )) || [[ "$SEC_REBOOT$FULL_REBOOT" != nevernever ]]; then
        ensure_needrestart
    fi
}

# needrestart restarts the services and tells whether the kernel is outdated
# (Debian leaves no /var/run/reboot-required behind).
ensure_needrestart() {
    command -v needrestart &>/dev/null && return 0
    echo ">>> Installing needrestart..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y needrestart >/dev/null 2>&1 \
        || echo "!!! needrestart could not be installed - no service restarts, no kernel check."
}

uu_installed() { dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "ok installed"; }

# The exclusions are shell globs ("docker*"); unattended-upgrades wants
# regular expressions.
glob_to_regex() {
    local g=$1
    g=${g//./\\.}; g=${g//+/\\+}; g=${g//\*/.*}; g=${g//\?/.}
    echo "^${g}\$"
}

write_uu_conf() {
    uu_installed || return 0
    local p
    local -a pats=()
    read -r -a pats <<<"$EXCLUDE_PKGS"
    {
        echo "// written by auto-update.sh - do not edit, run auto-update.sh --setup"
        echo "// unattended-upgrades only runs when auto-update calls it (security"
        echo "// updates: $(safe_text)); reboots and mails are auto-update's job."
        echo 'APT::Periodic::Unattended-Upgrade "0";'
        echo 'Unattended-Upgrade::Automatic-Reboot "false";'
        echo 'Unattended-Upgrade::Mail "";'
        echo 'Unattended-Upgrade::Remove-Unused-Dependencies "false";'
        echo "// security sources only (the package default adds the point releases)"
        echo '#clear Unattended-Upgrade::Allowed-Origins;'
        echo '#clear Unattended-Upgrade::Origins-Pattern;'
        echo 'Unattended-Upgrade::Origins-Pattern {'
        echo '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
        echo '    "origin=Debian,codename=${distro_codename},label=Debian-Security";'
        echo '    "origin=Ubuntu,archive=${distro_codename}-security";'
        echo '    "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
        echo '    "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";'
        echo '};'
        if (( ${#pats[@]} > 0 )); then
            echo "// exclusions (EXCLUDE_PKGS)"
            echo 'Unattended-Upgrade::Package-Blacklist {'
            for p in "${pats[@]}"; do echo "    \"$(glob_to_regex "$p")\";"; done
            echo '};'
        fi
    } > "$UU_CONF"
    chmod 644 "$UU_CONF"
}

ensure_uu() {
    if ! uu_installed; then
        echo ">>> Installing unattended-upgrades..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null 2>&1 \
            || { echo "!!! unattended-upgrades could not be installed."; return 1; }
    fi
    write_uu_conf
}

# Packages unattended-upgrades would install now (dry run).
uu_pending() {
    uu_installed || return 0
    unattended-upgrade --dry-run -v 2>/dev/null \
        | sed -n 's/^Packages that will be upgraded: //p' | tr ' ' '\n' | grep . || true
}

# ---------------------------------------------------------------------------
# Third-party repositories: which new versions count as safe
# ---------------------------------------------------------------------------
# name|URL pattern of the repository|safe range|quick or noticeable|services
#   safe range: any   - every new version
#               major - the same major version (0.x: the same minor)
#               minor - the same major.minor
#   quick:      the service is back in seconds - may run hourly
#   noticeable: only in the night window
#   services:   must be running again afterwards (those that ran before)
# Why: Docker follows SemVer since 23 (breaking changes only in major
# versions, fixes only for the newest line; a minor update restarts the
# containers - live-restore covers patch versions only). Tailscale keeps one
# compatible line, but its restart cuts every tailnet connection, the admin's
# SSH session included. Caddy has been 2.x for years, its minor versions now
# and then change config or behaviour. Falco minor versions can bring new
# rules, i.e. new alerts. nginx.org: an even minor is a stable branch with
# fixes only. Apache from Sury: 2.4 for years. Debian's own nginx, Apache and
# everything else come with the security run.
TP_SOURCES=(
    "Docker|download\.docker\.com|major|noticeable|docker containerd"
    "Tailscale|pkgs\.tailscale\.com|any|noticeable|tailscaled"
    "Caddy|dl\.cloudsmith\.io/public/caddy|minor|quick|caddy"
    "Falco|download\.falco\.org|minor|quick|falco falco-modern-bpf falco-bpf falco-kmod"
    "nginx.org|nginx\.org/packages|minor|quick|nginx"
    "Apache (Sury)|packages\.sury\.org/apache2|minor|quick|apache2"
    "Trivy|aquasecurity\.github\.io/trivy-repo|major|quick|"
)
OTHER_WAIT_DAYS=14      # other updates waiting longer: [!] in the overview, a mail
DOCKER_WAIT=600         # seconds the containers get to run (and be healthy) again
HELD_FILE="$DIR/var/auto-update.held"          # held after a failed check
PENDING_STATE="$DIR/var/auto-update.pending"   # package first-seen-epoch
REMIND_FILE="$DIR/var/auto-update.reminded"    # last "other updates waiting" mail

# tp_field "<source line or name>" N - field N of a TP_SOURCES entry
tp_field() {
    local s
    for s in "${TP_SOURCES[@]}"; do
        [[ "$s" == "$1" || "${s%%|*}" == "$1" ]] && { cut -d'|' -f"$2" <<<"$s"; return 0; }
    done
    return 1
}
# tp_source URL -> the TP_SOURCES entry of that repository
tp_source() {
    local s re
    for s in "${TP_SOURCES[@]}"; do
        re=$(cut -d'|' -f2 <<<"$s")
        [[ "$1" =~ $re ]] && { echo "$s"; return 0; }
    done
    return 1
}
# upstream_ver 5:28.0.4-1~debian.12~bookworm -> 28.0.4
upstream_ver() { local v=${1#*:}; echo "${v%%[-~+]*}"; }
# in_range RANGE INSTALLED NEW
in_range() {
    local -a x y
    IFS=. read -r -a x <<<"$(upstream_ver "$2")"
    IFS=. read -r -a y <<<"$(upstream_ver "$3")"
    case "$1" in
        any)   return 0 ;;
        major) [[ "${x[0]:-}" == "${y[0]:-}" ]] || return 1
               [[ "${x[0]:-}" != 0 || "${x[1]:-}" == "${y[1]:-}" ]] ;;
        minor) [[ "${x[0]:-}" == "${y[0]:-}" && "${x[1]:-}" == "${y[1]:-}" ]] ;;
        *)     return 1 ;;
    esac
}

# Every upgradable package, one line each:
#   package|installed|candidate|kind|version to install|source
# kind: safe (Debian security, or a third-party version within its range -
# then "version to install" is the highest such version), other, excluded.
# Works on the package lists as they are (no apt-get update).
classify_pending() {
    local line p v u s pkg target src cand_url held
    held=$(apt-mark showhold 2>/dev/null)
    local -a pkgs=()
    local -A INST CAND SUITE VERS
    while read -r line; do
        # openssl/stable-security 3.0.15-1~deb12u1 amd64 [upgradable from: 3.0.14-1~deb12u2]
        [[ "$line" =~ ^([^/]+)/([^\ ]+)\ ([^\ ]+)\ [^\ ]+\ \[upgradable\ from:\ ([^]]+)\] ]] || continue
        pkg=${BASH_REMATCH[1]}
        SUITE[$pkg]=${BASH_REMATCH[2]}; CAND[$pkg]=${BASH_REMATCH[3]}; INST[$pkg]=${BASH_REMATCH[4]}
        pkgs+=("$pkg")
    done < <(LC_ALL=C apt list --upgradable 2>/dev/null)
    (( ${#pkgs[@]} > 0 )) || return 0
    # every version of these packages with its repository
    while IFS='|' read -r p v u; do
        p=${p//[[:space:]]/}; v=${v//[[:space:]]/}; u=${u#"${u%%[![:space:]]*}"}
        [[ -n "$p" && -n "$v" && "$u" == *Packages* ]] || continue
        VERS[$p]+="${v} ${u%% *}"$'\n'
    done < <(LC_ALL=C apt-cache madison "${pkgs[@]}" 2>/dev/null)
    for pkg in "${pkgs[@]}"; do
        # held (by a failed check, or by hand): neither kind installs it
        if grep -qxF "$pkg" <<<"$held"; then
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|held||"; continue
        fi
        if pkg_excluded "$pkg"; then
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|excluded||"; continue
        fi
        if [[ "${SUITE[$pkg]}" == *-security* ]]; then
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|safe|${CAND[$pkg]}|security"; continue
        fi
        src=""; target=""; cand_url=""
        while read -r v u; do
            [[ -n "$v" ]] || continue
            [[ "$v" == "${CAND[$pkg]}" ]] && cand_url=$u
            s=$(tp_source "$u") || continue
            src=${s%%|*}
            dpkg --compare-versions "$v" gt "${INST[$pkg]}" || continue
            in_range "$(cut -d'|' -f3 <<<"$s")" "${INST[$pkg]}" "$v" || continue
            if [[ -z "$target" ]] || dpkg --compare-versions "$v" gt "$target"; then target=$v; fi
        done <<<"${VERS[$pkg]:-}"
        if [[ -n "$src" && -n "$target" ]]; then
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|safe|${target}|${src}"
        elif [[ -n "$src" ]]; then
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|other||${src}"
        else
            # Debian/Ubuntu, or a repository no heuristic knows: its host
            u=${cand_url#*://}; u=${u%%/*}
            case "$u" in
                *debian.org|*ubuntu.com|*canonical.com|"") u=distribution ;;
            esac
            echo "${pkg}|${INST[$pkg]}|${CAND[$pkg]}|other||${u}"
        fi
    done
}

# First-seen time per pending package - for "waiting N days". Reads the
# classification on stdin; packages no longer pending drop out.
track_pending() {
    local now pkg rest t
    local -A seen=()
    now=$(date +%s)
    mkdir -p "$(dirname "$PENDING_STATE")"
    if [[ -f "$PENDING_STATE" ]]; then
        while read -r pkg t; do [[ -n "$pkg" ]] && seen[$pkg]=$t; done < "$PENDING_STATE"
    fi
    while IFS='|' read -r pkg rest; do
        [[ -n "$pkg" ]] || continue
        echo "${pkg} ${seen[$pkg]:-$now}"
    done > "${PENDING_STATE}.new"
    mv "${PENDING_STATE}.new" "$PENDING_STATE"
}
# oldest_other_days <classification> - age of the oldest waiting other update
oldest_other_days() {
    local pkg kind t oldest="" now
    local -A seen=()
    [[ -f "$PENDING_STATE" ]] && while read -r pkg t; do seen[$pkg]=$t; done < "$PENDING_STATE"
    now=$(date +%s)
    while IFS='|' read -r pkg _ _ kind _ _; do
        [[ "$kind" == other ]] || continue
        t=${seen[$pkg]:-$now}
        [[ -z "$oldest" || "$t" -lt "$oldest" ]] && oldest=$t
    done <<<"$1"
    [[ -n "$oldest" ]] && echo $(( (now - oldest) / 86400 )) || echo 0
}
# other_summary <classification> - "Docker 29.0.1, Caddy 2.10.0, 7 distribution"
other_summary() {
    local pkg cand kind src out="" n=0
    local -A shown=()
    while IFS='|' read -r pkg _ cand kind _ src; do
        [[ "$kind" == other ]] || continue
        if [[ "$src" == distribution ]]; then n=$((n + 1)); continue; fi
        [[ -n "${shown[$src]:-}" ]] && continue
        shown[$src]=1
        if tp_field "$src" 1 >/dev/null; then out+="${src} $(upstream_ver "$cand"), "
        else out+="${pkg} (${src}), "; fi
    done <<<"$1"
    (( n > 0 )) && out+="${n} distribution package(s), "
    echo "${out%, }"
}

# Repositories configured on this server that neither the distribution nor a
# TP_SOURCES entry covers - their packages only come with "other updates".
unknown_repos() {
    LC_ALL=C apt-cache policy 2>/dev/null | awk '
        /^ *[0-9]+ (https?|file|ftp):/ { url = $2; next }
        /release / && url != "" {
            if ($0 !~ /o=(Debian|Ubuntu|UbuntuESM|UbuntuESMApps|Canonical)(,|$)/) print url
            url = ""
        }' | while read -r u; do
            tp_source "$u" >/dev/null && continue
            u=${u#*://}; echo "${u%%/*}"
        done | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# The TP_SOURCES this server actually uses (a repository is configured).
tp_present() {
    local s re urls
    urls=$(LC_ALL=C apt-cache policy 2>/dev/null | awk '/^ *[0-9]+ (https?|file|ftp):/ {print $2}')
    for s in "${TP_SOURCES[@]}"; do
        re=$(cut -d'|' -f2 <<<"$s")
        grep -qE "$re" <<<"$urls" && echo "${s%%|*}"
    done
    return 0
}

# The packages a failed check held that are still held - released by hand
# ones drop out of the list.
held_now() {
    [[ -s "$HELD_FILE" ]] || return 0
    local h
    h=$(comm -12 <(sort -u "$HELD_FILE") <(apt-mark showhold 2>/dev/null | sort -u))
    if [[ -n "$h" ]]; then printf '%s\n' "$h" > "$HELD_FILE"; else rm -f "$HELD_FILE"; fi
    tr '\n' ' ' <<<"$h" | sed 's/ *$//'
}

tailscale_running() { tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; }

# The containers that ran before must run again; those healthy before must be
# healthy again. Containers can take a while - up to DOCKER_WAIT seconds.
docker_check() {
    local tmp=$1 list=${CONTAINER_HEALTH:-} id was st name waited=0 bad
    [[ -n "$list" && -s "$list" ]] || return 0
    [[ -n "${CONTAINERS_BEFORE:-}" ]] && restore_containers "$CONTAINERS_BEFORE" >> "$tmp" 2>&1
    while true; do
        bad=""
        while read -r id was; do
            [[ -n "$id" ]] || continue
            st=$(docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null) \
                || continue                       # removed meanwhile - not our business
            [[ "$st" == "true healthy" ]] && continue
            [[ "${st%% *}" == true && "$was" != healthy ]] && continue
            name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null); bad+="${name#/} (${st}) "
        done < "$list"
        [[ -z "$bad" ]] && return 0
        (( waited >= DOCKER_WAIT )) && break
        sleep 10; waited=$((waited + 10))
    done
    echo "!!! after ${DOCKER_WAIT}s not running or not healthy: ${bad}" >> "$tmp"
    return 1
}

# tp_check TMP SOURCE TAILSCALE_WAS_UP SERVICE... - after an update of SOURCE:
# the services that ran before run again, the configuration is valid.
tp_check() {
    local tmp=$1 src=$2 tsup=$3 u ok=0
    shift 3
    for u in "$@"; do
        for _ in $(seq 1 30); do systemctl is-active --quiet "$u" && break; sleep 2; done
        systemctl is-active --quiet "$u" || { echo "!!! ${u} is not running" >> "$tmp"; ok=1; }
    done
    case "$src" in
        Caddy)
            if command -v caddy &>/dev/null && [[ -f /etc/caddy/Caddyfile ]]; then
                local out
                out=$(caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) \
                    || { printf '%s\n' "$out" | tail -5 >> "$tmp"; echo "!!! caddy validate failed" >> "$tmp"; ok=1; }
            fi ;;
        nginx*)
            if command -v nginx &>/dev/null; then
                nginx -t 2>>"$tmp" || { echo "!!! nginx -t failed" >> "$tmp"; ok=1; }
            fi ;;
        Apache*)
            if command -v apachectl &>/dev/null; then
                apachectl configtest 2>>"$tmp" || { echo "!!! apachectl configtest failed" >> "$tmp"; ok=1; }
            fi ;;
        Tailscale)
            if (( tsup == 1 )); then
                for _ in $(seq 1 30); do tailscale_running && break; sleep 2; done
                tailscale_running || { echo "!!! tailscale is not connected again" >> "$tmp"; ok=1; }
            fi ;;
        Docker)
            docker_check "$tmp" || ok=1 ;;
    esac
    return $ok
}

# tp_update TMP SOURCE "pkg=new ..." "pkg=old ..." - install, check, and go
# back to the old versions (held) when the check fails.
tp_update() {
    local tmp=$1 src=$2 new=$3 old=$4 u tsup=0 names
    local -a active=() newv oldv
    read -r -a newv <<<"$new"; read -r -a oldv <<<"$old"
    for u in $(tp_field "$src" 5); do
        systemctl is-active --quiet "$u" 2>/dev/null && active+=("$u")
    done
    [[ "$src" == Tailscale ]] && tailscale_running && tsup=1
    names=$(printf '%s\n' "${newv[@]}" | cut -d= -f1 | tr '\n' ' ')
    { echo; echo "--- ${src}: ${newv[*]} ---"; } >> "$tmp"
    if ! apt-get -y "${APT_LOCKWAIT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            install --only-upgrade "${newv[@]}" >>"$tmp" 2>&1; then
        echo "!!! ${src}: the installation failed" >> "$tmp"
        return 1
    fi
    changed=1
    local -a nm; read -r -a nm <<<"$names"; pkgs+=("${nm[@]}")
    if tp_check "$tmp" "$src" "$tsup" "${active[@]}"; then
        echo "${src}: checked - running" >> "$tmp"
        return 0
    fi
    echo "!!! ${src}: the check failed - back to the previous version" >> "$tmp"
    if apt-get -y "${APT_LOCKWAIT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            --allow-downgrades install "${oldv[@]}" >>"$tmp" 2>&1; then
        apt-mark hold "${nm[@]}" >/dev/null 2>&1
        mkdir -p "$(dirname "$HELD_FILE")"
        printf '%s\n' "${nm[@]}" >> "$HELD_FILE"; sort -u -o "$HELD_FILE" "$HELD_FILE"
        echo "Back on ${oldv[*]} and held - no automatic updates for them until" >> "$tmp"
        echo "the cause is fixed and they are released: apt-mark unhold ${names}" >> "$tmp"
        tp_check "$tmp" "$src" "$tsup" "${active[@]}" && echo "${src}: running again on the old version" >> "$tmp"
    else
        echo "!!! going back failed - check ${src} by hand" >> "$tmp"
    fi
    return 1
}

# run_third_party TMP quick|all - the safe third-party versions, per source
run_third_party() {
    local tmp=$1 which=$2 rc=0 pkg inst kind target src cls
    local -A NEW=() OLD=()
    while IFS='|' read -r pkg inst _ kind target src; do
        [[ "$kind" == safe && "$src" != security && -n "$src" ]] || continue
        cls=$(tp_field "$src" 4)
        [[ "$which" == all || "$cls" == quick ]] || continue
        NEW[$src]+="${pkg}=${target} "; OLD[$src]+="${pkg}=${inst} "
    done <<<"$CLASSIFIED"
    for src in "${!NEW[@]}"; do
        tp_update "$tmp" "$src" "${NEW[$src]}" "${OLD[$src]}" || rc=1
    done
    return $rc
}

# After the security run: nginx and Apache from the distribution - their
# configuration still valid, running. No older fixed version to go back to.
check_dist_webservers() {
    local tmp=$1 rc=0
    if printf '%s\n' "${pkgs[@]}" | grep -q '^nginx' && command -v nginx &>/dev/null; then
        nginx -t 2>>"$tmp" && systemctl is-active --quiet nginx \
            || { echo "!!! nginx: configuration test or service failed after the security update - check by hand" >> "$tmp"; rc=1; }
    fi
    if printf '%s\n' "${pkgs[@]}" | grep -q '^apache2' && command -v apachectl &>/dev/null; then
        apachectl configtest 2>>"$tmp" && systemctl is-active --quiet apache2 \
            || { echo "!!! apache2: configuration test or service failed after the security update - check by hand" >> "$tmp"; rc=1; }
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Texts
# ---------------------------------------------------------------------------
# safe_text - when the safe updates run
safe_text() {
    local noticeable=() s
    for s in $(tp_present); do [[ "$(tp_field "$s" 4)" == noticeable ]] && noticeable+=("$s"); done
    case "$SEC_SCHEDULE" in
        interval)
            if (( ${#noticeable[@]} > 0 )); then
                echo "unattended - quick ones every ${SEC_INTERVAL_MIN} min, $(IFS=/; echo "${noticeable[*]}") at ${REBOOT_TIME}"
            else
                echo "unattended - every ${SEC_INTERVAL_MIN} min"
            fi ;;
        daily)   echo "unattended - nightly at ${REBOOT_TIME}" ;;
        weekly)  echo "unattended - ${DAYS[$SEC_WEEKDAY]} at ${REBOOT_TIME}" ;;
        *)       echo "off" ;;
    esac
}
# other_text - when the other updates run
other_text() {
    case "$FULL_SCHEDULE" in
        daily)  echo "daily at ${REBOOT_TIME}" ;;
        weekly) echo "weekly, ${DAYS[$FULL_WEEKDAY]} at ${REBOOT_TIME}" ;;
        *)      echo "by hand" ;;
    esac
}
reboot_text() {
    case "$SEC_REBOOT" in
        now)    echo "right after the run, when needed" ;;
        never)  echo "never - only reported" ;;
        *)      echo "at ${REBOOT_TIME}, when needed" ;;
    esac
}
mail_text() {
    [[ -n "$MAIL_TO" ]] || { echo "no mail"; return; }
    local w=""
    (( MAIL_ON_INSTALL == 1 )) && w+="installation, "
    (( MAIL_ON_ERROR   == 1 )) && w+="errors and rollbacks, "
    (( MAIL_ON_NOOP    == 1 )) && w+="every run, "
    w=${w%, }
    echo "${MAIL_TO} (on: ${w:-never}; other updates waiting > ${OTHER_WAIT_DAYS} days)"
}
status_line() {
    echo "auto-update: safe updates: $(safe_text); other updates: $(other_text); reboot: $(reboot_text)${EXCLUDE_PKGS:+; excluded: ${EXCLUDE_PKGS}}"
}

# ---------------------------------------------------------------------------
# Cron
# ---------------------------------------------------------------------------
write_cron() {
    local rh=$((10#${REBOOT_TIME%%:*})) rm=$((10#${REBOOT_TIME##*:})) iv=${SEC_INTERVAL_MIN:-60}
    local sm=$((10#${SEC_TIME##*:}))     # the minute of the hourly run (SEC_TIME, default :30)
    {
        echo "# auto-update - automatic apt updates (written by ${SELF})"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if [[ "$SEC_SCHEDULE" == interval ]]; then
            # -n: if the previous run is still busy, this one is skipped
            echo "# safe updates, quick ones: every ${iv} min"
            if (( iv >= 60 )); then echo -n "${sm}"; else echo -n "*/${iv}"; fi
            echo " * * * * root flock -n ${LOCK_FILE} ${SELF} --run security >/dev/null 2>&1"
        fi
        # The night window: noticeable safe updates, other updates when due,
        # then the reboot when one is needed. -w: an hourly run that happens
        # to be busy gets 30 minutes to finish.
        echo "# night window ${REBOOT_TIME}: safe updates ($(safe_text)), other updates ($(other_text)), reboot ($(reboot_text))"
        echo "${rm} ${rh} * * * root flock -w 1800 ${LOCK_FILE} ${SELF} --run night >/dev/null 2>&1"
        echo "# after a boot: containers that ran before a reboot by this tool, reboot marker"
        echo "@reboot root ${SELF} --at-boot >/dev/null 2>&1"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------
# ask_time VAR "Prompt" <current HH:MM> [DEFAULT_NAME]  -> VAR=HH:MM
ask_time() {
    local __tv=$1 T=$3 __tp=${4:-}
    ask T "$2 (HH:MM)" "$3" "" "$__tp"
    while [[ ! "$T" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        if [[ -n "${BATCH:-}" ]] || preset "$__tp"; then batch_bad "$2" "$T" "a time HH:MM" "$__tp"; return 1; fi
        read -rp "  -> format HH:MM: " T
    done
    printf -v "$__tv" '%02d:%02d' "$((10#${T%%:*}))" "$((10#${T##*:}))"
}

# choose VAR "<value list for batch check>" DEFAULT_NAME DEFAULT_CHOICE "1=val" "2=val" ...
# The menu text is printed by the caller; this reads the number (or takes the
# preset / batch value) and sets VAR to the value of that number.
choose() {
    local __cv=$1 __allowed=$2 __pre=$3 __def=$4 __c __e
    shift 4
    if [[ -n "${BATCH:-}" ]] || preset "$__pre"; then
        [[ "${!__cv}" =~ ^(${__allowed})$ ]] || { batch_bad "$__cv" "${!__cv}" "${__allowed//|/, }" "$__pre"; return 1; }
        echo "Choice: ${!__cv}$(preset_tag "$__pre")"
        return 0
    fi
    read -rp "Choice [${__def}]: " __c
    __c=${__c:-$__def}
    for __e in "$@"; do
        [[ "${__e%%=*}" == "$__c" ]] && { printf -v "$__cv" '%s' "${__e#*=}"; return 0; }
    done
    for __e in "$@"; do
        [[ "${__e%%=*}" == "$__def" ]] && printf -v "$__cv" '%s' "${__e#*=}"
    done
    return 0
}

edit_safe() {
    local present def=1
    present=$(tp_present | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    echo
    echo "--- Safe updates ---"
    if [[ -n "$present" ]]; then
        echo "Fixes that change nothing in behaviour: the security updates of the"
        echo "distribution, and of ${present} the versions their projects keep"
        echo "compatible (checked afterwards, rolled back when the check fails)."
    else
        echo "Fixes that change nothing in behaviour: the security updates of the"
        echo "distribution."
    fi
    echo "  1) hourly    quick ones every hour; Docker and Tailscale, which restart"
    echo "               containers or cut the tailnet, in the night window  (recommended)"
    echo "  2) nightly   all in the night window"
    echo "  3) off"
    case "$SEC_SCHEDULE" in daily|weekly) def=2 ;; off) def=3 ;; esac
    choose SEC_SCHEDULE 'interval|daily|weekly|off' DEFAULT_SEC_SCHEDULE "$def" 1=interval 2=daily 3=off || return 1
    [[ "$SEC_INTERVAL_MIN" =~ ^(10|15|20|30|60)$ ]] || SEC_INTERVAL_MIN=60
    return 0
}

edit_other() {
    local def=1
    echo
    echo "--- Other updates ---"
    echo "New versions that can change behaviour: Debian point releases, the next"
    echo "major version of Docker, ... The overview and a mail say when some are"
    echo "waiting longer than ${OTHER_WAIT_DAYS} days."
    echo "  1) by hand                                                  (recommended)"
    echo "  2) weekly    ${DAYS[$FULL_WEEKDAY]}, in the night window"
    echo "  3) daily     in the night window"
    case "$FULL_SCHEDULE" in weekly) def=2 ;; daily) def=3 ;; esac
    choose FULL_SCHEDULE 'off|weekly|daily' DEFAULT_FULL_SCHEDULE "$def" 1=off 2=weekly 3=daily || return 1
    if preset DEFAULT_FULL_WEEKDAY && [[ ! "$FULL_WEEKDAY" =~ ^[0-6]$ ]]; then
        batch_bad "Weekday" "$FULL_WEEKDAY" "0-6 (0=Sunday)" DEFAULT_FULL_WEEKDAY; return 1
    fi
    return 0
}

edit_reboot() {
    local def=1
    echo
    echo "--- Reboot ---"
    echo "When an update needs a reboot (new kernel):"
    echo "  1) at night  in the night window, after the updates          (recommended)"
    echo "  2) never     only reported (mail) - stays on the old kernel until someone acts"
    [[ "$SEC_REBOOT" == never ]] && def=2
    choose SEC_REBOOT 'window|never|now' DEFAULT_SEC_REBOOT "$def" 1=window 2=never || return 1
    preset DEFAULT_FULL_REBOOT || FULL_REBOOT=$SEC_REBOOT
    return 0
}

edit_window() {
    echo
    echo "--- Night window ---"
    echo "Noticeable safe updates, other updates (when scheduled) and a needed"
    echo "reboot happen at this time."
    ask_time REBOOT_TIME "Night window" "$REBOOT_TIME" DEFAULT_REBOOT_TIME || return 1
}

# The four questions.
edit_policy() {
    edit_safe || return 1
    edit_other || return 1
    edit_reboot || return 1
    edit_window || return 1
}

edit_mail_to() {
    echo
    local R=$MAIL_TO
    ask R "Mail recipient(s) for errors, rollbacks, waiting updates ('-' = none)" "$MAIL_TO" "" DEFAULT_MAIL_TO
    [[ "$R" == "-" ]] && R=""
    MAIL_TO=$R
    if [[ -n "$MAIL_TO" ]] && ! command -v mail &>/dev/null; then
        echo "Note: 'mail' is not installed - reports only go to the log until a"
        echo "mailer is set up (mail-setup.sh)."
    fi
}

edit_mail() {
    echo
    echo "--- Mail report ---"
    edit_mail_to
    [[ -n "$MAIL_TO" ]] || return 0
    confirm "Mail when an error occurred (or a rollback)?" "$(yn "$MAIL_ON_ERROR")" DEFAULT_MAIL_ON_ERROR \
        && MAIL_ON_ERROR=1 || MAIL_ON_ERROR=0
    confirm "Mail when packages were installed?" "$(yn "$MAIL_ON_INSTALL")" DEFAULT_MAIL_ON_INSTALL \
        && MAIL_ON_INSTALL=1 || MAIL_ON_INSTALL=0
    confirm "Mail even when there was nothing to do?" "$(yn "$MAIL_ON_NOOP")" DEFAULT_MAIL_ON_NOOP \
        && MAIL_ON_NOOP=1 || MAIL_ON_NOOP=0
}

edit_advanced() {
    echo
    echo "--- Exclusions ---"
    echo "Packages that are never updated automatically (shell patterns allowed,"
    echo "e.g. 'docker*'). An excluded package gets no security updates either."
    local EX=""; ask EX "Excluded packages ('-' = none)" "$EXCLUDE_PKGS" "" DEFAULT_EXCLUDE_PKGS
    [[ "$EX" == "-" ]] && EXCLUDE_PKGS="" || { [[ -n "$EX" ]] && EXCLUDE_PKGS="$EX"; }
    echo
    confirm "Remove packages that are no longer needed (apt autoremove)?" "$(yn "$AUTOREMOVE")" \
        DEFAULT_AUTOREMOVE && AUTOREMOVE=1 || AUTOREMOVE=0
    echo
    confirm "Restart affected services after an update (needrestart)?" "$(yn "$SEC_RESTART")" \
        DEFAULT_SEC_RESTART && SEC_RESTART=1 || SEC_RESTART=0
    FULL_RESTART=$SEC_RESTART
    echo
    echo "Containers: an update of the container engine or a reboot stops them;"
    echo "those without a restart policy stay down. This starts them again."
    confirm "Start containers again that ran before an update or reboot?" "$(yn "$RESTORE_CONTAINERS")" \
        DEFAULT_RESTORE_CONTAINERS && RESTORE_CONTAINERS=1 || RESTORE_CONTAINERS=0
    # Only worth asking where git-updater is actually set up.
    if [[ -f "$GITUP_SCRIPT" && -f "$DIR/git-updater.conf" ]]; then
        echo
        confirm "After an installation, redeploy the compose stacks (git-updater.sh --redeploy)?" \
            "$(yn "$POST_UPDATE_REDEPLOY")" DEFAULT_POST_UPDATE_REDEPLOY \
            && POST_UPDATE_REDEPLOY=1 || POST_UPDATE_REDEPLOY=0
    else
        POST_UPDATE_REDEPLOY=0
    fi
}

# Every preset is checked before the first question - also those whose
# question is skipped, since a preset is saved either way.
check_presets() {
    local k d re
    local hhmm='^([01]?[0-9]|2[0-3]):[0-5][0-9]$'
    # KEY -> "regex|what it has to be"
    local -A pat=(
        [SEC_SCHEDULE]='^(interval|daily|weekly|off)$|interval|daily|off'
        [SEC_INTERVAL_MIN]='^(10|15|20|30|60)$|one of 10 15 20 30 60'
        [FULL_SCHEDULE]='^(weekly|daily|off)$|weekly|daily|off'
        [SEC_REBOOT]='^(window|now|never)$|window|never|now'
        [FULL_REBOOT]='^(window|now|never)$|window|never|now'
        [SEC_WEEKDAY]='^[0-6]$|0-6 (0=Sunday)' [FULL_WEEKDAY]='^[0-6]$|0-6 (0=Sunday)'
        [SEC_TIME]="${hhmm}|a time HH:MM" [FULL_TIME]="${hhmm}|a time HH:MM"
        [REBOOT_TIME]="${hhmm}|a time HH:MM"
    )
    for k in SEC_RESTART FULL_RESTART MAIL_ON_ERROR MAIL_ON_INSTALL MAIL_ON_NOOP \
             AUTOREMOVE RESTORE_CONTAINERS POST_UPDATE_REDEPLOY; do
        pat[$k]='^[01]$|0 or 1'
    done
    for k in "${!pat[@]}"; do
        d="DEFAULT_${k}"; re=${pat[$k]%%\$|*}\$
        preset "$d" || continue
        [[ "${!d}" =~ $re ]] || { batch_bad "$k" "${!d}" "${pat[$k]#*\$|}" "$d"; return 1; }
    done
    for d in DEFAULT_ADVANCED DEFAULT_UPGRADE_NOW; do
        preset "$d" || continue
        yn_value "${!d}" >/dev/null || { batch_bad "$d" "${!d}" "Y or N" "$d"; return 1; }
    done
    return 0
}

# Guided setup (--setup): the four questions, the recipient when there is none.
configure() {
    echo "Automatic updates: safe updates unattended, other updates by hand or on"
    echo "a schedule, a needed reboot in the night window."
    if [[ -n "${BATCH:-}" ]]; then
        echo "Batch mode: every question takes its default (DEFAULT_* or built-in)."
    else
        echo "Enter accepts the value in brackets."
    fi
    check_presets || return 1
    if [[ -n "${BATCH:-}" ]]; then
        local k
        for k in SEC_RESTART FULL_RESTART MAIL_ON_ERROR MAIL_ON_INSTALL MAIL_ON_NOOP \
                 AUTOREMOVE RESTORE_CONTAINERS POST_UPDATE_REDEPLOY; do
            [[ "${!k}" =~ ^[01]$ ]] || { batch_bad "$k" "${!k}" "0 or 1"; return 1; }
        done
    fi
    edit_policy || return 1
    if [[ -z "$MAIL_TO" ]] || preset DEFAULT_MAIL_TO; then edit_mail_to; fi
    if preset DEFAULT_ADVANCED && [[ "$(yn_value "$DEFAULT_ADVANCED")" == Y ]]; then edit_advanced; fi
    apply_settings
    echo
    echo "Safe updates:   $(safe_text)"
    echo "Other updates:  $(other_text)"
    echo "Reboot:         $(reboot_text)"
    echo "Mail:           $(mail_text)"
    echo "Cron:           ${CRON_FILE}"
    echo ">>> Setup complete."
}

# ---------------------------------------------------------------------------
# Exclusions and holds
# ---------------------------------------------------------------------------
# Patterns are matched as shell globs, so "docker*" covers the whole family.
# The list is split with 'read -a': an unquoted $EXCLUDE_PKGS would be
# pathname-expanded first ("docker*" next to docker-setup.sh).
pkg_excluded() {
    local name=$1 p
    local -a pats=()
    read -r -a pats <<<"$EXCLUDE_PKGS"
    for p in "${pats[@]}"; do
        # shellcheck disable=SC2053
        [[ "$name" == $p ]] && return 0
    done
    return 1
}

# 'dist-upgrade' takes no package list - in "all" mode the only lever for the
# exclusions is 'apt-mark hold'. Only packages held by us are released again,
# and the release is armed as a trap first: an interrupted run must not leave
# the system pinned.
HELD_BY_US=()

apply_holds() {
    HELD_BY_US=()
    (( $# == 0 )) && return 0
    command -v apt-mark &>/dev/null || return 0
    local already p
    already=$(apt-mark showhold 2>/dev/null || true)
    for p in "$@"; do
        grep -qxF "$p" <<<"$already" && continue   # somebody else holds it - not ours
        apt-mark hold "$p" >/dev/null 2>&1 && HELD_BY_US+=("$p")
    done
    return 0
}

release_holds() {
    local p
    for p in "${HELD_BY_US[@]}"; do apt-mark unhold "$p" >/dev/null 2>&1 || true; done
    HELD_BY_US=()
    return 0
}

# ---------------------------------------------------------------------------
# Reboot detection
# ---------------------------------------------------------------------------
# Ubuntu leaves /var/run/reboot-required behind; Debian does not - there
# needrestart says whether the running kernel is outdated (KSTA 2 or 3).
reboot_required() {
    [[ -f /var/run/reboot-required ]] && return 0
    command -v needrestart &>/dev/null || return 1
    local ksta
    ksta=$(needrestart -b -k 2>/dev/null | awk -F': *' '/NEEDRESTART-KSTA/ {print $2}')
    [[ "$ksta" == 2 || "$ksta" == 3 ]]
}

boot_epoch() { date -d "$(uptime -s 2>/dev/null)" +%s 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Containers: bring back what was running
# ---------------------------------------------------------------------------
# Containers with "restart: always/unless-stopped" come back by themselves -
# those without a restart policy (the default of 'docker run' and of compose
# services without a 'restart:' line) stay down. So the running ones are noted
# before an update or reboot and the missing ones started again afterwards.
docker_up() { command -v docker &>/dev/null && systemctl is-active --quiet docker; }

running_containers() {
    if docker_up; then docker ps -q --no-trunc 2>/dev/null || true; fi
}

# restore_containers <file with ids> - report on stdout, 1 if a start failed
restore_containers() {
    local list=$1 id name n=0 bad=0
    [[ -s "$list" ]] || return 0
    command -v docker &>/dev/null || return 0
    # The engine may still be coming up (after a boot or its own update).
    for _ in $(seq 1 45); do
        docker_up && docker info &>/dev/null && break
        sleep 2
    done
    while read -r id; do
        [[ -n "$id" ]] || continue
        # running again, or gone (--rm, compose down): nothing to do
        [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == "false" ]] || continue
        name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null); name=${name#/}
        if docker start "$id" >/dev/null 2>&1; then
            echo "  started again: ${name}"; n=$((n + 1))
        else
            echo "!!! could not be started: ${name}"; bad=1
        fi
    done < "$list"
    (( n == 0 && bad == 0 )) && echo "  all containers are running"
    return $bad
}

do_reboot() {
    local why=$1
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%F %T') ${why}" >> "$LOG_FILE"
    if (( RESTORE_CONTAINERS == 1 )) && docker_up; then
        mkdir -p "$(dirname "$CONTAINER_STATE")"
        running_containers > "$CONTAINER_STATE"
    fi
    rm -f "$REBOOT_FLAG"
    shutdown -r +1 "auto-update: ${why}" >/dev/null 2>&1 || reboot
}

# Called from cron after every boot.
at_boot() {
    rm -f "$REBOOT_FLAG"        # whoever rebooted, the wish is fulfilled
    [[ -f "$CONTAINER_STATE" ]] || return 0
    # Only a list from just before this boot counts - a stale one would start
    # containers stopped on purpose since.
    if [[ -z "$(find "$CONTAINER_STATE" -mmin -120 2>/dev/null)" ]] || (( RESTORE_CONTAINERS != 1 )); then
        rm -f "$CONTAINER_STATE"; return 0
    fi
    local out rc=0 host
    out=$(restore_containers "$CONTAINER_STATE" 2>&1) || rc=1
    rm -f "$CONTAINER_STATE"
    mkdir -p "$(dirname "$LOG_FILE")"
    { echo "$(date '+%F %T') containers after the reboot:"; echo "$out"; } >> "$LOG_FILE"
    if (( rc != 0 && MAIL_ON_ERROR == 1 )) && [[ -n "$MAIL_TO" ]] && command -v mail &>/dev/null; then
        host=$(hostname -f 2>/dev/null || hostname)
        printf '%s\n' "Containers that ran before the reboot:" "$out" \
            | mail -s "[ERROR] auto-update ${host}: containers after the reboot" "$MAIL_TO" || true
    fi
    return $rc
}

# The reboot window (cron, under the same lock as the update runs): reboots
# only when a run asked for it since the last boot.
nightly_reboot() {
    [[ -f "$REBOOT_FLAG" ]] || return 0
    if (( $(stat -c %Y "$REBOOT_FLAG") < $(boot_epoch) )); then
        rm -f "$REBOOT_FLAG"; return 0        # rebooted in between
    fi
    do_reboot "reboot window ${REBOOT_TIME}: a reboot was required"
}

# ---------------------------------------------------------------------------
# Update run
# ---------------------------------------------------------------------------
upgradable_packages() {
    LC_ALL=C apt list --upgradable 2>/dev/null | awk -F/ '/^[a-z0-9]/ {print $1}'
}

# safe_when SOURCE - when a safe update of SOURCE comes
safe_when() {
    [[ "$SEC_SCHEDULE" == off ]] && { echo "safe updates are off"; return; }
    if [[ "$SEC_SCHEDULE" == interval && ( "$1" == security || "$(tp_field "$1" 4)" == quick ) ]]; then
        echo "next hourly run"
    else
        echo "night window ${REBOOT_TIME}"
    fi
}

# --pending [fresh]: what is waiting, and of which kind
show_pending() {
    if [[ -n "${1:-}" ]]; then
        echo ">>> Updating package lists..."
        apt-get update -qq >/dev/null 2>&1
        echo
    fi
    local c pkg cand kind target src tag n=0 s=0 o=0 nx=0 u
    c=$(classify_pending)
    echo "--- Pending updates ---"
    if [[ -z "$c" ]]; then
        echo "(none)"
    else
        while IFS='|' read -r pkg _ cand kind target src; do
            n=$((n + 1))
            case "$kind" in
                safe)
                    s=$((s + 1))
                    if [[ "$src" == security ]]; then tag="safe - security, $(safe_when security)"
                    else tag="safe - ${src} $(upstream_ver "$target"), $(safe_when "$src")"; fi ;;
                other)
                    o=$((o + 1)); tag="other - ${src}" ;;
                held)
                    nx=$((nx + 1)); tag="held - not installed until released (apt-mark unhold ${pkg})" ;;
                *)  nx=$((nx + 1)); tag="excluded" ;;
            esac
            printf '  %-34s %-22s %s\n' "$pkg" "$(upstream_ver "$cand")" "$tag"
        done <<<"$c"
        echo
        echo "Total: ${n} - ${s} safe, ${o} other$( (( o > 0 )) && echo " (oldest waiting $(oldest_other_days "$c") days)"), ${nx} excluded or held"
    fi
    u=$(held_now)
    [[ -n "$u" ]] && echo "Held after a failed check: ${u} - release: apt-mark unhold <package>"
    u=$(unknown_repos)
    [[ -n "$u" ]] && echo "Not covered by the safe updates (no heuristic known): packages from ${u}"
    reboot_required && { echo; echo "!!! A reboot is pending."; }
    return 0
}

# Security run: unattended-upgrades picks and installs (security sources
# only, exclusions as its blacklist, packages with a conffile prompt skipped).
# Sets pkgs and changed of the caller (run_update).
run_security() {
    local tmp=$1 restart=$2 out="" urc=0
    local -a got=()
    echo >> "$tmp"; echo "--- Security updates of the distribution ---" >> "$tmp"
    if ! ensure_uu >>"$tmp" 2>&1; then
        echo "!!! unattended-upgrades is missing - no security updates." >> "$tmp"
        return 1
    fi
    [[ -n "$EXCLUDE_PKGS" ]] && echo "Excluded: ${EXCLUDE_PKGS}" >> "$tmp"
    # apt-daily or a manual apt may hold the dpkg lock - wait a while
    for _ in $(seq 1 $((APT_LOCK_WAIT / 30))); do
        # needrestart only lists while unattended-upgrade runs: its apt hook
        # would otherwise restart unattended-upgrades.service, whose stop waits
        # for this very run to end - both wait for ever. The restarts follow
        # below, once the run is over.
        out=$(NEEDRESTART_MODE=l unattended-upgrade -v 2>&1); urc=$?
        grep -qi 'lock could not be acquired' <<<"$out" || break
        sleep 30
    done
    mapfile -t got < <(sed -n 's/^Packages that will be upgraded: //p' <<<"$out" | tr ' ' '\n' | grep .)
    if (( ${#got[@]} == 0 )); then
        echo "No pending security updates." >> "$tmp"
    else
        { echo "Security updates (${#got[@]}):"; printf '  %s\n' "${got[@]}"; echo; } >> "$tmp"
        pkgs+=("${got[@]}")
    fi
    # the interesting part of its output: errors, kept back, conffile prompts
    grep -Ei 'error|warn|kept back|conffile|not upgraded|all upgrades installed' <<<"$out" \
        | grep -v DeprecationWarning >> "$tmp" || true
    if (( urc != 0 )); then
        echo "!!! unattended-upgrade failed (exit ${urc}) - see ${UU_LOG}" >> "$tmp"
        return 1
    fi
    (( ${#got[@]} > 0 )) || return 0
    changed=1
    if (( restart == 1 )) && command -v needrestart &>/dev/null; then
        echo "--- needrestart ---" >> "$tmp"
        needrestart -r a >>"$tmp" 2>&1 \
            || { echo "!!! needrestart reported an error." >> "$tmp"; return 1; }
    fi
    check_dist_webservers "$tmp"
}

# The other updates: apt-get dist-upgrade, exclusions held for the run.
run_full() {
    local tmp=$1 restart=$2 p rc=0
    local -a all_pkgs=() skipped=() todo=()
    echo >> "$tmp"; echo "--- Other updates (dist-upgrade) ---" >> "$tmp"
    mapfile -t all_pkgs < <(upgradable_packages)
    for p in "${all_pkgs[@]}"; do
        if pkg_excluded "$p"; then skipped+=("$p"); else todo+=("$p"); fi
    done
    if (( ${#skipped[@]} > 0 )); then
        { echo "Excluded, deliberately not installed (${#skipped[@]}):"; printf '  %s\n' "${skipped[@]}"; echo; } >> "$tmp"
    fi
    if (( ${#todo[@]} == 0 )); then
        echo "No pending updates$( (( ${#skipped[@]} > 0 )) && echo " outside the exclusions")." >> "$tmp"
        return 0
    fi
    { echo "To be updated (${#todo[@]}):"; printf '  %s\n' "${todo[@]}"; echo; } >> "$tmp"
    trap 'release_holds' EXIT INT TERM
    apply_holds "${skipped[@]}"
    (( ${#HELD_BY_US[@]} > 0 )) && echo "Held for the duration of the run: ${HELD_BY_US[*]}" >> "$tmp"
    if (( restart == 1 )); then export NEEDRESTART_MODE=a; else export NEEDRESTART_MODE=l; fi
    if apt-get -y "${APT_LOCKWAIT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            dist-upgrade >>"$tmp" 2>&1; then
        changed=1; pkgs+=("${todo[@]}")
        # The apt hook usually did this already; a second pass is cheap.
        if (( restart == 1 )) && command -v needrestart &>/dev/null; then
            echo "--- needrestart ---" >> "$tmp"
            needrestart -r a >>"$tmp" 2>&1 || { echo "!!! needrestart reported an error." >> "$tmp"; rc=1; }
        fi
    else
        echo "!!! The update failed." >> "$tmp"
        rc=1
    fi
    release_holds; trap - EXIT INT TERM
    return $rc
}

# Due in tonight's run?
sec_due_tonight() {
    case "$SEC_SCHEDULE" in
        daily)  return 0 ;;
        weekly) [[ "$(date +%w)" == "$SEC_WEEKDAY" ]] ;;
        *)      return 1 ;;
    esac
}
full_due_tonight() {
    case "$FULL_SCHEDULE" in
        daily)  return 0 ;;
        weekly) [[ "$(date +%w)" == "$FULL_WEEKDAY" ]] ;;
        *)      return 1 ;;
    esac
}

# Once a week at most: a mail when other updates wait too long.
remind_other() {
    local c=$1 days n host
    days=$(oldest_other_days "$c")
    (( days > OTHER_WAIT_DAYS )) || return 0
    [[ -n "$MAIL_TO" ]] && command -v mail &>/dev/null || return 0
    [[ -f "$REMIND_FILE" && -n "$(find "$REMIND_FILE" -mtime -7 2>/dev/null)" ]] && return 0
    n=$(grep -c '|other|' <<<"$c")
    host=$(hostname -f 2>/dev/null || hostname)
    {
        echo "${n} update(s) on ${host} are not installed automatically and have been"
        echo "waiting for ${days} days: $(other_summary "$c")."
        echo
        echo "They can change behaviour (new versions), so they wait for someone to"
        echo "install them - and they carry fixes the safe updates cannot take."
        echo
        echo "  sudo ${SELF} --pending       what is waiting"
        echo "  sudo ${SELF} --upgrade-now   install, with a list first"
    } | mail -s "auto-update ${host}: ${n} other update(s) waiting for ${days} days" "$MAIL_TO" || return 0
    mkdir -p "$(dirname "$REMIND_FILE")"; touch "$REMIND_FILE"
}

# run_update <security|night|safe|all> [verbose]
#   security - hourly: security updates + quick safe third-party updates
#   night    - night window: safe updates (all of them), other updates when
#              due, then the reboot when one is needed
#   safe     - all safe updates now
#   all      - the other updates now
run_update() {
    local scope=${1:-} verbose=${2:-}
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    case "$scope" in
        security|night|safe|all) ;;
        # '--run' without a scope: cron lines of versions before 2.3
        *) [[ "$SEC_SCHEDULE" != off ]] && scope=security || scope=all ;;
    esac
    local label
    case "$scope" in
        security) label="hourly run" ;;
        night)    label="night run" ;;
        safe)     label="safe updates" ;;
        all)      label="other updates" ;;
    esac

    mkdir -p "$(dirname "$LOG_FILE")"
    # Cron files of older versions (no night run) - rewrite them.
    if [[ -f "$CRON_FILE" ]] && ! grep -q -- '--run night' "$CRON_FILE"; then
        write_cron
        [[ -f "$CONF" ]] && grep -q '^RESTART_SERVICES=' "$CONF" && save_conf
    fi

    local tmp rc=0 changed=0 host did_full=0
    local -a pkgs=()
    tmp=$(mktemp)
    host=$(hostname -f 2>/dev/null || hostname)
    {
        echo "auto-update on ${host}"
        echo "Start: $(date '+%F %T')"
        echo "Run:   ${label}"
        echo "----------------------------------------"
    } > "$tmp"

    export DEBIAN_FRONTEND=noninteractive
    # needrestart's apt hook reads this: 'a' restarts, 'l' only lists. Without
    # it, the hook would fall back to its own config (interactive on Ubuntu).
    if (( SEC_RESTART == 1 )); then export NEEDRESTART_MODE=a; else export NEEDRESTART_MODE=l; fi
    # apt-daily / unattended-upgrades may hold the dpkg lock for a while.
    APT_LOCKWAIT=(-o "DPkg::Lock::Timeout=${APT_LOCK_WAIT}")

    # Running containers (and their health) before - to start them again and
    # to check a Docker update.
    CONTAINERS_BEFORE=""; CONTAINER_HEALTH=""
    if docker_up; then
        CONTAINERS_BEFORE=$(mktemp); CONTAINER_HEALTH=$(mktemp)
        running_containers > "$CONTAINERS_BEFORE"
        if [[ -s "$CONTAINERS_BEFORE" ]]; then
            xargs -r docker inspect -f '{{.Id}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                < "$CONTAINERS_BEFORE" > "$CONTAINER_HEALTH" 2>/dev/null || true
        fi
        (( RESTORE_CONTAINERS == 1 )) || : > "$CONTAINERS_BEFORE"
    fi

    if ! apt-get "${APT_LOCKWAIT[@]}" update -qq >>"$tmp" 2>&1; then
        echo "!!! 'apt-get update' failed." >> "$tmp"
        rc=1
    fi
    CLASSIFIED=$(classify_pending)
    track_pending <<<"$CLASSIFIED"

    case "$scope" in
        security)
            run_security "$tmp" "$SEC_RESTART" || rc=1
            run_third_party "$tmp" quick || rc=1 ;;
        safe)
            run_security "$tmp" "$SEC_RESTART" || rc=1
            run_third_party "$tmp" all || rc=1 ;;
        night)
            if [[ "$SEC_SCHEDULE" != off ]]; then
                if sec_due_tonight; then run_security "$tmp" "$SEC_RESTART" || rc=1; fi
                run_third_party "$tmp" all || rc=1
            fi
            if full_due_tonight; then
                run_full "$tmp" "$FULL_RESTART" || rc=1
                did_full=1
            fi ;;
        all)
            run_full "$tmp" "$FULL_RESTART" || rc=1
            did_full=1 ;;
    esac
    (( changed == 0 )) && echo "Nothing was installed." >> "$tmp"

    if (( AUTOREMOVE == 1 && changed == 1 )); then
        echo "--- autoremove ---" >> "$tmp"
        apt-get -y "${APT_LOCKWAIT[@]}" autoremove >>"$tmp" 2>&1 || { echo "!!! autoremove failed." >> "$tmp"; rc=1; }
    fi

    # Optional, and only where git-updater is set up: 'compose up -d' after an
    # installation puts the stacks back into their intended state.
    if (( POST_UPDATE_REDEPLOY == 1 && changed == 1 && rc == 0 )); then
        echo >> "$tmp"; echo "--- Redeploy ---" >> "$tmp"
        if [[ -x "$GITUP_SCRIPT" && -f "$DIR/git-updater.conf" ]]; then
            if "$GITUP_SCRIPT" --redeploy >>"$tmp" 2>&1; then
                echo "Redeploy finished." >> "$tmp"
            else
                echo "!!! The redeploy reported an error." >> "$tmp"; rc=1
            fi
        else
            echo "(git-updater is not set up - skipped)" >> "$tmp"
        fi
    fi

    if [[ -n "$CONTAINERS_BEFORE" ]]; then
        if (( changed == 1 )) && [[ -s "$CONTAINERS_BEFORE" ]]; then
            echo >> "$tmp"; echo "--- Containers ---" >> "$tmp"
            restore_containers "$CONTAINERS_BEFORE" >> "$tmp" 2>&1 || rc=1
        fi
        rm -f "$CONTAINERS_BEFORE" "$CONTAINER_HEALTH"
    fi

    # A reboot: needed now, or asked for by an earlier run (hourly runs only
    # mark it). The night run is the window.
    local reboot_now=0 rpolicy=$SEC_REBOOT flag=0
    (( did_full == 1 )) && rpolicy=$FULL_REBOOT
    [[ -f "$REBOOT_FLAG" ]] && (( $(stat -c %Y "$REBOOT_FLAG") >= $(boot_epoch) )) && flag=1
    if reboot_required || (( flag == 1 )); then
        echo >> "$tmp"
        case "$rpolicy" in
            now)
                echo "Reboot required - the server restarts in 1 minute." >> "$tmp"
                reboot_now=1 ;;
            window)
                if [[ "$scope" == night ]]; then
                    echo "Reboot required - the server restarts now, in the night window." >> "$tmp"
                    reboot_now=1
                else
                    mkdir -p "$(dirname "$REBOOT_FLAG")"; touch "$REBOOT_FLAG"
                    echo "Reboot required - in the night window at ${REBOOT_TIME}." >> "$tmp"
                fi ;;
            *)
                echo "!!! Reboot required - please do it by hand." >> "$tmp" ;;
        esac
    fi

    echo "----------------------------------------" >> "$tmp"
    echo "End: $(date '+%F %T')   status: $( ((rc==0)) && echo ok || echo ERROR)" >> "$tmp"

    cat "$tmp" >> "$LOG_FILE"
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"

    local subject
    if (( rc != 0 )); then subject="[ERROR] auto-update ${host}: ${label}"
    elif (( changed == 1 )); then subject="auto-update ${host}: ${#pkgs[@]} package(s) updated (${label})"
    else subject="auto-update ${host}: no updates (${label})"; fi

    local do_mail=0
    (( rc != 0      && MAIL_ON_ERROR   == 1 )) && do_mail=1
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
    [[ "$scope" == night ]] && remind_other "$(classify_pending)"

    [[ -n "$verbose" ]] && cat "$tmp"
    rm -f "$tmp"
    (( reboot_now == 1 )) && do_reboot "reboot after the ${label}"
    return $rc
}

# --overview: key=value lines for base-setup.sh --check (no apt-get update)
overview() {
    is_setup || { echo "setup=0"; return 0; }
    local c n
    c=$(classify_pending)
    n=$(grep -c '|other|' <<<"$c")
    echo "setup=1"
    echo "safe=$(safe_text)"
    echo "safe_pending=$(grep -c '|safe|' <<<"$c")"
    echo "other_schedule=$(other_text)"
    echo "other_n=${n}"
    echo "other_days=$( (( n > 0 )) && oldest_other_days "$c" || echo 0)"
    echo "other_list=$(other_summary "$c")"
    echo "other_wait=${OTHER_WAIT_DAYS}"
    echo "reboot=$(reboot_text)"
    echo "held=$(held_now)"
    echo "unknown=$(unknown_repos)"
}

# Interactive full upgrade right now - for a fresh server or by hand. Works
# without a setup; services are restarted according to the 'all updates'
# setting (default: yes).
upgrade_now() {
    echo ">>> apt-get update"
    if ! apt-get update; then
        echo "!!! 'apt-get update' failed - check the sources and the network."
        return 1
    fi
    local n; n=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
    echo
    if (( n == 0 )); then
        echo "The system is up to date."
    else
        apt list --upgradable 2>/dev/null | grep '/' | sed 's/^/  /'
        echo
        echo "${n} package(s) pending. 'full-upgrade' also installs new dependencies"
        echo "(new kernel packages, for instance) and removes conflicting ones."
        echo "Running services may restart."
        confirm "Run the full upgrade now?" "$(yn_def "${DEFAULT_UPGRADE_NOW:-Y}")" DEFAULT_UPGRADE_NOW || return 2
        if (( FULL_RESTART == 1 )); then export NEEDRESTART_MODE=a; else export NEEDRESTART_MODE=l; fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get -y \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold full-upgrade; then
            echo "!!! The upgrade failed."
            return 1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get -y autoremove >/dev/null 2>&1 || true
    fi
    local held; held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    [[ -n "$held" ]] && echo "Note: packages on hold (never upgraded): ${held}"
    if reboot_required; then
        echo
        echo "!!! A reboot is required (new kernel or libc)."
        return 3
    fi
    return 0
}

show_log() {
    [[ -f "$LOG_FILE" ]] || { echo "There is no log."; return; }
    tail -n 60 "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall auto-update"
    echo
    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -f "$UU_CONF" ]]   && echo "  - unattended-upgrades settings $UU_CONF"
    [[ -f "$LOG_FILE" ]]  && echo "  - log $LOG_FILE                              [asked]"
    echo
    echo "Installed updates stay; only no new ones are applied automatically."
    echo
    confirm "Really remove?" || { echo "Cancelled."; return; }
    make_backup auto-update "$CONF" "$LOG_FILE" || return
    rm -f "$CRON_FILE" "$CONF" "$REBOOT_FLAG" "$CONTAINER_STATE" "$UU_CONF" "$PENDING_STATE" "$REMIND_FILE"
    local h; h=$(held_now)
    [[ -n "$h" ]] && echo "Still held after a failed check (release with apt-mark unhold): ${h}"
    rm -f "$HELD_FILE"
    if [[ -f "$LOG_FILE" ]] && confirm "Delete the log $LOG_FILE as well?"; then
        rm -f "$LOG_FILE"
    fi
    rmdir "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo
    echo "Removed. The server no longer gets updates from auto-update."
    uu_installed && echo "Note: unattended-upgrades is installed - its own daily timer applies again."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
run_now_menu() {
    while true; do
        echo
        echo "--- Install updates now ---"
        echo "1) Safe updates now           (security + safe third-party versions, checked)"
        echo "2) Other updates now          (dist-upgrade, unattended)"
        echo "3) Full upgrade interactively (list, ask, install)"
        echo "4) Show pending updates"
        echo "5) Back"
        local c; read -rp "Choice: " c || exit 0
        case "$c" in
            1) is_setup || apply_settings; run_update safe verbose ;;
            2) is_setup || apply_settings; run_update all verbose ;;
            3) upgrade_now ;;
            4) show_pending fresh ;;
            *) return ;;
        esac
    done
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Automatic updates (apt)"
        echo "==========================================="
        if is_setup; then
            echo "Safe updates:   $(safe_text)"
            echo "Other updates:  $(other_text)"
            echo "Reboot:         $(reboot_text)$( [[ -f "$REBOOT_FLAG" ]] && echo "  - one is scheduled")"
            echo "Mail:           $(mail_text)"
            echo "Excluded:       ${EXCLUDE_PKGS:-(nothing)}"
            local h; h=$(held_now)
            [[ -n "$h" ]] && echo "Held:           ${h} (after a failed check)"
            echo "Cron:           $([[ -f "$CRON_FILE" ]] && echo active || echo "!!! not installed")"
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Settings                   (safe, other updates, reboot, night window)"
        echo "2) Mail report"
        echo "3) Advanced                   (exclusions, autoremove, restarts, containers)"
        echo "4) Install updates now ..."
        echo "5) Show pending updates"
        echo "6) Show the log"
        echo "7) Uninstall"
        echo "q) Quit"
        local CH; read -rp "Choice: " CH || exit 0
        case "$CH" in
            1) edit_policy;   apply_settings; pause ;;
            2) edit_mail;     apply_settings; pause ;;
            3) edit_advanced; apply_settings; pause ;;
            4) run_now_menu ;;
            5) show_pending fresh; pause ;;
            6) show_log; pause ;;
            7) uninstall; pause ;;
            q|Q) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --run)            run_update "${2:-}" "${3:-}" ;;
    --nightly-reboot) nightly_reboot ;;
    --at-boot|--restore-containers) at_boot ;;
    --upgrade-now)    upgrade_now ;;
    --setup)          configure ;;
    --pending)        show_pending fresh ;;
    --overview)       overview ;;
    --status)         is_setup && status_line ;;
    --uninstall)      uninstall ;;
    "")               main_menu ;;
    *)                echo "Usage: $0 [--setup|--run security|night|safe|all|--upgrade-now|--pending|--overview|--status|--at-boot|--uninstall|--version]"; exit 1 ;;
esac
