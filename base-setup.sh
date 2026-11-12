#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# base-setup.sh - a security and operations baseline for every server, in
#                 five blocks and three layers (each uses the one before)
#
#   settings    1. Settings    - OS check, system update, hostname, time sync
#                                and timezone, locale, kernel hardening, swap,
#                                shell comfort
#   components  2. Components  - small tools, firewall (ufw or nftables), mailer,
#                                fail2ban (when SSH is public), tailnet
#                                (Tailscale/Headscale), Docker
#   functions   3. SSH access  - tailnet only, or public with admin user and key
#               4. Updates     - security updates hourly (unattended-upgrades),
#                                others by hand or weekly, reboot window
#               5. Monitoring  - free space, node exporter, Falco, security check
#
# Every item is required, recommended or optional; --check shows the state
# (read from the system) and lists the required items still missing.
#
# Every step asks interactively - unless the configuration file given with
# --conf sets the value (format and keys: base-setup.conf.example). Only that
# file is read: no file next to the script, no values from the environment
# (secrets aside). A value that is set is taken without a question; with every
# value set, the run asks nothing but the one question that always stays:
# before the SSH access changes, whether the new login works.
#
# This script does no system work of its own: every step calls the matching
# tool next to it (ufw-manager.sh, ssh-setup.sh, auto-update.sh, ...) and hands
# the configured values over as presets (DEFAULT_* variables - a preset is not
# asked). Every tool also works on its own, interactively.
#
# Usage: base-setup.sh [options] [KEY=VALUE ...] [mode]
#   modes:   (none)              menu
#            --all               all five blocks in a row
#            --block settings|components|ssh|updates|monitoring
#            --check             baseline status only, changes nothing; each
#                                item with a note on the right what it is for
#                                (--check --brief: without the notes)
#            --texts             the example texts with current values
#            --show-config       the effective configuration, changes nothing
#   options: --conf FILE         another configuration file (default:
#                                none - without it everything is asked)
#            --yes               ask nothing: values not configured take their
#                                default (the SSH login test is still asked)
#            KEY=VALUE           a setting for this run, written back to the
#                                --conf file if there is one (not for secrets -
#                                those go in the file or the environment)
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
CONF=""          # only what --conf names
CONF_EXAMPLE="$DIR/base-setup.conf.example"
REPORT_DIR="$DIR/var/base-setup"

BASE_SCRIPT="$DIR/base-tools.sh"
HOST_SCRIPT="$DIR/hostname-setup.sh"
SSH_SCRIPT="$DIR/ssh-setup.sh"
UFW_SCRIPT="$DIR/ufw-manager.sh"
UPDATE_SCRIPT="$DIR/auto-update.sh"
MAIL_SCRIPT="$DIR/mail-setup.sh"
DISK_SCRIPT="$DIR/disk-monitor.sh"
NODEEXP_SCRIPT="$DIR/node-exporter-setup.sh"
DOCKER_SCRIPT="$DIR/docker-setup.sh"
ANOMALY_SCRIPT="$DIR/anomaly-monitor.sh"
ROOTPW_SCRIPT="$DIR/root-password.sh"
SECCHECK_SCRIPT="$DIR/security-check.sh"
IMGCHECK_SCRIPT="$DIR/image-check.sh"
TS_SCRIPT="$DIR/tailscale-setup.sh"

die() { echo "!!! $*" >&2; exit 1; }

# ===========================================================================
# Configuration
# ===========================================================================
# KEY|TYPE|DEFAULT - TYPE: text, bool (yes/no), secret, or a list "a,b,c" of
# allowed values. The order is the order of the display.
CONF_SPEC=(
    "NOTIFY_TO|text|" "PURPOSE|text|" "OWNER|text|" "WINDOW|text|" "PUBLIC_IP|text|"
    "SYSTEM_UPGRADE|bool|yes" "SHELL_SETUP|bool|yes" "BASE_TOOLS|bool|yes" "DOCKER|bool|no"
    "HOSTNAME|text|" "HOST_DOMAIN|text|"
    "TIMEZONE|text|Europe/Berlin" "NTP_SERVERS|text|"
    "SYS_LANG|text|C.UTF-8" "SYS_LOCALES|text|de_DE.UTF-8 en_US.UTF-8"
    "KERNEL_HARDENING|bool|yes" "SWAP|text|auto"
    "TAILNET|bool|" "FIREWALL|yes,keep|yes" "PUBLIC_PORTS|text|"
    "SSH_ACCESS|tailnet,public,keep|public" "SSH_PORT|text|auto"
    "SSH_ROOT_LOGIN|auto,no,key,password|auto" "SSH_PASSWORD_LOGIN|auto,no,yes|auto"
    "ADMIN_USER|text|" "ADMIN_PASSWORD|secret|" "ADMIN_KEY|text|"
    "ADMIN_KEY_2|text|" "ADMIN_KEY_3|text|" "ADMIN_KEY_4|text|" "ADMIN_KEY_5|text|"
    "ADMIN_KEY_6|text|" "ADMIN_KEY_7|text|" "ADMIN_KEY_8|text|" "ADMIN_KEY_9|text|"
    "FAIL2BAN|bool|yes" "HEADSCALE_URL|text|" "TS_AUTHKEY|secret|" "ROOT_PASSWORD|secret|"
    "MAILER|graph,smtp,keep,none|smtp" "MAIL_FROM|text|" "MAIL_FROM_NAME|text|"
    "GRAPH_TENANT_ID|text|" "GRAPH_CLIENT_ID|text|" "GRAPH_CLIENT_SECRET|secret|"
    "GRAPH_SECRET_EXPIRY|text|"
    "SMTP_HOST|text|" "SMTP_PORT|text|" "SMTP_USER|text|" "SMTP_PASSWORD|secret|"
    "SEC_UPDATES|hourly,daily,off|hourly" "FULL_UPDATES|off,weekly,daily|off"
    "FULL_DAY|mon,tue,wed,thu,fri,sat,sun|sun" "FULL_TIME|text|02:00"
    "REBOOT|window,never,now|window" "REBOOT_TIME|text|03:00" "EXCLUDE_PKGS|text|"
    "DISK_MONITOR|bool|yes" "NODE_EXPORTER|auto,yes,no|auto" "FALCO|bool|yes"
    "SECURITY_CHECK|bool|yes" "IMAGE_CHECK|bool|yes"
)
# Names of earlier versions (profiles, the DEFAULT_* presets, old conf files).
declare -A CONF_ALIAS=(
    [APP_PORTS]=PUBLIC_PORTS [DEFAULT_SSH_ACCESS]=SSH_ACCESS [DEFAULT_MAILER]=MAILER
    [DEFAULT_FAIL2BAN]=FAIL2BAN [DEFAULT_SYSCTL]=KERNEL_HARDENING
    [DEFAULT_ROOTLOGIN_CHOICE]=SSH_ROOT_LOGIN [DEFAULT_PASSWORD_OFF]=SSH_PASSWORD_LOGIN
    [DEFAULT_OPEN_WEB]=PUBLIC_PORTS
)

declare -A C=() C_TYPE=() C_DEF=() C_SRC=() C_FILE=()
CONF_KEYS=()
for _s in "${CONF_SPEC[@]}"; do
    IFS='|' read -r _k _t _d <<<"$_s"
    CONF_KEYS+=("$_k"); C_TYPE[$_k]=$_t; C_DEF[$_k]=$_d
done
unset _s _k _t _d

is_secret() { [[ "${C_TYPE[$1]}" == secret ]]; }
known_key() { [[ -n "${C_TYPE[$1]+x}" ]]; }

# An old name -> the current key and value; prints "KEY|VALUE".
translate_alias() {
    local k=$1 v=$2 n=${CONF_ALIAS[$1]}
    case "$k" in
        DEFAULT_ROOTLOGIN_CHOICE)
            case "$v" in 1) v=key ;; 2) v=no ;; 3) v=password ;; *) v=auto ;; esac ;;
        DEFAULT_PASSWORD_OFF)
            [[ "$v" =~ ^[YyJj] ]] && v=no || v=yes ;;
        DEFAULT_OPEN_WEB)
            [[ "$v" =~ ^[YyJj] ]] && v="80/tcp 443/tcp" || v="" ;;
        DEFAULT_SYSCTL|DEFAULT_FAIL2BAN)
            [[ "$v" =~ ^[YyJj] ]] && v=yes || v=no ;;
    esac
    echo "${n}|${v}"
}

# The value part of a line: "..." or '...' or bare (an inline comment after a
# blank is dropped). Nothing is expanded. Prints the value, 1 on a broken one.
parse_value() {
    local v=$1
    if [[ "$v" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$v" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    [[ "$v" == \"* || "$v" == \'* ]] && return 1          # opening quote without its pair
    v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v")
    [[ "$v" == *\"* || "$v" == *\'* ]] && return 1        # quotes inside a bare value
    echo "$v"
}

# Normalise and check a value for KEY. Prints the value, 1 with a message.
check_value() {
    local k=$1 v=$2 t=${C_TYPE[$1]} p
    [[ -z "$v" ]] && { echo ""; return 0; }
    # "-" = explicitly none (the question is not asked)
    if [[ "$v" == - ]]; then
        case "$k" in
            PUBLIC_PORTS|EXCLUDE_PKGS|SYS_LOCALES|HOST_DOMAIN) echo -; return 0 ;;
        esac
    fi
    case "$t" in
        bool)
            case "${v,,}" in
                yes|y|true|1|ja|j|on)  echo yes ;;
                no|n|false|0|nein|off) echo no ;;
                *) echo "yes or no expected" >&2; return 1 ;;
            esac; return 0 ;;
        text|secret) ;;
        *)  [[ ",${t}," == *",${v,,},"* ]] || { echo "one of: ${t//,/ }" >&2; return 1; }
            echo "${v,,}"; return 0 ;;
    esac
    case "$k" in
        HOSTNAME)    [[ "$v" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
                         || { echo "letters, digits and -, no domain (that is HOST_DOMAIN)" >&2; return 1; } ;;
        SWAP)        [[ "$v" =~ ^(auto|no|[0-9]+)$ ]] || { echo "auto, no or a size in MB" >&2; return 1; } ;;
        SSH_PORT)    [[ "$v" =~ ^(auto|keep)$ ]] || { [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )); } \
                         || { echo "auto, keep or a port 1-65535" >&2; return 1; } ;;
        FULL_TIME|REBOOT_TIME)
                     [[ "$v" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "HH:MM expected" >&2; return 1; } ;;
        PUBLIC_PORTS)
            for p in $v; do
                [[ "$p" =~ ^[0-9]+(:[0-9]+)?/(tcp|udp)$ ]] || { echo "'$p': port/tcp or port/udp expected" >&2; return 1; }
            done ;;
        ADMIN_KEY*)  [[ "$v" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/=]+ ]] \
                         || { echo "a public key line (ssh-ed25519 AAAA... comment) expected" >&2; return 1; } ;;
        ADMIN_USER)  [[ "$v" =~ ^[a-z_][a-z0-9_.-]{0,31}$ && "$v" != root ]] \
                         || { echo "a user name (lowercase, not root) expected" >&2; return 1; } ;;
        GRAPH_SECRET_EXPIRY)
                     [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "YYYY-MM-DD expected" >&2; return 1; } ;;
    esac
    echo "$v"
}

# Read a configuration file into C_FILE. Strict: a broken line or an unknown
# key stops with the line number. Files of earlier versions (written by the
# script, sourced by bash) are recognised by their first line and unescaped.
read_conf() {
    local f=$1 line n=0 key raw val legacy=0 msg
    head -1 "$f" 2>/dev/null | grep -qE '^# (mbits-)?base-setup configuration - answers of the last run' && legacy=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "${f}:${n}: KEY=VALUE expected: ${line}"
        key=${BASH_REMATCH[1]}; raw=${BASH_REMATCH[2]}
        if (( legacy == 1 )) && [[ "$raw" != \"* && "$raw" != \'* ]]; then
            val=$(sed -E 's/\\(.)/\1/g' <<<"$raw")          # printf %q of older base-setup versions
        else
            val=$(parse_value "$raw") || die "${f}:${n}: unbalanced or misplaced quotes: ${line}"
        fi
        if ! known_key "$key"; then
            [[ -n "${CONF_ALIAS[$key]+x}" ]] || die "${f}:${n}: unknown key ${key}"
            IFS='|' read -r key val <<<"$(translate_alias "$key" "$val")"
        fi
        val=$(check_value "$key" "$val" 2>&1) || die "${f}:${n}: ${key}: ${val}"
        C_FILE[$key]=$val
    done < "$f"
    CONF_LEGACY=$legacy
}
CONF_LEGACY=0

# A file with a secret in it must be root's and closed to everyone else.
check_conf_perms() {
    local f=$1 k has=0 owner mode
    for k in "${CONF_KEYS[@]}"; do
        is_secret "$k" && [[ -n "${C_FILE[$k]:-}" ]] && has=1
    done
    (( has == 1 )) || return 0
    read -r owner mode < <(stat -c '%u %a' "$f")
    if [[ "$owner" != 0 ]] || (( (8#$mode & 8#077) != 0 )); then
        echo "!!! ${f} holds secrets but is owner uid ${owner}, mode ${mode}." >&2
        echo "!!! Fix it first:  chown root:root '${f}' && chmod 600 '${f}'" >&2
        exit 1
    fi
}

# Quote a value for the file. Fails when it holds both kinds of quotes.
quote_value() {
    local v=$1
    if [[ ! "$v" =~ [[:space:]#\"\'] ]]; then echo "$v"
    elif [[ "$v" != *\"* ]]; then echo "\"$v\""
    elif [[ "$v" != *\'* ]]; then echo "'$v'"
    else return 1; fi
}

# Write KEY=VALUE into the file: the existing line is replaced (an inline
# comment is kept), a commented-out "#KEY=" line is taken, or it is appended.
# A missing file starts as a copy of the example. Never for secrets.
conf_write() {
    local k=$1 v=$2 q tmp done=0 line rest old
    is_secret "$k" && return 0
    [[ -n "$CONF" ]] || return 0     # no --conf: nothing is written anywhere
    q=$(quote_value "$v") || { echo "!!! ${k}: value with both kinds of quotes is not written" >&2; return 1; }
    if [[ ! -f "$CONF" ]]; then
        ( umask 077; if [[ -f "$CONF_EXAMPLE" ]]; then cp "$CONF_EXAMPLE" "$CONF"; else : > "$CONF"; fi )
    fi
    tmp=$(mktemp "${CONF}.XXXX")
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( done == 0 )) && [[ "$line" =~ ^${k}=(.*)$ ]]; then
            old=${BASH_REMATCH[1]}; rest=""
            if [[ "$old" =~ ^(\"[^\"]*\"|\'[^\']*\')([[:space:]]+#.*)$ ]]; then
                rest=${BASH_REMATCH[2]}
            elif [[ "$old" != \"* && "$old" != \'* && "$old" =~ ([[:space:]]+#.*)$ ]]; then
                rest=${BASH_REMATCH[1]}
            fi
            line="${k}=${q}${rest}"; done=1
        fi
        printf '%s\n' "$line"
    done < "$CONF" > "$tmp"
    (( done == 1 )) || printf '%s=%s\n' "$k" "$q" >> "$tmp"
    chmod 600 "$tmp"; chown root:root "$tmp" 2>/dev/null || true
    mv "$tmp" "$CONF"
}

# Defaults < file (--conf) < arguments. From the environment only the secrets
# (TS_AUTHKEY, ADMIN_PASSWORD, ...) - a forgotten export of an ordinary key
# would preset an answer nobody sees coming.
declare -A C_ARG=()
resolve_conf() {
    local k v
    for k in "${CONF_KEYS[@]}"; do
        C[$k]=${C_DEF[$k]}; C_SRC[$k]="default"
        if [[ -n "${C_FILE[$k]+x}" ]]; then C[$k]=${C_FILE[$k]}; C_SRC[$k]="file"; fi
        if is_secret "$k" && v=$(printenv "$k") && [[ -n "$v" ]]; then
            v=$(check_value "$k" "$v" 2>&1) || die "environment ${k}: ${v}"
            C[$k]=$v; C_SRC[$k]=environment
        fi
        if [[ -n "${C_ARG[$k]+x}" ]]; then C[$k]=${C_ARG[$k]}; C_SRC[$k]=argument; fi
    done
}

# --- Command line -------------------------------------------------------------
MODE=""; MODE_ARG=""; ASSUME_YES=0; AUDIT_INFO=1
while (( $# > 0 )); do
    case "$1" in
        --conf)      CONF=${2:?--conf needs a file}; shift 2 ;;
        --conf=*)    CONF=${1#--conf=}; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --brief)     AUDIT_INFO=0; shift ;;
        --block)     MODE=--block; MODE_ARG=${2:-}; shift; (( $# > 0 )) && shift ;;
        --all|--check|--texts|--show-config) MODE=$1; shift ;;
        [A-Z]*=*)
            _k=${1%%=*}; _v=${1#*=}
            if ! known_key "$_k"; then
                [[ -n "${CONF_ALIAS[$_k]+x}" ]] || die "unknown key ${_k}"
                IFS='|' read -r _k _v <<<"$(translate_alias "$_k" "$_v")"
            fi
            is_secret "$_k" && die "${_k} is a secret - put it in the configuration file (chmod 600) or the environment, not on the command line"
            _v=$(check_value "$_k" "$_v" 2>&1) || die "${_k}: ${_v}"
            C_ARG[$_k]=$_v; shift ;;
        *) die "unknown argument: $1 (see the header of $0)" ;;
    esac
done
unset _k _v
# Presets for the tools come from this script only: DEFAULT_* and BATCH left
# exported in the calling shell would preset answers unseen.
for _k in $(compgen -e); do
    [[ "$_k" == DEFAULT_* || "$_k" == BATCH ]] && unset "$_k"
done
unset _k
if [[ -n "$CONF" ]]; then
    [[ "$CONF" == /* ]] || CONF="$PWD/$CONF"
    [[ -f "$CONF" ]] || die "configuration file not found: ${CONF}"
    read_conf "$CONF"
    check_conf_perms "$CONF"
fi
resolve_conf

# Files of earlier versions become the documented format once (a backup stays).
if (( CONF_LEGACY == 1 )); then
    _bak="${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$CONF" "$_bak"
    for _k in "${CONF_KEYS[@]}"; do
        [[ -n "${C_FILE[$_k]:-}" ]] && conf_write "$_k" "${C_FILE[$_k]}"
    done
    echo "Configuration converted to the current format: ${CONF} (old one: ${_bak})"
    unset _bak _k
fi

# Plain variables for the texts and steps (HOSTNAME stays in C[] - bash has its
# own variable of that name).
for _k in "${CONF_KEYS[@]}"; do
    [[ "$_k" == HOSTNAME ]] && continue
    printf -v "$_k" '%s' "${C[$_k]}"
done
unset _k

# Set a value for this run and write it to the file (not for secrets).
conf_set() {
    local k=$1 v=$2
    C[$k]=$v; C_SRC[$k]=asked
    [[ "$k" != HOSTNAME ]] && printf -v "$k" '%s' "$v"
    conf_write "$k" "$v"
}

BLOCK=""
banner() {
    echo
    echo "==========================================================="
    echo " ${BLOCK:+${BLOCK} - }$1"
    echo "==========================================================="
}

REBOOT_PENDING=0
SSH_MODE=""          # tailnet | public - derived from the state

declare -a SUMMARY=()

# confirm "Question" [Y]   -> default Y instead of N; with --yes the default
confirm() {
    local q=$1 def=${2:-N} ans
    if (( ASSUME_YES == 1 )); then
        echo "$q -> $( [[ "$def" == Y ]] && echo yes || echo no) (--yes)"
        [[ "$def" == Y ]]; return
    fi
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

pause() { read -rp "Press Enter to continue..." _; }

run() {
    local script=$1; shift
    if [[ ! -f "$script" ]]; then
        echo "!!! Script not found: $script"
        return 1
    fi
    [[ -x "$script" ]] || chmod +x "$script"
    "$script" "$@"
}

note() { SUMMARY+=("$1|$2|${3:-}"); }

ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}')
    echo "${p:-22}"
}

tailnet_ip() { command -v tailscale &>/dev/null && tailscale ip -4 2>/dev/null | head -1; }

ufw_active() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }

# Publicly open ports according to ufw (rules not bound to an interface such
# as tailscale0), as "tcp-list udp-list" for port-scan-monitor.sh --add.
public_ports() {
    local tcp="" udp="" spec p proto
    ufw_active || { echo "- -"; return 0; }
    while read -r spec; do
        case "$spec" in
            OpenSSH)  tcp+=",22"; continue ;;
            *"/tcp")  p=${spec%/tcp}; proto=tcp ;;
            *"/udp")  p=${spec%/udp}; proto=udp ;;
            *)        p=$spec; proto=both ;;
        esac
        [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]] || continue
        case "$proto" in
            tcp)  tcp+=",$p" ;;
            udp)  udp+=",$p" ;;
            both) tcp+=",$p"; udp+=",$p" ;;
        esac
    done < <(ufw status 2>/dev/null | awk 'NR>4 && $1 !~ /\(v6\)/ && $2 !~ /^on$/ && $2 ~ /^(ALLOW|LIMIT)$/ && $3 == "Anywhere" {print $1}')
    tcp=${tcp#,}; udp=${udp#,}
    echo "${tcp:--} ${udp:--}"
}

# The command that registers this server at the external port scanner.
scan_register_cmd() {
    local t u; read -r t u < <(public_ports)
    echo "sudo <dir>/port-scan-monitor.sh --add $(hostname -s) ${PUBLIC_IP:-<public-ip>} ${t} ${u}"
}

# Everything that listens on something other than loopback.
show_listeners() {
    # Everything that listens on something other than loopback.
    ss -H -tulpn 2>/dev/null | awk '{
        split($5, a, ":"); port = a[length(a)]; addr = substr($5, 1, length($5) - length(port) - 1)
        if (addr ~ /^(127\.|\[::1\]|::1)/) next
        proc = $7; sub(/^users:\(\("/, "", proc); sub(/".*/, "", proc)
        printf "  %-4s %-28s %s\n", $1, $5, proc
    }' | sort -u
}

mailer_ready() { command -v mail &>/dev/null || [[ -x /usr/sbin/sendmail ]]; }

sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'; }

os_info() {   # prints "id|version|pretty" - in a subshell, os-release sets VERSION
    ( # shellcheck disable=SC1091
      . /etc/os-release 2>/dev/null; echo "${ID:-}|${VERSION_ID:-}|${PRETTY_NAME:-unknown}" )
}

st_os() {
    local id ver _p
    IFS='|' read -r id ver _p < <(os_info)
    case "$id" in
        debian) dpkg --compare-versions "${ver:-0}" ge 12 ;;
        ubuntu) dpkg --compare-versions "${ver:-0}" ge 24.04 ;;
        *)      return 1 ;;
    esac
}

upgradable_count() { apt list --upgradable 2>/dev/null | grep -c '/' || true; }

# ---------------------------------------------------------------------------
# State of the system - read from the system itself, not from what our tools
# wrote: a server set up by hand or by other tools is judged the same way.
# ---------------------------------------------------------------------------
in_container() { [[ ! "$(systemd-detect-virt --container 2>/dev/null || true)" =~ ^(none)?$ ]]; }

# --- Base tools ---------------------------------------------------------------
# Our shell setup (prompt, history, aliases) - what base-tools adds on top.
st_basetools() { [[ -f /etc/profile.d/zz-base-tools.sh ]]; }
# The everyday tools, whoever installed them.
basetools_text() {
    local c x ok n=0 t=0
    local -a miss=()
    for c in "vim|nano" "screen|tmux" htop curl rsync ncdu; do
        t=$((t + 1)); ok=0
        for x in ${c//|/ }; do command -v "$x" &>/dev/null && ok=1; done
        if (( ok == 1 )); then n=$((n + 1)); else miss+=("${c%%|*}"); fi
    done
    echo "${n}/${t} tools$( (( ${#miss[@]} > 0 )) && echo " (missing: ${miss[*]})"), shell setup: $(st_basetools && echo base-tools || echo none)"
}

# --- Time, locale ---------------------------------------------------------------
st_time() {
    local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ "$tz" == "$TIMEZONE" ]] || return 1
    in_container && return 0          # a container gets its clock from the host
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]
}
time_synced() { in_container || [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; }
time_text() {
    local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "?")
    echo "$(time_synced && echo synchronised || echo "NOT synchronised"), timezone ${tz}$( [[ "$tz" == "$TIMEZONE" ]] || echo " (wanted: ${TIMEZONE})")"
}
sys_lang() { sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' || true; }
missing_locales() {
    local l
    for l in $SYS_LOCALES; do
        [[ "$l" == - ]] && continue
        locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}" || echo "$l"
    done
}
# exactly what is wanted (the step sets it)
locale_norm() { local l=${1,,}; echo "${l/utf-8/utf8}"; }
st_locale() { [[ "$(locale_norm "$(sys_lang)")" == "$(locale_norm "$SYS_LANG")" && -z "$(missing_locales)" ]]; }
locale_utf8() { [[ "$(sys_lang)" =~ [Uu][Tt][Ff]-?8$ ]]; }

# --- Kernel hardening: the effective values, wherever they were set -----------
# key|accepted values (regex)
SYSCTL_CHECKS=(
    "kernel.kptr_restrict|[12]" "kernel.dmesg_restrict|1" "fs.suid_dumpable|0"
    "fs.protected_fifos|[12]" "fs.protected_regular|[12]"
    "net.ipv4.conf.all.accept_redirects|0" "net.ipv6.conf.all.accept_redirects|0"
    "net.ipv4.conf.all.send_redirects|0" "net.ipv4.conf.all.accept_source_route|0"
    "net.ipv4.tcp_syncookies|1" "net.ipv4.conf.all.rp_filter|[12]"
)
sysctl_score() {   # prints "matching total"
    local c k re v n=0
    for c in "${SYSCTL_CHECKS[@]}"; do
        k=${c%%|*}; re=${c#*|}
        v=$(sysctl -n "$k" 2>/dev/null || true)
        [[ "$v" =~ ^(${re})$ ]] && n=$((n + 1))
    done
    echo "$n ${#SYSCTL_CHECKS[@]}"
}
st_sysctl() { in_container && return 0; local n t; read -r n t < <(sysctl_score); (( n == t )); }

# --- Swap: active, or not needed (container, 8 GB RAM or more) ----------------
mem_mb() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo; }
st_swap() {
    in_container && return 0
    [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]] && return 0
    (( $(mem_mb) >= 8192 ))
}

# --- Hostname, tailnet ----------------------------------------------------------
st_hostname() { [[ ! "$(hostname -s)" =~ ^(ubuntu|debian|localhost|vm|vps|server|srv)[-0-9]*$|^[0-9a-f-]{12,}$ ]]; }
st_tailnet()  { [[ -n "$(tailnet_ip)" ]]; }
tailnet_control() { tailscale debug prefs 2>/dev/null | sed -n 's/.*"ControlURL": *"\([^"]*\)".*/\1/p' | head -1; }
# Tailscale SSH answers port 22 on the tailnet itself - past sshd and its rules.
tailscale_ssh_on() { command -v tailscale &>/dev/null && tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": *true'; }

# --- Docker ---------------------------------------------------------------------
# Published container ports on all addresses - they bypass ufw.
docker_public() {
    command -v docker &>/dev/null || return 0
    docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
        | awk '/0\.0\.0\.0:|\[::\]:|:::[0-9]/ {print $1}' | tr '\n' ' ' | sed 's/ $//'
}

# --- Firewall -------------------------------------------------------------------
# A firewall counts when it drops what is not allowed: ufw with default deny,
# or an nftables ruleset of its own (input chain with policy drop - not
# managed by these tools; ufw also writes nftables chains, so ufw comes first).
st_ufw() { ufw_active && ufw status verbose 2>/dev/null | grep -q "deny (incoming)"; }
st_nft() {
    ! ufw_active && ! systemctl is-active --quiet firewalld 2>/dev/null \
        && command -v nft &>/dev/null && nft list chains 2>/dev/null | grep -qE 'hook input .*policy drop'
}
st_firewall() { st_ufw || st_nft; }
firewall_kind() { if st_ufw; then echo ufw; elif st_nft; then echo nftables; fi; return 0; }
# Another packet filter that drops incoming traffic (neither ufw nor nftables
# of its own) - not judged here.
other_firewall() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then echo firewalld; return; fi
    ufw_active && return 0
    st_nft && return 0
    if command -v iptables &>/dev/null && iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then echo "iptables"; fi
    return 0
}
# The accept rules of the nftables input chains, one per line.
nft_input_accepts() {
    nft list ruleset 2>/dev/null | awk '
        /^[[:space:]]*chain /           { inch = 1; hook = 0; next }
        inch && /hook input/            { hook = 1; next }
        inch && /^[[:space:]]*}/        { inch = 0; hook = 0; next }
        hook && /accept/ && !/ct state/ { sub(/^[[:space:]]+/, ""); print }'
}
# nft_port_rule RULE PORT - does the rule name the port (dport 22, { 22, 80 }, ssh)?
nft_port_rule() {
    local r=$1 p=$2
    [[ "$r" =~ dport[[:space:]]+${p}([^0-9]|$) || "$r" =~ dport[[:space:]]+\{[^}]*[^0-9]${p}[^0-9][^}]*\} ]] && return 0
    [[ "$p" == 22 && "$r" =~ dport[[:space:]]+(ssh|\{[^}]*ssh) ]]
}
nft_iface_rule() { [[ "$1" =~ iif(name)?[[:space:]]+\"?(tailscale0|lo)\"? ]]; }
# Short list of what the nftables input chains accept: "22 on tailscale0, 80, 443".
nft_accepted() {
    local r out="" i
    while IFS= read -r r; do
        i=""; [[ "$r" =~ iif(name)?[[:space:]]+\"?([A-Za-z0-9_.-]+) ]] && i=" on ${BASH_REMATCH[2]}"
        if [[ "$r" =~ dport[[:space:]]+(\{[^}]*\}|[^[:space:]]+) ]]; then out+="$(tr -d '{} ' <<<"${BASH_REMATCH[1]}")${i}, "
        elif [[ -n "$i" ]]; then out+="all${i}, "
        fi
    done < <(nft_input_accepts)
    echo "${out%, }"
}
firewall_text() {
    local o
    if st_ufw; then
        echo "ufw, default deny, allowed: $(ufw status 2>/dev/null | awk 'NR>4 && $2 ~ /ALLOW|LIMIT/ && $1 !~ /\(v6\)/ {printf "%s ", $1 ($2=="on"?" on "$3:"")}')"
    elif st_nft; then
        echo "nftables, input policy drop, accepted: $(nft_accepted | grep . || echo nothing)"
    elif ufw_active; then
        echo "ufw active but NOT default deny"
    elif o=$(other_firewall) && [[ -n "$o" ]]; then
        echo "${o} (not ufw - managed outside these tools)"
    else
        echo "none - every listening port is reachable"
    fi
}

# --- Mail: what /usr/sbin/sendmail really is and whether mail leaves ----------
mail_state() {   # prints "name|state", state "ok", "none" or a warning
    local sm pkg t r
    if [[ -f /etc/graph-mailer.conf ]]; then echo "graph-mailer|ok"; return; fi
    if [[ -f /etc/msmtprc ]]; then echo "msmtp|ok"; return; fi
    sm=$(readlink -f /usr/sbin/sendmail 2>/dev/null || true)
    [[ -n "$sm" && -e "$sm" ]] || { echo "|none"; return; }
    pkg=$(dpkg -S "$sm" 2>/dev/null | head -1 | cut -d: -f1)
    case "$pkg" in
        exim4*)
            t=$(sed -n "s/^dc_eximconfig_configtype='\(.*\)'/\1/p" /etc/exim4/update-exim4.conf.conf 2>/dev/null)
            if [[ -z "$t" || "$t" == local ]]; then echo "exim4|local only - delivers nothing outside"
            else echo "exim4|ok"; fi ;;
        postfix)
            r=$(postconf -h relayhost 2>/dev/null || true)
            echo "postfix|ok${r:+ (relay ${r})}" ;;
        *)  echo "${pkg:-$sm}|unknown - send a test mail" ;;
    esac
}
# The mailer when mail can leave the machine, else empty.
mailer_name() { local s; s=$(mail_state); [[ "${s#*|}" == ok* ]] && echo "${s%%|*}"; return 0; }
st_mail() { [[ -n "$(mailer_name)" ]]; }

# --- SSH ------------------------------------------------------------------------
st_ssh_hardened() {
    [[ "$(sshd_val passwordauthentication)" == "no" && "$(sshd_val kbdinteractiveauthentication)" != "yes" \
       && "$(sshd_val permitrootlogin)" != "yes" ]]
}
# The firewall rules that open the SSH port to everyone (ufw or nftables).
ssh_public_rules() {
    local sp r; sp=$(ssh_port)
    if ufw_active; then
        ufw status 2>/dev/null | grep -E "^(${sp}(/tcp)?|OpenSSH)[[:space:]]" | grep -v "on tailscale0" || true
    elif st_nft; then
        while IFS= read -r r; do
            nft_port_rule "$r" "$sp" && ! nft_iface_rule "$r" && echo "$r"
        done < <(nft_input_accepts)
    fi
    return 0
}
# SSH only over the tailnet: a rule for tailscale0, none for everyone.
st_ssh_tailnet_only() {
    local sp r ok=1; sp=$(ssh_port)
    if ufw_active; then
        ufw status 2>/dev/null | grep -qE "^${sp}(/tcp)? on tailscale0" || return 1
    elif st_nft; then
        while IFS= read -r r; do
            [[ "$r" =~ iif(name)?[[:space:]]+\"?tailscale0 ]] || continue
            [[ "$r" != *dport* ]] || nft_port_rule "$r" "$sp" && ok=0
        done < <(nft_input_accepts)
        (( ok == 0 )) || return 1
    else
        return 1
    fi
    [[ -z "$(ssh_public_rules)" ]]
}
# Non-root members of sudo/admin/wheel with an authorized_keys file.
sudo_key_users() {
    local g u home
    for g in sudo admin wheel; do getent group "$g" | cut -d: -f4 | tr ',' '\n'; done | sort -u | grep . \
        | while read -r u; do
            home=$(getent passwd "$u" | cut -d: -f6)
            [[ -s "$home/.ssh/authorized_keys" ]] && echo "$u"
        done
    return 0
}
f2b_sshd() { systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status 2>/dev/null | grep -q sshd; }
# tailnet | public | "" - from what is configured, not from a remembered answer
ssh_mode_now() {
    if st_ssh_tailnet_only; then echo tailnet
    elif st_ssh_hardened && [[ -n "$(sudo_key_users)" ]]; then echo public
    fi
    return 0
}

# --- Updates --------------------------------------------------------------------
st_autoupdate() { [[ -f /etc/cron.d/auto-update ]]; }
# The daily timer of unattended-upgrades (Ubuntu default, many Debian images).
uu_active() {
    dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "ok installed" || return 1
    [[ "$(apt-config dump 2>/dev/null | awk -F'"' '$1 ~ /^APT::Periodic::Unattended-Upgrade / {print $2}')" =~ ^[1-9] ]] \
        && systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null
}
# Reboot needed: Ubuntu's marker, or (Debian) a newer kernel installed than runs.
reboot_needed() {
    [[ -f /var/run/reboot-required ]] && { echo "reboot-required"; return 0; }
    in_container && return 1
    local newest; newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$(uname -r)" ]] && { echo "running $(uname -r), installed ${newest}"; return 0; }
    return 1
}

# --- Monitoring -----------------------------------------------------------------
st_disk() { [[ -f /etc/cron.d/disk-monitor ]]; }
# Where a node exporter listens, whoever installed it.
node_exp_addr() {
    ss -Hltnp 2>/dev/null | awk '/node_exporter|prometheus-node/ {print $4; exit}'
}
st_nodeexp() {
    local a tip; a=$(node_exp_addr); tip=$(tailnet_ip)
    [[ -n "$a" && -n "$tip" && "${a%:*}" == "$tip" ]]
}
falco_active() {
    local u
    for u in falco-modern-bpf falco-bpf falco-kmod falco; do
        systemctl is-active --quiet "$u" 2>/dev/null && return 0
    done
    return 1
}
st_anomaly() { falco_active && [[ -f /etc/cron.d/anomaly-monitor ]]; }
st_seccheck() { [[ -f /etc/cron.d/security-check ]]; }
st_imagecheck() { [[ -f /etc/cron.d/image-check ]]; }
other_seccheck() {
    local f
    for f in /etc/cron.daily/rkhunter /etc/cron.weekly/rkhunter /etc/cron.d/lynis /etc/cron.daily/chkrootkit; do
        [[ -e "$f" ]] && printf '%s ' "${f##*/}"
    done
    return 0
}

last_report() { ls -1t "$REPORT_DIR/$(hostname -s)"-2*.txt "$REPORT_DIR/$(hostname -s)"-2*.md 2>/dev/null | head -1; }

# Prints "tool|olddir|file" for every reference outside $DIR.
find_foreign() {
    local f p tool d
    {
        for f in /etc/cron.d/*; do
            [[ -f "$f" ]] || continue
            grep -hoE '/[^ ]+/[a-z][a-z0-9-]*\.sh' "$f" 2>/dev/null | while read -r p; do
                echo "${p}|${f}"
            done
        done
        if [[ -f /usr/local/sbin/graph-sendmail ]]; then
            grep -hoE '/[^ ]+/graph-mailer\.sh' /usr/local/sbin/graph-sendmail 2>/dev/null \
                | sed 's#$#|/usr/local/sbin/graph-sendmail#'
        fi
        if [[ -f /etc/systemd/system/iptables-router.service ]]; then
            grep -hoE '/[^ ]+/iptables-router\.sh' /etc/systemd/system/iptables-router.service 2>/dev/null \
                | sed 's#$#|/etc/systemd/system/iptables-router.service#'
        fi
    } | while IFS='|' read -r p f; do
        tool=$(basename "$p" .sh); d=$(dirname "$p")
        [[ "$d" == "$DIR" ]] && continue
        echo "${tool}|${d}|${f}"
    done | sort -u
}

# Moves one tool over to this directory: settings copied (paths rewritten),
# references re-pointed. Nothing is reconfigured; the step for the tool then
# shows it as "already set up" with the old values.
take_over() {
    local tool=$1 old=$2; shift 2
    local f
    if [[ -f "$old/$tool.conf" && ! -f "$DIR/$tool.conf" ]]; then
        sed "s#${old}/#${DIR}/#g; s#${old}\"#${DIR}\"#g" "$old/$tool.conf" > "$DIR/$tool.conf"
        chmod --reference="$old/$tool.conf" "$DIR/$tool.conf" 2>/dev/null || chmod 600 "$DIR/$tool.conf"
        echo "    settings: $old/$tool.conf -> $DIR/$tool.conf"
    fi
    for f in "$@"; do
        sed -i "s#${old}/${tool}\.sh#${DIR}/${tool}.sh#g" "$f"
        echo "    re-pointed: $f"
    done
    if [[ " $* " == *" /etc/systemd/system/"* ]]; then systemctl daemon-reload; fi
}

# Asks, per tool, whether to take it over, uninstall it or leave it.
handle_foreign_install() {
    local list; list=$(find_foreign)
    [[ -z "$list" ]] && return 0

    echo "==========================================================="
    echo " Tools installed from another directory"
    echo "==========================================================="
    local olds old tool c def took
    local -a files
    olds=$(cut -d'|' -f2 <<<"$list" | sort -u)
    for old in $olds; do
        echo "  ${old}$([[ -d "$old/.git" ]] && echo "  (git checkout)")$([[ -d "$old" ]] || echo "  (directory MISSING - these jobs fail)")"
        grep "|${old}|" <<<"$list" | cut -d'|' -f1,3 | sed 's/|/  <- /; s/^/      /'
    done
    cat <<EOF

These run the OLD scripts. Changes made from here would not reach them, and
the old versions lack the current fixes. Per tool:
  t) take over  - settings are copied here, the job runs the new script
                  (only for tools that are part of this installation)
  u) uninstall  - the old script's own --uninstall (removes its job/config)
  l) leave      - keeps running from the old directory, which has to stay
EOF
    for old in $olds; do
        took=0
        if [[ ! -d "$old" ]]; then
            echo
            echo "!!! ${old} is gone - remove the stale entries listed above by hand."
            continue
        fi
        for tool in $(grep "|${old}|" <<<"$list" | cut -d'|' -f1 | sort -u); do
            mapfile -t files < <(grep "^${tool}|${old}|" <<<"$list" | cut -d'|' -f3)
            echo
            if [[ -f "$DIR/$tool.sh" ]]; then
                def=t
            else
                def=l
                echo "  (${tool} is not part of this installation - take over is not possible)"
            fi
            if [[ "$tool" == "graph-mailer" ]]; then
                echo "  Note: uninstalling graph-mailer deletes the client secret - mail stops."
            fi
            read -rp "  ${tool} from ${old}: [t]ake over, [u]ninstall, [l]eave? [${def}]: " c
            case "${c:-$def}" in
                t|T)
                    if [[ -f "$DIR/$tool.sh" ]]; then
                        take_over "$tool" "$old" "${files[@]}"; took=1
                    else
                        echo "    not possible - left as it is."
                    fi ;;
                u|U)
                    if [[ -f "$old/$tool.sh" ]]; then
                        bash "$old/$tool.sh" --uninstall || echo "!!! ${tool} --uninstall reported an error."
                    else
                        echo "!!! $old/$tool.sh not found - remove ${files[*]} by hand."
                    fi ;;
                *)  echo "    left as it is." ;;
            esac
        done
        # Logs and state of taken-over tools: copied once, existing files kept.
        if (( took == 1 )) && [[ -d "$old/var" ]]; then
            mkdir -p "$DIR/var"
            cp -an "$old/var/." "$DIR/var/" 2>/dev/null && echo "    data: $old/var -> $DIR/var (copied, not moved)"
        fi
        # Nothing points there any more? Then the directory can go.
        if ! find_foreign | grep -q "|${old}|"; then
            echo
            echo "Nothing refers to ${old} any more ($(du -sh "$old" 2>/dev/null | cut -f1))."
            if confirm "Delete ${old}$([[ -d "$old/.git" ]] && echo " (git checkout, incl. local changes)")?"; then
                rm -rf "$old" && echo "Deleted."
            fi
        fi
    done
    echo
    if [[ -n "$(find_foreign)" ]]; then
        echo "Still running from other directories:"
        find_foreign | sed 's/|/  /g; s/^/  /'
    fi
    pause
}


# The checklist, in the order of the blocks. Everything is read from the system.
#   mark:  [x] in place  [ ] missing  [!] needs attention  [-] not applicable
#   level: required / recommended / optional - required items still missing
#          are listed at the end as the to-do.
TODO=()
# --- What every item of the overview is, and what it is good for -------------
# Shown as the right-most column (AUDIT_INFO=1; --brief or menu key i: off).
declare -A AUDIT_DESC=(
    [OS]="release with security support - else no more fixes"
    [Time]="NTP sync - logs, certificates, one-time codes need it"
    [Locale]="UTF-8 everywhere; extra locales for what SSH clients send"
    ["Kernel hardening"]="sysctl against spoofing and leaks - less to attack"
    [Swap]="RAM overflow - slows down instead of killing processes"
    [Hostname]="a telling name - mails and prompts show the server"
    ["Shell comfort"]="coloured prompt, history, aliases - fewer slips as root"
    ["Small tools"]="editor, tmux, htop, curl ... - what you need logged in"
    [Firewall]="ufw or nftables - only ports opened on purpose are reachable"
    [Mailer]="sends alerts out - without it nobody hears of problems"
    [fail2ban]="bans IPs after failed logins - stops password guessing"
    [Tailscale]="private network - admin and monitoring, no open ports"
    [Docker]="containers - careful: published ports bypass ufw"
    [unattended-upgrades]="installs security updates - auto-update says when"
    [needrestart]="restarts services after updates - so fixes take effect"
    ["Node exporter"]="CPU, RAM, disk and network figures for Prometheus"
    [Falco]="watches system calls - shells in containers, changed files"
    [sshd]="the SSH server - keys only, no root password, own port"
    [Access]="who reaches SSH - tailnet only is the safest"
    ["Admin users"]="personal sudo users with a key - traceable, no root login"
    ["Safe updates"]="fixes that change nothing, unattended - holes closed within hours"
    ["Other updates"]="new versions, may change behaviour - installed on purpose"
    ["Other sources"]="repositories without a known safe range - only by hand"
    [Reboot]="a new kernel or library only counts after a reboot"
    ["Free space check"]="mail before a disk is full - full disks stop services"
    [Prometheus]="central monitoring over the tailnet - trends, alerts"
    ["Anomaly alerts"]="Falco findings by mail - so someone reads them"
    ["Security check"]="rootkit check and audit (rkhunter, lynis) - finds changes"
    ["Image check"]="critical holes in container base images that a newer image closes"
    [Documentation]="report of the last run - what was set up, when, how"
    ["Old installations"]="tools run from another copy - that copy gets no fixes"
)
declare -A AUDIT_BLOCK=(
    [1]="how the system itself is set - the ground for the rest"
    [2]="installed software - the building blocks for 3 to 5"
    [3]="who can log in, and how - the most attacked door"
    [4]="known holes get closed without anyone logging in"
    [5]="problems reach a person before they become an outage"
)

# The overview: audit_rows prints "row<US>note", audit_align lines the notes up
# as the right-most column (cut at the terminal width) or drops them.
audit() { audit_rows | audit_align; }

audit_align() {
    local w=0 dim="" rst=""
    if [[ -t 1 ]]; then
        w=$(stty size </dev/tty 2>/dev/null | awk '{print $2}'); [[ "$w" =~ ^[0-9]+$ ]] || w=0
        dim=$'\e[2m'; rst=$'\e[0m'
    fi
    awk -F $'\x1f' -v info="$AUDIT_INFO" -v w="$w" -v dim="$dim" -v rst="$rst" '
        { left[NR] = $1; sub(/ +$/, "", left[NR]); note[NR] = (NF > 1) ? $2 : ""
          if (note[NR] != "" && length(left[NR]) > max) max = length(left[NR]) }
        END {
            col = max + 2
            narrow = (info == 1 && w > 0 && col + 30 > w)   # no room for a readable column
            for (i = 1; i <= NR; i++) {
                l = left[i]; n = note[i]
                if (info != 1 || narrow || n == "") {
                    print l
                    if (i == 1 && narrow)
                        printf "%s(the notes on what each item is for need a terminal of %d+ columns, this one has %d)%s\n", dim, col + 50, w, rst
                    continue
                }
                if (w > 0 && col + length(n) > w) n = substr(n, 1, w - col - 3) "..."
                printf "%s%" (col - length(l)) "s%s%s%s\n", l, "", dim, n, rst
            }
        }'
}

audit_rows() {
    local id ver pretty n sp tip users ms mstate mname v dp of rb k t inst run
    IFS='|' read -r id ver pretty < <(os_info)
    sp=$(ssh_port); tip=$(tailnet_ip)
    users=$(sudo_key_users | tr '\n' ' ' | sed 's/ $//')
    TODO=()

    # line MARK LEVEL "item" "detail"
    line() {
        local lv
        case "$2" in req) lv=required ;; rec) lv=recommended ;; *) lv=optional ;; esac
        printf '  [%s] %-20s %-12s %s\x1f%s\n' "$1" "$3" "$lv" "$4" "${AUDIT_DESC[$3]:-}"
        [[ "$2" == req && "$1" != x && "$1" != - ]] && TODO+=("$3")
        return 0
    }
    # comp MARK LEVEL "name" installed running "set up"
    comp() {
        local lv
        case "$2" in req) lv=required ;; rec) lv=recommended ;; *) lv=optional ;; esac
        printf '  [%s] %-20s %-12s %-10s %-9s %s\x1f%s\n' "$1" "$3" "$lv" "$4" "$5" "$6" "${AUDIT_DESC[$3]:-}"
        [[ "$2" == req && "$1" != x && "$1" != - ]] && TODO+=("$3")
        return 0
    }
    # block N "header" - a block header, its note on the right
    block() { echo; printf '%s\x1f%s\n' "$2" "${AUDIT_BLOCK[$1]}"; }
    yn() { if "$@"; then echo x; else echo " "; fi; }
    svc() { systemctl is-active --quiet "$1" 2>/dev/null && echo active || echo stopped; }

    echo "--- Baseline status of $(hostname -s) ---  [x] in place  [ ] missing  [!] attention  [-] n/a"
    echo "Tools ${VERSION} in ${DIR}$( [[ -L "$DIR" ]] && echo " -> $(readlink "$DIR")")"

    # -----------------------------------------------------------------
    block 1 "1 Settings"
    line "$(yn st_os)" req "OS" "$pretty"
    line "$(time_synced && echo x || echo " ")" req "Time" "$(time_text)"
    v=$(sys_lang); k=$(missing_locales | tr '\n' ' ' | sed 's/ $//')
    line "$(st_locale && echo x || { locale_utf8 && echo '!' || echo " "; })" rec "Locale" \
         "LANG=${v:-unset}$(locale_utf8 || echo " (not UTF-8)")$( [[ "$v" == "$SYS_LANG" ]] || echo ", wanted ${SYS_LANG}")${k:+, missing ${k}}"
    if in_container; then
        line "-" rec "Kernel hardening" "container - the host's business"
    else
        read -r n t < <(sysctl_score)
        line "$( (( n == t )) && echo x || echo " ")" rec "Kernel hardening" "${n}/${t} settings as recommended (effective values)"
    fi
    line "$(yn st_swap)" rec "Swap" "$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' | grep . || echo "none (RAM $(mem_mb) MB)")"
    line "$(yn st_hostname)" rec "Hostname" "$(hostname -s)$(st_hostname || echo " - looks like a provider default")"
    line "$(yn st_basetools)" opt "Shell comfort" "$(st_basetools && echo "coloured prompt, history, aliases (base-tools)" || echo "not set up")"

    # -----------------------------------------------------------------
    block 2 "2 Components"
    printf '      %-20s %-12s %-10s %-9s %s\x1f%s\n' "" "" "installed" "running" "set up" "what for"
    v=$(basetools_text); v=${v%%,*}
    comp "$( [[ "$v" == "6/6 "* ]] && echo x || echo " ")" opt "Small tools" "${v%% *}" "-" "$(grep -o 'missing: [^)]*' <<<"$v" || echo -)"
    # firewall
    of=$(other_firewall)
    if st_ufw; then
        comp x req "Firewall" ufw active \
             "default deny, allowed: $(ufw status 2>/dev/null | awk 'NR>4 && $2 ~ /ALLOW|LIMIT/ && $1 !~ /\(v6\)/ {printf "%s ", $1 ($2=="on"?" on "$3:"")}')"
    elif ufw_active; then
        comp "!" req "Firewall" ufw active "NOT default deny"
    elif st_nft; then
        comp x req "Firewall" nftables active "policy drop, accepted: $(nft_accepted | grep . || echo nothing) (own ruleset)"
    elif [[ -n "$of" ]]; then
        comp "!" req "Firewall" "$of" active "not judged here - ufw or nftables expected"
    else
        comp " " req "Firewall" "$(command -v ufw &>/dev/null && echo "ufw" || echo no)" \
             "$(command -v ufw &>/dev/null && echo inactive || echo -)" "no firewall - every listening port is reachable"
    fi
    # mailer
    ms=$(mail_state); mname=${ms%%|*}; mstate=${ms#*|}
    case "$mname" in
        exim4)   run=$(svc exim4) ;;
        postfix) run=$(svc postfix) ;;
        "")      run="-" ;;
        *)       run="-" ;;
    esac
    comp "$( [[ "$mstate" == ok* ]] && echo x || { [[ "$mstate" == none ]] && echo " " || echo '!'; })" req "Mailer" \
         "${mname:-no}" "$run" "$( [[ "$mstate" == none ]] && echo "alerts cannot leave the machine" || echo "$mstate")"
    # fail2ban: required for public SSH
    k=$(f2b_level)
    if command -v fail2ban-client &>/dev/null; then
        comp "$(f2b_sshd && echo x || echo '!')" "$k" "fail2ban" yes "$(svc fail2ban)" "$(f2b_sshd && echo "sshd jail" || echo "no sshd jail")"
    else
        comp "$( [[ "$k" == req ]] && echo " " || echo "-")" "$k" "fail2ban" no "-" \
             "$( [[ "$k" == req ]] && echo "needed while SSH is public" || echo "not needed - SSH only over the tailnet$(st_ssh_tailnet_only || echo " (planned)")")"
    fi
    # tailscale: required for the tailnet way
    k=opt; [[ "${C[SSH_ACCESS]}" == tailnet ]] && k=req
    if command -v tailscale &>/dev/null; then
        comp "$( [[ -z "$tip" ]] && echo " " || { tailscale_ssh_on && echo '!' || echo x; })" "$k" "Tailscale" yes "$(svc tailscaled)" \
             "$( [[ -n "$tip" ]] && echo "${tip}$(v=$(tailnet_control); [[ -n "$v" ]] && echo " via ${v}")$(tailscale_ssh_on && echo ", Tailscale SSH ON - bypasses sshd")" || echo "not connected")"
    else
        comp "$( [[ "$k" == req ]] && echo " " || echo "-")" "$k" "Tailscale" no "-" "not in a tailnet"
    fi
    # docker
    if command -v docker &>/dev/null; then
        dp=$(docker_public)
        comp "$([[ -n "$dp" ]] && echo '!' || echo x)" opt "Docker" "$(docker --version 2>/dev/null | sed 's/Docker version //; s/,.*//')" "$(svc docker)" \
             "$( [[ -n "$dp" ]] && echo "PUBLIC container ports (bypass the firewall): ${dp}" || echo "no public container ports")"
    else
        comp "-" opt "Docker" no "-" "-"
    fi
    # update and monitoring components - installed by the functions below
    inst=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "ok installed" && echo yes || echo no)
    comp "$( [[ "$inst" == yes ]] && echo x || echo " ")" req "unattended-upgrades" "$inst" \
         "$(uu_active && echo "own timer" || echo "-")" "$( [[ -f /etc/apt/apt.conf.d/52auto-update ]] && echo "driven by auto-update (security only)" || echo "not driven by auto-update")"
    comp "$(command -v needrestart &>/dev/null && echo x || echo " ")" rec "needrestart" \
         "$(command -v needrestart &>/dev/null && echo yes || echo no)" "-" "-"
    v=$(node_exp_addr)
    comp "$( [[ -z "$v" ]] && echo "-" || { st_nodeexp && echo x || echo '!'; })" opt "Node exporter" \
         "$( [[ -n "$v" ]] || dpkg-query -W prometheus-node-exporter &>/dev/null && echo yes || echo no)" "$( [[ -n "$v" ]] && echo active || echo "-")" \
         "${v:+listens on ${v}$(st_nodeexp || echo " - not the tailnet IP")}"
    if falco_active || command -v falco &>/dev/null; then
        comp "$(st_anomaly && echo x || echo '!')" rec "Falco" yes "$(falco_active && echo active || echo stopped)" \
             "$( [[ -f /etc/cron.d/anomaly-monitor ]] && echo "alerts by mail (anomaly-monitor)" || echo "nobody reads its alerts")"
    else
        comp " " rec "Falco" no "-" "-"
    fi

    # -----------------------------------------------------------------
    block 3 "3 SSH access    needs: firewall $(st_firewall && echo "[x]" || echo "[ ]")  fail2ban (public) $(f2b_sshd && echo "[x]" || echo "[ ]")  tailscale (tailnet way) $( [[ -n "$tip" ]] && echo "[x]" || echo "[ ]")"
    if ! command -v sshd &>/dev/null && [[ ! -x /usr/sbin/sshd ]]; then
        line " " req "sshd" "no SSH server installed"
    else
        line "$(yn st_ssh_hardened)" req "sshd" \
             "port ${sp}, root login $(v=$(sshd_val permitrootlogin); echo "${v:-?}"), passwords $(v=$(sshd_val passwordauthentication); echo "${v:-?}"), keys $(v=$(sshd_val pubkeyauthentication); echo "${v:-?}")"
    fi
    if st_ssh_tailnet_only; then
        line x req "Access" "tailnet only (port ${sp} on tailscale0)"
    elif [[ -n "$(ssh_public_rules)" ]]; then
        line "$(st_ssh_hardened && [[ -n "$users" ]] && f2b_sshd && echo x || echo '!')" req "Access" \
             "public on port ${sp} through the firewall$(f2b_sshd || echo ", no fail2ban")"
    elif st_firewall; then
        line "!" req "Access" "no $(firewall_kind) rule for port ${sp} - only an open session or the console gets in"
    elif [[ -n "$of" ]]; then
        line "!" req "Access" "public? ${of} decides (not checked here)"
    else
        line "!" req "Access" "public on port ${sp} - no firewall in front"
    fi
    line "$( [[ -n "$users" ]] && echo x || { st_ssh_tailnet_only && echo "-" || echo " "; })" \
         "$(st_ssh_tailnet_only && echo opt || echo req)" "Admin users" \
         "${users:-none (sudo + key)}$( [[ -s /root/.ssh/authorized_keys ]] && echo "; root has keys")"

    # -----------------------------------------------------------------
    block 4 "4 Updates       needs: unattended-upgrades $(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q "ok installed" && echo "[x]" || echo "[ ]")  needrestart $(command -v needrestart &>/dev/null && echo "[x]" || echo "[ ]")  mailer $(st_mail && echo "[x]" || echo "[ ]")"
    # What auto-update says about itself: safe updates, other updates waiting.
    local ov held unk
    ov=$("$UPDATE_SCRIPT" --overview 2>/dev/null)
    ovv() { sed -n "s/^$1=//p" <<<"$ov"; }
    if [[ "$(ovv setup)" == 1 ]]; then
        held=$(ovv held); unk=$(ovv unknown)
        if [[ "$(ovv safe)" == off ]]; then
            line " " req "Safe updates" "off"
        elif uu_active; then
            line "!" req "Safe updates" "$(ovv safe) + the own timer of unattended-upgrades (fixed by the next run)"
        elif [[ -n "$held" ]]; then
            line "!" req "Safe updates" "$(ovv safe); held after a failed check: ${held}"
        else
            line x req "Safe updates" "$(ovv safe)"
        fi
        n=$(ovv other_n); k=$(ovv other_days)
        if (( ${n:-0} == 0 )); then
            line x rec "Other updates" "$(ovv other_schedule) - none waiting"
        else
            line "$( (( ${k:-0} > $(ovv other_wait) )) && echo '!' || echo x)" rec "Other updates" \
                 "$(ovv other_schedule) - ${n} waiting, oldest ${k} days ($(ovv other_list))"
        fi
        [[ -n "$unk" ]] && line "!" rec "Other sources" "not covered by the safe updates: ${unk}"
    else
        if uu_active; then
            line "!" req "Safe updates" "only unattended-upgrades' own timer: no third-party, no reboot window, no mail"
        else
            line " " req "Safe updates" "none"
        fi
        n=$(upgradable_count)
        line "$( (( n == 0 )) && echo x || echo '!')" rec "Other updates" "not set up - ${n} upgradable"
    fi
    if rb=$(reboot_needed); then line "!" rec "Reboot" "needed - ${rb}"; else line x rec "Reboot" "not needed"; fi

    # -----------------------------------------------------------------
    block 5 "5 Monitoring    needs: mailer $(st_mail && echo "[x]" || echo "[ ]")  node exporter + tailscale (Prometheus) $( [[ -n "$(node_exp_addr)" && -n "$tip" ]] && echo "[x]" || echo "[ ]")  Falco $(falco_active && echo "[x]" || echo "[ ]")"
    line "$(yn st_disk)" rec "Free space check" "$(st_disk && echo "hourly (disk-monitor)" || echo "not set up")"
    line "$(st_nodeexp && echo x || echo "-")" opt "Prometheus" "$(st_nodeexp && echo "node exporter on $(node_exp_addr), scraped over the tailnet" || echo "not set up")"
    line "$(st_anomaly && echo x || echo " ")" rec "Anomaly alerts" "$(st_anomaly && echo "Falco, mailed by anomaly-monitor" || echo "not set up")"
    v=$(other_seccheck)
    line "$(st_seccheck && echo x || { [[ -n "$v" ]] && echo x || echo " "; })" rec "Security check" \
         "$(st_seccheck && echo "$(sed -n 's/^SCHEDULE="\(.*\)"/\1/p' "$DIR/security-check.conf" 2>/dev/null) (security-check)" || echo "${v:+other: ${v}}${v:-not scheduled}")"
    if command -v docker &>/dev/null; then
        v=$("$IMGCHECK_SCRIPT" --status 2>/dev/null); k=$?
        case "$k" in
            0) line x rec "Image check" "$v" ;;
            1) line "!" rec "Image check" "$v" ;;
            *) line " " rec "Image check" "not set up - container base images are not checked" ;;
        esac
    else
        line "-" rec "Image check" "no Docker"
    fi
    local r; r=$(last_report)
    line "$([[ -n "$r" ]] && echo x || echo " ")" rec "Documentation" "${r:-no report yet}"

    local fi_n; fi_n=$(find_foreign | cut -d'|' -f1,2 | sort -u | wc -l)
    if (( fi_n > 0 )); then
        echo
        line "!" rec "Old installations" "${fi_n} tool(s) run from: $(find_foreign | cut -d'|' -f2 | sort -u | tr '\n' ' ')"
    fi
    echo
    if (( ${#TODO[@]} > 0 )); then
        echo "To do - required, still missing: $(printf '%s, ' "${TODO[@]}" | sed 's/, $//')"
    else
        echo "All required items are in place."
    fi
}

# Example texts - deliberately plain, to be adapted before sending.
announcement_text() {
    local host; host=$(hostname -s)
    cat <<EOF
Subject: Maintenance on ${host}${WINDOW:+ - ${WINDOW}}

Hello,

${WINDOW:-<date, time from-to>} we will bring the server ${host}
(${PURPOSE:-<purpose / application>}) up to the security baseline.

What this means for you:

- During the window, updates are installed and services restart; the
  server may reboot once. The application can be unavailable for a few
  minutes in between.

- Afterwards, updates are installed automatically in fixed windows:
  security updates every 60 minutes; all other updates are installed
  by hand, announced separately. Affected services restart briefly by themselves. If an
  update needs a reboot (new kernel), the server restarts at night at
  03:00 - only then, and only when needed.

- From the internet, only the application ports stay reachable
  (${PUBLIC_PORTS:-<ports>}). If any other system connects to this server today -
  monitoring, backup, interfaces of partners - please tell us before the
  window, otherwise that connection will be blocked.

- Administrative access (SSH) will only be possible via the
  tailnet or with a personal SSH key. Whoever needs admin access: please
  send us your public SSH key or ask for a tailnet login.

Questions: ${NOTIFY_TO:-<contact>}

Best regards
<name>
EOF
}

# Sent after the run: what actually changed.
completion_text() {
    local host sp tip; host=$(hostname -s); sp=$(ssh_port); tip=$(tailnet_ip || true)
    local access
    case "$SSH_MODE" in
        tailnet) access="only via the tailnet: ssh -p ${sp} <user>@${tip:-<tailnet-ip>}
  (or the tailnet name ${host}). Public SSH is closed." ;;
        public)  access="via SSH with a personal key, no root login, no passwords:
  ssh -p ${sp} <user>@${PUBLIC_IP:-<public-ip>}" ;;
        *)       access="unchanged" ;;
    esac
    cat <<EOF
Subject: Maintenance on ${host} completed

Hello,

the maintenance on ${host} (${PURPOSE:-<purpose>}) is completed.
The server is running normally again.

What has changed:

- Admin access: ${access}
- Reachable from the internet: $(read -r t u < <(public_ports); echo "tcp ${t}, udp ${u}")
- Updates: $(st_autoupdate && "$UPDATE_SCRIPT" --status 2>/dev/null | sed 's/^auto-update: //' || echo "no automatic updates")
- Failures and low disk space are reported to ${NOTIFY_TO:-<recipient>}.

If anything does not work as before, please reply to this mail.

Best regards
<name>
EOF
}

write_report() {
    SSH_MODE=$(ssh_mode_now)
    banner "Configuration summary"
    mkdir -p "$REPORT_DIR"
    local host f d
    host=$(hostname -s)
    f="$REPORT_DIR/${host}-$(date +%Y%m%d-%H%M).txt"
    d="$REPORT_DIR/${host}-doc-entry.txt"
    config_summary | tee "$f"
    {
        echo
        echo "CHECKLIST"
        local line item status extra
        for line in "${SUMMARY[@]}"; do
            IFS='|' read -r item status extra <<<"$line"
            printf '%-22s %-14s %s\n' "$item" "$status" "$extra"
        done
        echo
        echo "FIREWALL"
        if st_nft; then nft list ruleset 2>/dev/null; else ufw status verbose 2>/dev/null || echo "ufw not active"; fi
        echo
        echo "LISTENING SERVICES"
        show_listeners
    } >> "$f"
    doc_entry_text > "$d"
    chmod 600 "$f" "$d"
    echo
    echo "Saved: ${f}"
    echo "Documentation entry (purpose/owner/backup still TODO): ${d}"
    note "Documentation" "saved" "$f"
}

# Short overview of what this server is configured with now.
config_summary() {
    local tip t u au m
    tip=$(tailnet_ip || true)
    read -r t u < <(public_ports)
    au=$("$UPDATE_SCRIPT" --status 2>/dev/null | sed 's/^auto-update: //')
    m=$(mailer_name || true)
    printf '%-14s %s\n' \
        "Host:"        "$(hostname -f 2>/dev/null || hostname -s)" \
        "OS:"          "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"), kernel $(uname -r)" \
        "Public IP:"   "${PUBLIC_IP:-unknown}" \
        "Tailnet:"     "${tip:-not connected}" \
        "SSH:"         "port $(ssh_port), ${SSH_MODE:-unchanged}, admins: $(sudo_key_users | tr '\n' ' ')" \
        "Public ports:" "tcp ${t}, udp ${u}" \
        "Updates:"     "${au:-not set up}" \
        "Mail:"        "${m:-not set up}${MAIL_FROM:+, from ${MAIL_FROM}}, alerts to ${NOTIFY_TO:-nobody}" \
        "Free space:"  "$(st_disk && echo "hourly check" || echo "not set up")" \
        "Monitoring:"  "$(st_nodeexp && echo "node exporter on $(node_exp_addr)" || echo "not set up")" \
        "Docker:"      "$(command -v docker &>/dev/null && docker --version 2>/dev/null | sed 's/Docker version //' || echo "not installed")"
}

# Example entry for the server documentation (wiki, CMDB, ticket) - plain text.
doc_entry_text() {
    local host sp tip id ver pretty users au ssh_access m
    host=$(hostname -s); sp=$(ssh_port); tip=$(tailnet_ip || true)
    IFS='|' read -r id ver pretty < <(os_info)
    users=$(sudo_key_users | tr '\n' ' ')
    au=$("$UPDATE_SCRIPT" --status 2>/dev/null | sed 's/^auto-update: //')
    m=$(mailer_name)
    case "$SSH_MODE" in
        tailnet) ssh_access="only via the tailnet (${tip:-tailnet IP})" ;;
        public)  ssh_access="public, key only, no root login" ;;
        *)       ssh_access="TODO (unchanged by this run)" ;;
    esac
    # Plain text on purpose: it is pasted into wikis, tickets and mails that
    # do not render Markdown.
    cat <<EOF
SERVER ${host}
$(printf '%*s' $((7 + ${#host})) '' | tr ' ' '=')

Purpose:              ${PURPOSE:-TODO}
Owner / contact:      ${OWNER:-TODO}
Technical contact:    ${NOTIFY_TO:-TODO}
FQDN:                 $(hostname -f 2>/dev/null || echo TODO)
Public IP:            ${PUBLIC_IP:-TODO}
Tailnet:              ${tip:-not connected}$( [[ -n "$tip" ]] && echo " (${HEADSCALE_URL})" )
Provider / location:  TODO (incl. where the emergency console is)
OS:                   ${pretty}
Baseline:             base-setup ${VERSION}, last run $(date +%F)

APPLICATIONS
TODO: what runs here (service, version, path, compose project), which
domains point here, which ports it needs.

ACCESS
SSH:                  port ${sp}, ${ssh_access}
Admin users with key: ${users:-none}
Passwords:            sudo/root in the password manager, entry TODO
Emergency access:     provider console - TODO link

NETWORK
Publicly open:        $(read -r t u < <(public_ports); echo "tcp ${t}, udp ${u}")
Firewall:             $(if st_nft; then echo "nftables, own ruleset (/etc/nftables.conf)"; else echo "ufw, default deny incoming; changes via ufw-manager.sh"; fi)

OPERATIONS
Updates:              ${au:-not set up}
Mail delivery:        ${m:-none}, alerts to ${NOTIFY_TO:-TODO}
Free space check:     $(st_disk && echo "hourly, disk-monitor.sh" || echo "not set up")
Monitoring:           $(st_nodeexp && echo "Prometheus node exporter on $(node_exp_addr), scraped over the tailnet" || echo "TODO / not set up")
Backup:               TODO (what, where, how often, last restore test)
External port scan:   register at the scanner: $(scan_register_cmd)
Scripts:              ${DIR}

CHANGE HISTORY
$(date +%F)  ${SUDO_USER:-root}  baseline applied (base-setup ${VERSION})${WINDOW:+, window ${WINDOW}}
EOF
}

show_summary() {
    echo
    echo "==========================================================="
    echo " Summary"
    echo "==========================================================="
    local line item status extra
    printf '%-22s %-14s %s\n' "ITEM" "STATUS" "NOTE"
    printf '%-22s %-14s %s\n' "----------------------" "--------------" "----"
    for line in "${SUMMARY[@]}"; do
        IFS='|' read -r item status extra <<<"$line"
        printf '%-22s %-14s %s\n' "$item" "$status" "$extra"
    done
}

# ===========================================================================
# Configuration in the steps: a value that is set is taken without a question
# ===========================================================================
have_tty() { { true </dev/tty; } 2>/dev/null; }

# given KEY -> the configuration sets it (--conf file, argument; secrets also environment)
given() { [[ "${C_SRC[$1]}" != default && -n "${C[$1]}" ]]; }

# The one question before an item that is not in place yet, the same in every
# step: "<Item> (<level>) - set up now?". Required and recommended items
# default to yes, optional ones to no (or the default given); with --yes the
# default is taken.
now_q() {
    local lv
    case "$2" in req) lv=required ;; rec) lv=recommended ;; *) lv=optional ;; esac
    echo "${1} (${lv}) - set up now?"
}
setup_now() { confirm "$(now_q "$1" "$2")" "${3:-$( [[ "$2" == opt ]] && echo N || echo Y)}"; }

# want KEY "Question" Y|N -> yes/no from the configuration, else asked
# (with --yes: the default).
want() {
    local k=$1 q=$2 def=$3
    if given "$k"; then
        echo "${q} -> ${C[$k]} (${k} in the configuration)"
        [[ "${C[$k]}" == yes ]]; return
    fi
    confirm "$q" "$def"
}

# A value base-setup asks itself (recipient, public IP): from the
# configuration, else asked and written back to the file.
ask_value() {   # ask_value KEY "Question" [default] [required]
    local k=$1 q=$2 def=${3:-} req=${4:-} v msg
    given "$k" && return 0
    if (( ASSUME_YES == 1 )); then
        [[ -n "$def" ]] && conf_set "$k" "$def"
        return 0
    fi
    while true; do
        read -rp "${q}${def:+ [${def}]}: " v || return 1
        v=${v:-$def}
        [[ -z "$v" && -z "$req" ]] && return 0
        msg=$(check_value "$k" "$v" 2>&1) && [[ -n "$msg" ]] && break
        echo "  -> ${msg:-required}"
    done
    conf_set "$k" "$msg"
}

# Tool calls: presets as DEFAULT_*, with --yes in batch mode (no questions).
# Usage: tool <script> <args...> -- environment from the array E
E=()
preset_if() {   # preset_if KEY DEFAULT_NAME [value] - adds to E when KEY is given
    given "$1" || return 0
    E+=("$2=${3-${C[$1]}}")
}
tool() {
    local script=$1; shift
    [[ -x "$script" ]] || chmod +x "$script" 2>/dev/null || true
    if (( ASSUME_YES == 1 )); then
        env "${E[@]}" BATCH=1 "$script" "$@" </dev/null
    else
        env "${E[@]}" "$script" "$@"
    fi
}

# Recipient of the alert mails - asked once, kept in the configuration.
ask_notify_to() {
    given NOTIFY_TO && return 0
    echo
    echo "Recipient for failure and alert mails: this address really gets mail -"
    echo "failed updates, low disk space, Falco, the security check. A team mailbox"
    echo "is better than a person. Several: comma-separated."
    ask_value NOTIFY_TO "Recipient for alert mails"
    NOTIFY_TO=${C[NOTIFY_TO]}
}

# With --yes nothing can be asked: what has no default must be configured.
MISSING=()
preflight_yes() {
    (( ASSUME_YES == 1 )) || return 0
    local blocks=" $* "
    MISSING=()
    if [[ "$blocks" == *" block_components "* ]]; then
        if [[ "${C[TAILNET]}" == yes || -n "${C[HEADSCALE_URL]}" ]] && [[ -z "$(tailnet_ip)" ]]; then
            [[ -n "${C[TS_AUTHKEY]}" ]] || MISSING+=("TS_AUTHKEY (secret)")
        fi
        # no mailer yet: MAILER (default smtp) needs its values
        if [[ -z "$(mailer_name)" ]]; then
            case "${C[MAILER]}" in
                smtp)
                    given SMTP_HOST || MISSING+=("SMTP_HOST (MAILER=smtp, the default)")
                    given MAIL_FROM || MISSING+=("MAIL_FROM")
                    given SMTP_USER || MISSING+=("SMTP_USER")
                    [[ -n "${C[SMTP_PASSWORD]}" ]] || MISSING+=("SMTP_PASSWORD (secret)") ;;
                graph)
                    given GRAPH_TENANT_ID || MISSING+=("GRAPH_TENANT_ID")
                    given GRAPH_CLIENT_ID || MISSING+=("GRAPH_CLIENT_ID")
                    given MAIL_FROM || MISSING+=("MAIL_FROM")
                    [[ -n "${C[GRAPH_CLIENT_SECRET]}" ]] || MISSING+=("GRAPH_CLIENT_SECRET (secret)") ;;
            esac
        fi
    fi
    if [[ "$blocks" == *" block_ssh "* ]]; then
        # SSH_ACCESS defaults to public: then the admin user and key are needed
        if [[ "${C[SSH_ACCESS]}" == public && "$(ssh_mode_now)" != public ]]; then
            given ADMIN_USER || MISSING+=("ADMIN_USER")
            given ADMIN_KEY || MISSING+=("ADMIN_KEY")
            [[ -n "${C[ADMIN_PASSWORD]}" ]] || MISSING+=("ADMIN_PASSWORD (secret: file with chmod 600 or environment)")
        fi
        if [[ "${C[SSH_ACCESS]}" == tailnet && -z "$(tailnet_ip)" && " $* " != *" block_components "* ]]; then
            [[ -n "${C[TS_AUTHKEY]}" ]] || MISSING+=("TS_AUTHKEY (secret)")
        fi
    fi
    if (( ${#MISSING[@]} > 0 )); then
        echo "!!! --yes asks nothing - missing in ${CONF:-the configuration (--conf FILE)}:" >&2
        printf '!!!   %s\n' "${MISSING[@]}" >&2
        return 1
    fi
}

# What the configuration fixes (secrets as ***). Everything else is asked.
show_config() {
    local k v n=0
    echo "Configuration: ${CONF:-none (--conf FILE) - everything is asked}"
    for k in "${CONF_KEYS[@]}"; do
        given "$k" || [[ -n "${C[$k]}" && "${C_TYPE[$k]}" == secret ]] || continue
        v=${C[$k]}
        if is_secret "$k"; then v="***"
        elif [[ "$k" == ADMIN_KEY* ]]; then v="${v:0:20}...${v: -20}"; fi
        printf '  %-20s %s  (%s)\n' "$k" "$v" "${C_SRC[$k]}"
        n=$((n + 1))
    done
    (( n == 0 )) && echo "  (nothing set - every step asks)"
    echo "Values set here are taken without a question; everything else is asked."
}

# ===========================================================================
# Block 1: basic setup
# ===========================================================================
step_os() {
    banner "Check the operating system"
    local id="" ver="" min="" PRETTY_NAME=""
    [[ -r /etc/os-release ]] && IFS='|' read -r id ver PRETTY_NAME < <(os_info)
    echo "OS:      ${PRETTY_NAME:-unknown}"
    echo "Kernel:  $(uname -r)"
    echo "Virt:    $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo
    if [[ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]]; then
        echo "!!! PID 1 is not systemd - the tools depend on systemd and will fail."
        confirm "Continue anyway?" || return 1
    fi
    case "$id" in
        debian) min="12" ;;
        ubuntu) min="24.04" ;;
        *)
            echo "!!! Supported are Debian 12+ and Ubuntu 24.04+; this is '${id:-unknown}'."
            confirm "Continue anyway, at your own risk?" || return 1
            note "OS" "unsupported" "${PRETTY_NAME:-$id}"; return 0 ;;
    esac
    if dpkg --compare-versions "${ver:-0}" lt "$min"; then
        echo "!!! ${PRETTY_NAME:-$id} is older than the supported minimum (${min})."
        echo "!!! A release upgrade belongs before this baseline, not after it."
        confirm "Continue anyway?" || return 1
        note "OS" "too old" "${PRETTY_NAME:-$id}"; return 0
    fi
    echo "Supported."
    note "OS" "ok" "${PRETTY_NAME:-$id}"
}

step_upgrade() {
    banner "System update (required)"
    if given SYSTEM_UPGRADE && [[ "${C[SYSTEM_UPGRADE]}" == no ]]; then
        note "System update" "skipped" "SYSTEM_UPGRADE=no, $(upgradable_count) pending"; return 0
    fi
    E=(); given SYSTEM_UPGRADE && E+=("DEFAULT_UPGRADE_NOW=Y")
    tool "$UPDATE_SCRIPT" --upgrade-now
    case $? in
        0) note "System update" "ok" ;;
        2) note "System update" "skipped" "$(upgradable_count) package(s) pending" ;;
        3) note "System update" "done" "reboot required"
           echo "The reboot is offered at the end, so the setup is not interrupted."
           REBOOT_PENDING=1 ;;
        *) note "System update" "FAILED"
           confirm "Continue anyway?" Y || return 1 ;;
    esac
}

# Presets for base-tools from the configuration.
basetools_presets() {
    E=()
    preset_if TIMEZONE DEFAULT_TIMEZONE
    preset_if NTP_SERVERS DEFAULT_NTP_SERVERS
    preset_if SYS_LANG DEFAULT_LANG
    preset_if SYS_LOCALES DEFAULT_LOCALES
    preset_if KERNEL_HARDENING DEFAULT_SYSCTL "$( [[ "${C[KERNEL_HARDENING]}" == yes ]] && echo Y || echo N)"
    preset_if SWAP DEFAULT_SWAP
    # what the configuration fixes, the tool does not ask again
    given TIMEZONE && E+=("DEFAULT_TIME_SETUP=Y")
    given SYS_LANG && E+=("DEFAULT_LOCALE_SETUP=Y")
    return 0
}

# Settings: coloured prompt, history, aliases, editor and screen settings.
step_shell() {
    banner "Shell comfort (optional)"
    echo "Coloured prompt (root in red), history with time stamps, aliases, editor"
    echo "and screen/tmux settings - for every user."
    local def=Y
    if st_basetools; then echo "-> Already set up."; def=N; fi
    if want SHELL_SETUP "$(st_basetools && echo "Write the shell settings again anyway?" || now_q "Shell comfort" opt)" "$def"; then
        if st_basetools && given SHELL_SETUP; then
            note "Shell comfort" "ok"
        else
            E=(); tool "$BASE_SCRIPT" --shell && note "Shell comfort" "done" || note "Shell comfort" "FAILED"
        fi
    else
        note "Shell comfort" "$(st_basetools && echo ok || echo skipped)"
    fi
}

# Components: the small tools of every day.
step_tools() {
    banner "Small tools (optional)"
    local v; v=$(basetools_text); v=${v%%,*}
    echo "Editors, screen/tmux, htop, curl, rsync, ncdu & co.: ${v}"
    if [[ "$v" == "6/6 "* ]]; then note "Small tools" "ok" "$v"; return 0; fi
    if want BASE_TOOLS "$(now_q "Small tools" opt)" Y; then
        basetools_presets
        tool "$BASE_SCRIPT" --packages && note "Small tools" "done" || note "Small tools" "FAILED"
    else
        note "Small tools" "skipped" "$v"
    fi
}

step_docker() {
    banner "Docker (optional)"
    if command -v docker &>/dev/null; then
        local dp; dp=$(docker_public)
        echo "-> Installed: $(docker --version 2>/dev/null | sed 's/Docker version //')"
        if [[ -n "$dp" ]]; then
            echo "!!! Published on all addresses (past the firewall): ${dp}"
            note "Docker" "WARNING" "public container ports: ${dp}"
        else
            note "Docker" "ok"
        fi
    elif echo "Official repository, log rotation, container ports on 127.0.0.1, live-restore." \
         && want DOCKER "$(now_q "Docker" opt)" N; then
        E=(); tool "$DOCKER_SCRIPT" --setup && note "Docker" "done" || note "Docker" "FAILED"
    else
        note "Docker" "not installed"
    fi
}

# Components: fail2ban - required while SSH is reachable from the internet.
# fail2ban is required only while SSH is public - not when SSH is (or is
# going to be) reachable over the tailnet only, and not without an SSH server.
f2b_level() {
    if st_ssh_tailnet_only || [[ "${C[SSH_ACCESS]}" == tailnet ]] \
       || { ! command -v sshd &>/dev/null && [[ ! -x /usr/sbin/sshd ]]; }; then
        echo opt
    else
        echo req
    fi
}
step_fail2ban() {
    banner "fail2ban (required while SSH is public)"
    echo "Bans an address for an hour after 5 failed SSH logins in 10 minutes;"
    echo "the tailnet is never banned."
    if f2b_sshd; then note "fail2ban" "ok" "sshd jail active"; return 0; fi
    local lv def=Y; lv=$(f2b_level)
    [[ "$lv" == opt ]] && { def=N; echo "-> Not needed: SSH $(st_ssh_tailnet_only && echo is || echo "is going to be") reachable over the tailnet only."; }
    if want FAIL2BAN "$(now_q "fail2ban (SSH jail, port $(ssh_port))" "$lv")" "$def"; then
        E=(); tool "$SSH_SCRIPT" --fail2ban && note "fail2ban" "done" "sshd jail, port $(ssh_port)" || note "fail2ban" "FAILED"
    else
        note "fail2ban" "skipped"
    fi
}

# System basics, each checked on every run: time sync and timezone, locale,
# kernel hardening, swap.
step_system() {
    banner "Time (required), locale, kernel hardening, swap (recommended)"
    basetools_presets
    local -a E0=("${E[@]}")
    if st_time; then
        echo "[x] Time: $(time_text)"; note "Time" "ok" "$(time_text)"
    else
        echo "[ ] Time: $(time_text) - wanted: synchronised, ${TIMEZONE}"
        if given TIMEZONE || setup_now "Time sync and timezone" req; then
            E=("${E0[@]}" DEFAULT_TIME_SETUP=Y); tool "$BASE_SCRIPT" --time || true
            st_time && note "Time" "done" "$(time_text)" || note "Time" "WARNING" "$(time_text)"
        else
            note "Time" "skipped" "$(time_text)"
        fi
    fi
    echo
    if st_locale; then
        echo "[x] Locale: ${SYS_LANG} + ${SYS_LOCALES}"; note "Locale" "ok"
    else
        echo "[ ] Locale: LANG=$(sys_lang | grep . || echo unset) - wanted: ${SYS_LANG}, available ${SYS_LOCALES}"
        if given SYS_LANG || setup_now "Locale" rec; then
            E=("${E0[@]}" DEFAULT_LOCALE_SETUP=Y); tool "$BASE_SCRIPT" --locale || true
            st_locale && note "Locale" "done" || note "Locale" "kept"
        else
            note "Locale" "skipped"
        fi
    fi
    echo
    if given KERNEL_HARDENING && [[ "${C[KERNEL_HARDENING]}" == no ]]; then
        note "Kernel hardening" "skipped" "KERNEL_HARDENING=no"
    elif st_sysctl; then
        echo "[x] Kernel hardening"; note "Kernel hardening" "ok"
    else
        local n t; read -r n t < <(sysctl_score)
        echo "[ ] Kernel hardening: ${n}/${t} settings as recommended"
        if given KERNEL_HARDENING || setup_now "Kernel hardening" rec; then
            E=("${E0[@]}" DEFAULT_SYSCTL=Y); tool "$BASE_SCRIPT" --sysctl || true
            st_sysctl && note "Kernel hardening" "done" || note "Kernel hardening" "skipped"
        else
            note "Kernel hardening" "skipped"
        fi
    fi
    E=("${E0[@]}")
    echo
    if given SWAP && [[ "${C[SWAP]}" == no ]]; then
        note "Swap" "skipped" "SWAP=no"
    elif st_swap; then
        echo "[x] Swap: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ' | grep . || echo "not needed")"
        note "Swap" "ok"
    else
        tool "$BASE_SCRIPT" --swap || true
        st_swap && note "Swap" "done" || note "Swap" "skipped"
    fi
}

step_hostname() {
    banner "Hostname (recommended)"
    local cur; cur=$(hostname -s 2>/dev/null || echo unknown)
    echo "Current hostname: ${cur}   (FQDN: $(hostname -f 2>/dev/null || echo -))"
    if given HOSTNAME; then
        if [[ "${C[HOSTNAME]}" == "$cur" ]]; then note "Hostname" "ok" "$cur"; return 0; fi
        local dom=${C[HOST_DOMAIN]}; [[ "$dom" == - ]] && dom=""
        E=(); if tool "$HOST_SCRIPT" --set "${C[HOSTNAME]}" "$dom"; then
            note "Hostname" "done" "$(hostname -s)"
        else
            note "Hostname" "FAILED" "${C[HOSTNAME]}"
        fi
        return 0
    fi
    cat <<'EOF'

The hostname should say what the machine is FOR - it shows up in every
alert mail, in the tailnet, in the shell prompt and in the documentation.
A provider's random name (vm-123456, ubuntu-s-1vcpu...) says nothing at
3 a.m. Suggested scheme: <customer>-<purpose>-<env><no>, for example
  acme-crm-prod01     acme-git-01     shop-web-test01
EOF
    echo
    st_hostname || echo "-> '${cur}' looks like a provider default."
    if (( ASSUME_YES == 0 )) && confirm "Set a different hostname now?" "$(st_hostname && echo N || echo Y)"; then
        echo "In the menu: 1) to type the name, then 3) to quit."
        if run "$HOST_SCRIPT"; then note "Hostname" "done" "$(hostname -s)"; else note "Hostname" "FAILED"; fi
    else
        note "Hostname" "kept" "$cur"
    fi
}

step_firewall() {
    banner "Firewall - ufw or nftables (required)"
    if st_nft; then
        echo "-> $(firewall_text) - an own ruleset."
        echo "   It is kept; ufw is not put on top. Ports are opened in that ruleset."
        note "Firewall" "ok" "nftables (own ruleset)"
    elif given FIREWALL && [[ "${C[FIREWALL]}" == keep ]]; then
        note "Firewall" "kept" "$(st_firewall && echo active || echo "NOT active")"
    else
        local run_it=1
        if st_firewall && ! given FIREWALL; then
            echo "-> ufw is active with default deny:"
            ufw status 2>/dev/null | sed -n '5,$p' | sed 's/^/   /'
            confirm "Run the firewall baseline again (review the open ports)?" || run_it=0
        elif ! st_firewall && ! given FIREWALL; then
            echo "[ ] $(firewall_text)"
            setup_now "Firewall (ufw)" req || run_it=2
        fi
        if (( run_it == 2 )); then
            note "Firewall" "skipped" "NOT active - everything reachable"
        elif (( run_it == 1 )); then
            E=("DEFAULT_SETUP_FIREWALL=Y")
            # PUBLIC_PORTS given: it is the complete list - no 80/443 question,
            # no pick from the listening services
            if given PUBLIC_PORTS; then
                E+=("DEFAULT_OPEN_WEB=N" "DEFAULT_ALLOW_LISTENERS=-" "DEFAULT_APP_PORTS=${C[PUBLIC_PORTS]}")
            fi
            tool "$UFW_SCRIPT" --setup
            case $? in
                0) note "Firewall" "done" "public: $(public_ports)" ;;
                2) note "Firewall" "kept" "$(st_firewall && echo active || echo "NOT active - everything reachable")" ;;
                *) note "Firewall" "FAILED" ;;
            esac
        else
            note "Firewall" "ok"
        fi
    fi
    ask_public_ip
}

# For the texts and the registration at the external port scanner.
ask_public_ip() {
    local guess
    if ! given PUBLIC_IP; then
        guess=$(curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
        echo
        echo "Public IP (what DNS points to) - for the documentation and the"
        echo "external port scan. Enter accepts the detected address."
        ask_value PUBLIC_IP "Public IP of this server" "$guess"
        PUBLIC_IP=${C[PUBLIC_IP]}
    fi
    echo
    echo "External check: register this server at the port scanner (another host):"
    echo "    $(scan_register_cmd)"
}

# Presets for ssh-setup (and the tailscale-setup it calls).
ssh_presets() {
    local i k
    E=()
    preset_if SSH_ACCESS DEFAULT_SSH_ACCESS
    # --yes: the default (public) without a question
    if (( ASSUME_YES == 1 )) && ! given SSH_ACCESS; then E+=("DEFAULT_SSH_ACCESS=${C[SSH_ACCESS]}"); fi
    case "${C[SSH_PORT]}" in
        auto) ;;
        *) preset_if SSH_PORT DEFAULT_SSH_PORT ;;
    esac
    if given SSH_ROOT_LOGIN; then
        case "${C[SSH_ROOT_LOGIN]}" in
            key) E+=("DEFAULT_ROOTLOGIN_CHOICE=1") ;; no) E+=("DEFAULT_ROOTLOGIN_CHOICE=2") ;;
            password) E+=("DEFAULT_ROOTLOGIN_CHOICE=3") ;;
        esac
    fi
    if given SSH_PASSWORD_LOGIN; then
        case "${C[SSH_PASSWORD_LOGIN]}" in
            no) E+=("DEFAULT_PASSWORD_OFF=Y") ;; yes) E+=("DEFAULT_PASSWORD_OFF=N") ;;
        esac
    fi
    preset_if FAIL2BAN DEFAULT_FAIL2BAN "$( [[ "${C[FAIL2BAN]}" == yes ]] && echo Y || echo N)"
    if given ADMIN_USER; then E+=("DEFAULT_ADMIN_USER=${C[ADMIN_USER]}" "DEFAULT_CREATE_ADMIN=Y"); fi
    preset_if ADMIN_KEY DEFAULT_ADMIN_KEY
    for i in 2 3 4 5 6 7 8 9; do k="ADMIN_KEY_$i"; preset_if "$k" "DEFAULT_$k"; done
    [[ -n "${C[ADMIN_PASSWORD]}" ]] && E+=("ADMIN_PASSWORD=${C[ADMIN_PASSWORD]}")
    preset_if HEADSCALE_URL TS_LOGIN_SERVER
    preset_if HOSTNAME DEFAULT_TS_HOSTNAME
    [[ -n "${C[TS_AUTHKEY]}" ]] && E+=("TS_AUTHKEY=${C[TS_AUTHKEY]}" "DEFAULT_TS_LOGIN=authkey")
    return 0
}

step_ssh() {
    banner "Secure the SSH access (required)"
    local cur rc=0
    cur=$(ssh_mode_now)
    echo "Two ways: SSH only over a tailnet (Tailscale/Headscale) - root login is"
    echo "fine there - or public with a personal admin user (sudo, key), root and"
    echo "passwords off, a port that does not look like SSH, fail2ban."
    if given SSH_ACCESS; then
        if [[ "${C[SSH_ACCESS]}" == keep ]]; then
            note "SSH access" "kept" "${cur:-not secured}, port $(ssh_port)"; ssh_root_password; return 0
        fi
        if [[ "${C[SSH_ACCESS]}" == "$cur" ]]; then
            note "SSH access" "ok" "$cur, port $(ssh_port)"; ssh_root_password; return 0
        fi
    elif [[ -n "$cur" ]]; then
        echo "-> Already secured: $( [[ "$cur" == tailnet ]] && echo "SSH only over the tailnet" || echo "public, key-only, admin user(s): $(sudo_key_users | tr '\n' ' ')")"
        if ! confirm "Change the SSH access anyway?"; then
            note "SSH access" "ok" "$cur, port $(ssh_port)"; ssh_root_password; return 0
        fi
    elif ! setup_now "SSH access" req; then
        note "SSH access" "skipped" "not secured, port $(ssh_port)"; ssh_root_password; return 0
    fi
    if [[ -z "$(tailnet_ip)" ]]; then
        echo
        echo "For the tailnet way, the server joins first (offered in the dialogue)"
        echo "with an auth key: Tailscale admin console, or on a Headscale server"
        echo "'headscale preauthkeys create --user <user> --expiration 1h'."
        [[ -n "$HEADSCALE_URL" ]] && echo "Control server: ${HEADSCALE_URL} (preset)."
    fi
    echo
    if st_nft; then
        echo "!!! The firewall is nftables (own ruleset): ssh-setup opens and closes ports"
        echo "!!! in ufw only. Set the SSH rule in the nftables ruleset yourself, e.g."
        echo "!!!   tailnet only: iifname \"tailscale0\" tcp dport <port> accept"
        echo "!!!   public:       tcp dport <port> accept"
    fi
    echo "Needs: firewall $(st_firewall && echo "active ($(firewall_kind))" || echo "NOT active - nothing can be closed, SSH stays public")," \
         "tailnet $( [[ -n "$(tailnet_ip)" ]] && echo "connected" || echo "not connected - the tailnet way joins first (block 1)")."
    echo
    echo "!!! Keep the provider's console at hand - it is the fallback if SSH breaks."
    echo "!!! The new login is tested in a SECOND terminal before anything is closed."
    echo
    ssh_presets
    # stdin stays the terminal (also with --yes): the login tests are asked there
    local -a b=()
    (( ASSUME_YES == 1 )) && b=(BATCH=1)
    env "${E[@]}" "${b[@]}" "$SSH_SCRIPT" --setup || rc=$?
    cur=$(ssh_mode_now)
    if (( rc == 2 )); then
        note "SSH access" "kept" "${cur:-not secured}, port $(ssh_port)"
    elif [[ -n "$cur" ]]; then
        note "SSH access" "done" "$cur, port $(ssh_port)"
    else
        note "SSH access" "open" "not secured - see ${SSH_SCRIPT}"
    fi
    ssh_root_password
}

# Root password: from the configuration, or checked when root may log in
# with one (tailnet way).
ssh_root_password() {
    if [[ -n "${C[ROOT_PASSWORD]}" ]]; then
        E=("ROOT_PASSWORD=${C[ROOT_PASSWORD]}")
        if BATCH=1 env "${E[@]}" "$ROOTPW_SCRIPT" </dev/null; then
            note "Root password" "done" "set from the configuration"
        else
            note "Root password" "FAILED"
        fi
    elif [[ "$(sshd_val permitrootlogin)" == yes ]]; then
        echo
        echo "Root may log in with a password (over the tailnet). The password then"
        echo "has to be strong and in the password manager - not a provider default."
        if (( ASSUME_YES == 0 )) && ! confirm "Is a strong root password set and stored in the password manager?"; then
            run "$ROOTPW_SCRIPT" || true
        fi
    fi
    if [[ "$(sshd_val permitrootlogin)" == yes || "$(sshd_val passwordauthentication)" == yes ]] \
            && [[ "$(ssh_mode_now)" != tailnet ]]; then
        note "SSH exposure" "WARNING" "passwords allowed, port open publicly"
    fi
}

mail_presets() {
    E=()
    preset_if MAILER DEFAULT_MAILER
    preset_if MAIL_FROM DEFAULT_MAIL_FROM
    preset_if MAIL_FROM DEFAULT_SENDER
    preset_if MAIL_FROM_NAME DEFAULT_SENDER_NAME
    preset_if GRAPH_TENANT_ID DEFAULT_TENANT_ID
    preset_if GRAPH_CLIENT_ID DEFAULT_CLIENT_ID
    preset_if GRAPH_SECRET_EXPIRY DEFAULT_SECRET_EXPIRY
    preset_if NOTIFY_TO DEFAULT_EXPIRY_MAIL
    preset_if NOTIFY_TO DEFAULT_ROOT_RCPT
    preset_if SMTP_HOST DEFAULT_SMTP_HOST
    preset_if SMTP_PORT DEFAULT_SMTP_PORT
    if given SMTP_PORT; then E+=("DEFAULT_SMTP_TLS=$( [[ "${C[SMTP_PORT]}" == 465 ]] && echo tls || echo starttls)"); fi
    if given SMTP_USER; then E+=("DEFAULT_SMTP_USER=${C[SMTP_USER]}" "DEFAULT_SMTP_AUTH=Y"); fi
    [[ "${C[MAILER]}" == graph ]] && given MAILER && E+=("DEFAULT_REPLACE_MSMTP=Y")
    [[ -n "${C[GRAPH_CLIENT_SECRET]}" ]] && E+=("GRAPH_CLIENT_SECRET=${C[GRAPH_CLIENT_SECRET]}")
    [[ -n "${C[SMTP_PASSWORD]}" ]] && E+=("SMTP_PASSWORD=${C[SMTP_PASSWORD]}")
    return 0
}

# Everything the mailer type needs is in the configuration (secrets aside).
mail_complete() {
    case "$1" in
        smtp)  given SMTP_HOST && given MAIL_FROM ;;
        graph) given GRAPH_TENANT_ID && given GRAPH_CLIENT_ID && given MAIL_FROM ;;
        *)     return 0 ;;
    esac
}
mail_status_line() {
    local ms; ms=$(mail_state)
    echo "[ ] $( [[ -n "${ms%%|*}" ]] && echo "${ms%%|*}: ${ms#*|}" || echo "no mailer - alerts cannot leave the machine")"
}
step_mail() {
    banner "Mail delivery (required - alerts must leave the machine)"
    local have rc=0 type="" c def=1 ms
    have=$(mailer_name)
    if given MAILER; then
        case "${C[MAILER]}" in
            none) note "Mail" "skipped" "MAILER=none - alerts only in the logs"; return 0 ;;
            keep) note "Mail" "$( [[ -n "$have" ]] && echo ok || echo kept)" "${have:-no mailer}"; return 0 ;;
            graph) [[ "$have" == graph-mailer ]] && { note "Mail" "ok" "$have"; return 0; } ;;
            smtp)  [[ "$have" == msmtp ]] && { note "Mail" "ok" "$have"; return 0; } ;;
        esac
        # The type is configured, its values are not all: the setup asks for
        # them - so ask first whether now is the time.
        if (( ASSUME_YES == 0 )) && ! mail_complete "${C[MAILER]}"; then
            mail_status_line
            if ! setup_now "Mail delivery via $( [[ "${C[MAILER]}" == graph ]] && echo "Microsoft 365 (Graph)" || echo SMTP)" req; then
                note "Mail" "skipped" "${have:-no mailer - alerts only in the logs}"; return 0
            fi
        fi
    elif (( ASSUME_YES == 1 )); then
        [[ -n "$have" ]] && { note "Mail" "ok" "$have"; return 0; }
        type=${C[MAILER]}           # the default: smtp
        [[ "$type" == none || "$type" == keep ]] && { note "Mail" "skipped" "MAILER=${type}"; return 0; }
    else
        if [[ -n "$have" ]]; then
            echo "-> A mailer is set up already (${have})."
            confirm "Configure it again anyway?" || { note "Mail" "ok" "$have"; return 0; }
            [[ "$have" == graph-mailer ]] && def=2
        else
            mail_status_line
        fi
        echo "How should mail leave this server?"
        echo "  1) SMTP account (msmtp)          - a mailbox or relay with SMTP login"
        echo "  2) Microsoft 365 via Graph API   - when SMTP AUTH is blocked in the tenant"
        echo "  3) not now"
        read -rp "$(now_q "Mail delivery" req) [${def}]: " c || c=3
        case "${c:-$def}" in
            1) type=smtp ;;
            2) type=graph ;;
            *) note "Mail" "skipped" "${have:-no mailer - alerts only in the logs}"; return 0 ;;
        esac
    fi
    ask_notify_to
    mail_presets
    if [[ -n "$type" ]]; then
        E+=("DEFAULT_MAILER=${type}")
        [[ "$type" == graph ]] && E+=("DEFAULT_REPLACE_MSMTP=Y")
    fi
    tool "$MAIL_SCRIPT" --setup || rc=$?
    have=$(mailer_name)
    if (( rc == 2 )); then note "Mail" "kept" "${have:-no mailer - alerts only in the logs}"
    elif (( rc == 0 )) && [[ -n "$have" ]]; then note "Mail" "done" "${have} - check that the test mail arrived"
    else note "Mail" "FAILED" "see ${MAIL_SCRIPT}"; fi
}

# Join a tailnet (Tailscale / Headscale) - for admin access and monitoring.
step_tailnet() {
    banner "Tailnet - Tailscale / Headscale (optional; required for the SSH tailnet way)"
    local tip def=N
    tip=$(tailnet_ip)
    if [[ -n "$tip" ]]; then
        echo "-> Connected: ${tip}$(v=$(tailnet_control); [[ -n "$v" ]] && echo " via ${v}")"
        if tailscale_ssh_on; then
            echo "!!! Tailscale SSH is on - it answers SSH on the tailnet itself, past sshd."
            note "Tailnet" "WARNING" "${tip}, Tailscale SSH on - switch it off: tailscale set --ssh=false"
        else
            note "Tailnet" "ok" "$tip"
        fi
        return 0
    fi
    echo "A tailnet gives admin access and monitoring without open ports. The"
    echo "server joins with an auth key: Tailscale admin console, or on a Headscale"
    echo "server 'headscale preauthkeys create --user <user> --expiration 1h'."
    [[ -n "${C[HEADSCALE_URL]}" ]] && echo "Control server: ${C[HEADSCALE_URL]} (configured)."
    [[ -n "${C[HEADSCALE_URL]}" || "${C[SSH_ACCESS]}" == tailnet ]] && def=Y
    if ! want TAILNET "$(now_q "Tailnet" "$( [[ "${C[SSH_ACCESS]}" == tailnet ]] && echo req || echo opt)")" "$def"; then
        note "Tailnet" "skipped" "not connected"; return 0
    fi
    E=()
    preset_if HEADSCALE_URL TS_LOGIN_SERVER
    preset_if HOSTNAME DEFAULT_TS_HOSTNAME
    [[ -n "${C[TS_AUTHKEY]}" ]] && E+=("TS_AUTHKEY=${C[TS_AUTHKEY]}" "DEFAULT_TS_LOGIN=authkey")
    if tool "$TS_SCRIPT" --login && [[ -n "$(tailnet_ip)" ]]; then
        note "Tailnet" "done" "$(tailnet_ip)"
    else
        note "Tailnet" "FAILED" "see ${TS_SCRIPT}"
    fi
}

block_settings() {
    BLOCK="1 Settings"
    step_os || return 1
    step_upgrade || return 1
    step_hostname
    step_system
    step_shell
}

block_components() {
    BLOCK="2 Components"
    step_tools
    step_firewall
    step_mail
    step_fail2ban
    step_tailnet
    step_docker
}

# ===========================================================================
# Block 3: SSH access
# ===========================================================================
block_ssh() {
    BLOCK="3 SSH access"
    step_ssh
}

# ===========================================================================
# Block 4: updates
# ===========================================================================
autoupdate_presets() {
    local wd
    local -a d=(sun mon tue wed thu fri sat)
    E=()
    if given SEC_UPDATES; then
        case "${C[SEC_UPDATES]}" in
            hourly) E+=("DEFAULT_SEC_SCHEDULE=interval" "DEFAULT_SEC_INTERVAL_MIN=60") ;;
            *)      E+=("DEFAULT_SEC_SCHEDULE=${C[SEC_UPDATES]}") ;;
        esac
    fi
    preset_if FULL_UPDATES DEFAULT_FULL_SCHEDULE
    if given FULL_DAY; then
        for wd in 0 1 2 3 4 5 6; do [[ "${d[$wd]}" == "${C[FULL_DAY]}" ]] && break; done
        E+=("DEFAULT_FULL_WEEKDAY=$wd")
    fi
    preset_if FULL_TIME DEFAULT_FULL_TIME
    preset_if REBOOT DEFAULT_SEC_REBOOT
    preset_if REBOOT DEFAULT_FULL_REBOOT
    preset_if REBOOT_TIME DEFAULT_REBOOT_TIME
    preset_if EXCLUDE_PKGS DEFAULT_EXCLUDE_PKGS
    preset_if NOTIFY_TO DEFAULT_MAIL_TO
    return 0
}

step_autoupdate() {
    banner "Automatic updates (required)"
    cat <<'EOF'
Safe updates - fixes that change nothing in behaviour - are installed
unattended: the security updates of the distribution, and of Docker,
Tailscale, Caddy, Falco, nginx.org, Apache (Sury) the versions their projects
keep compatible - checked afterwards, rolled back when a check fails. Quick
ones hourly, Docker and Tailscale in the night window. Other updates (new
versions, can change behaviour) by hand. A needed reboot: in the night
window. Mail on errors, rollbacks and other updates waiting too long.
EOF
    echo
    local cfg=0 k
    for k in SEC_UPDATES FULL_UPDATES FULL_DAY FULL_TIME REBOOT REBOOT_TIME EXCLUDE_PKGS; do
        given "$k" && cfg=1
    done
    if st_autoupdate && (( cfg == 0 )); then
        echo "-> Set up: $("$UPDATE_SCRIPT" --status 2>/dev/null | sed 's/^auto-update: //')"
        confirm "Change the settings anyway?" || { note "Auto updates" "ok"; return 0; }
    elif ! st_autoupdate && (( cfg == 0 )) && ! setup_now "Safe updates" req; then
        note "Auto updates" "skipped"; return 0
    fi
    ask_notify_to
    autoupdate_presets
    tool "$UPDATE_SCRIPT" --setup || true
    if st_autoupdate; then
        note "Auto updates" "done" "$("$UPDATE_SCRIPT" --status 2>/dev/null | sed 's/^auto-update: //')"
    else
        note "Auto updates" "FAILED" "no cron entry"
    fi
}

block_updates() {
    BLOCK="4 Updates"
    step_autoupdate
}

# ===========================================================================
# Block 5: monitoring
# ===========================================================================
# monitor_step KEY "item" "intro" st_func "setup question" -> 0 = set it up
monitor_wanted() {   # monitor_wanted KEY "note item" state_fn "question item" level
    local k=$1 item=$2 st=$3 q=$4 lv=$5
    if given "$k"; then
        [[ "${C[$k]}" == no ]] && { note "$item" "skipped" "${k}=no$($st && echo " (set up earlier, not removed)")"; return 1; }
        $st && { note "$item" "ok"; return 1; }
        return 0
    fi
    if $st; then
        echo "-> Already set up."
        confirm "Run the setup again anyway?" || { note "$item" "ok"; return 1; }
        return 0
    fi
    setup_now "$q" "$lv" Y || { note "$item" "skipped"; return 1; }
}

step_disk() {
    banner "Free space (recommended)"
    echo "Checks every hour and mails when a filesystem drops below the"
    echo "threshold - once on the change, not every hour."
    monitor_wanted DISK_MONITOR "Free space check" st_disk "Free space check" rec || return 0
    ask_notify_to
    mailer_ready || echo "!!! No mailer yet - alerts would only go to the log."
    E=(); preset_if NOTIFY_TO DEFAULT_ALERT_MAIL
    [[ "$(mailer_name)" == "" && "${C[MAILER]}" == none ]] && E+=("DEFAULT_NO_MAILER_OK=Y")
    tool "$DISK_SCRIPT" --setup || true
    if st_disk; then
        note "Free space check" "done" "alerts to ${C[NOTIFY_TO]:-log only}"
    else
        note "Free space check" "FAILED" "no cron entry"
    fi
}

step_monitoring() {
    banner "Prometheus node exporter (optional)"
    echo "The central Prometheus collects CPU, RAM, disks, network, systemd units"
    echo "and pending updates - over the tailnet only (bound to the tailnet IP)."
    if [[ -z "$(tailnet_ip)" ]] && ! st_nodeexp; then
        echo "-> Not in the tailnet - skipped (later: ${NODEEXP_SCRIPT} --setup)."
        note "Monitoring" "skipped" "no tailnet"; return 0
    fi
    if given NODE_EXPORTER && [[ "${C[NODE_EXPORTER]}" == auto ]]; then C[NODE_EXPORTER]=yes; fi
    monitor_wanted NODE_EXPORTER "Monitoring" st_nodeexp "Prometheus node exporter" opt || return 0
    E=(); if tool "$NODEEXP_SCRIPT" --setup; then
        note "Monitoring" "done" "node exporter on $(node_exp_addr)"
    else
        note "Monitoring" "FAILED"
    fi
}

step_anomaly() {
    banner "Anomaly detection - Falco (recommended)"
    echo "Falco watches what processes do and mails suspicious behaviour: shells"
    echo "in containers, writes into /etc or binary directories, reading"
    echo "/etc/shadow, privilege escalation. Default rules, nothing to configure."
    monitor_wanted FALCO "Anomaly detection" st_anomaly "Anomaly detection (Falco)" rec || return 0
    ask_notify_to
    E=(); preset_if NOTIFY_TO DEFAULT_ALERT_MAIL
    if tool "$ANOMALY_SCRIPT" --setup; then
        note "Anomaly detection" "done" "Falco, mail to ${C[NOTIFY_TO]:-nobody}"
    else
        note "Anomaly detection" "FAILED" "see ${ANOMALY_SCRIPT}"
    fi
}

step_seccheck() {
    banner "Regular security check (recommended)"
    echo "debsums, rkhunter, chkrootkit, lynis and system checks once a month by"
    echo "cron - a mail only when there is something to look at."
    monitor_wanted SECURITY_CHECK "Security check" st_seccheck "Security check" rec || return 0
    ask_notify_to
    E=(); preset_if NOTIFY_TO DEFAULT_MAIL_TO
    tool "$SECCHECK_SCRIPT" --schedule || true
    st_seccheck && note "Security check" "done" "findings to ${C[NOTIFY_TO]:-nobody}" \
        || note "Security check" "skipped"
}

step_imagecheck() {
    banner "Container base images (recommended with Docker)"
    if ! command -v docker &>/dev/null; then
        echo "-> No Docker - nothing to check."; note "Image check" "n/a" "no Docker"; return 0
    fi
    echo "apt does not update the images the containers run from. Nightly, Trivy"
    echo "checks the OS packages of their base images and mails CRITICAL holes that"
    echo "a newer base image closes - it only reports, it changes nothing."
    monitor_wanted IMAGE_CHECK "Image check" st_imagecheck "Image check" rec || return 0
    ask_notify_to
    E=(); preset_if NOTIFY_TO DEFAULT_MAIL_TO
    tool "$IMGCHECK_SCRIPT" --setup || true
    st_imagecheck && note "Image check" "done" "nightly, findings to ${C[NOTIFY_TO]:-nobody}" \
        || note "Image check" "FAILED" "see ${IMGCHECK_SCRIPT}"
}

block_monitoring() {
    BLOCK="5 Monitoring"
    step_disk
    step_monitoring
    step_anomaly
    step_seccheck
    step_imagecheck
}

# ===========================================================================
# Running blocks, menu
# ===========================================================================
run_blocks() {
    SUMMARY=()
    echo
    show_config
    preflight_yes "$@" || return 1
    local b
    for b in "$@"; do
        "$b" || { echo "Aborted."; break; }
    done
    BLOCK=""
    write_report
    show_summary
    if (( REBOOT_PENDING == 1 )) || [[ -f /var/run/reboot-required ]]; then
        echo
        echo "!!! A reboot is required to finish the updates."
        if (( ASSUME_YES == 0 )) && confirm "Reboot NOW?"; then
            reboot
        else
            echo "Remember to reboot - or let the reboot window do it at night."
        fi
    fi
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================================="
        echo " Base setup ${VERSION} - $(hostname -s)"
        echo " Configuration: ${CONF:-none (--conf FILE) - everything is asked}"
        echo "==========================================================="
        audit
        echo
        echo "1) Settings       update, hostname, time, locale, kernel, swap, shell"
        echo "2) Components     tools, firewall, mailer, fail2ban, tailnet, Docker"
        echo "3) SSH access     tailnet only, or public with admin user and key"
        echo "4) Updates        security hourly, others by hand, reboot at night"
        echo "5) Monitoring     free space, Prometheus, Falco, security check"
        echo "6) Everything     1 -> 5"
        echo "7) Configuration  what the --conf file sets (taken without a question)"
        echo "8) Texts          announcement, documentation entry, completion notice"
        echo "i) Notes          $( [[ "$AUDIT_INFO" == 1 ]] && echo "hide" || echo "show") what each item is and why"
        echo "q) Quit"
        local c; read -rp "Choice: " c || exit 0
        case "$c" in
            1) run_blocks block_settings; pause ;;
            2) run_blocks block_components; pause ;;
            3) run_blocks block_ssh; pause ;;
            4) run_blocks block_updates; pause ;;
            5) run_blocks block_monitoring; pause ;;
            6) run_blocks $ALL_BLOCKS; pause ;;
            7) show_config; pause ;;
            8) show_texts | less -R 2>/dev/null || show_texts; pause ;;
            i|I) AUDIT_INFO=$(( 1 - AUDIT_INFO )) ;;
            q|Q) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

show_texts() {
    SSH_MODE=$(ssh_mode_now)
    echo "===== Announcement (before the window) ====="; announcement_text
    echo; echo "===== Documentation entry ====="; doc_entry_text
    echo; echo "===== Completion notice (after the run) ====="; completion_text
}

ALL_BLOCKS="block_settings block_components block_ssh block_updates block_monitoring"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
    --check)       audit ;;
    --texts)       show_texts ;;
    --show-config) show_config ;;
    --all)         handle_foreign_install; run_blocks $ALL_BLOCKS ;;
    --block)
        handle_foreign_install
        case "$MODE_ARG" in
            settings)   run_blocks block_settings ;;
            components) run_blocks block_components ;;
            basic)      run_blocks block_settings block_components ;;
            ssh)        run_blocks block_ssh ;;
            updates)    run_blocks block_updates ;;
            monitoring) run_blocks block_monitoring ;;
            *) die "Blocks: settings, components, ssh, updates, monitoring (basic = settings + components)" ;;
        esac ;;
    "")            handle_foreign_install; main_menu ;;
esac
