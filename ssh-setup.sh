#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ssh-setup.sh - secure SSH access: tailnet-only or public with a non-root
#                admin, hardening via a drop-in, protection against lockout
#
# Two ways to secure the access (--setup):
#   tailnet - SSH only reachable over the Tailscale tailnet: the tailnet is the
#             gate, so root login (also with password) is acceptable; the
#             public SSH rule is removed after a tested login over the tailnet
#   public  - SSH stays reachable from the internet: a non-root admin user
#             with sudo and a key, root login and passwords off, and a port
#             that does not look like SSH, optionally fail2ban
# Nothing is closed before the new way in has been tested in a second terminal.
#
# Modes: (no argument) = interactive menu
#        --setup       = guided: access mode, admin user, port, hardening, lock
#        --harden      = only the hardening values (port, root, passwords ...)
#        --status      = effective settings on stdout
#        --add-key     = store a public key for a user
#        --uninstall   = uninstall
#
# Presets: a DEFAULT_* that is set (not empty) is taken without a question -
# interactively as well - and printed as "<question>: <value> (preset)". An
# invalid preset is an error, nothing is changed. Unset ones are asked (batch
# mode: their built-in default, in brackets below). When all hardening values
# (port ... ClientAlive) are preset, "Apply like this?" is not asked either.
#   DEFAULT_SSH_ACCESS        tailnet|public|keep (public)
#   DEFAULT_TS_JOIN           Y|N  join the tailnet when not in one yet (Y)
#   DEFAULT_CREATE_ADMIN      Y|N  admin user also in the tailnet way (N)
#   DEFAULT_ADMIN_USER        name of the admin user (no default; required in
#                             the public way)
#   DEFAULT_ADMIN_KEY, DEFAULT_ADMIN_KEY_2 ... _9
#                             public key(s) of the admin user, each a full line
#                             "ssh-ed25519 AAAA... comment", checked with
#                             ssh-keygen -l (batch: at least one is required
#                             for an admin user)
#   DEFAULT_SSH_PORT          random|keep|<number> (public: random, tailnet: keep)
#   DEFAULT_ROOTLOGIN_CHOICE  1-3 (public: 2 = no, tailnet: 3 = yes)
#   DEFAULT_PASSWORD_OFF      Y|N  (public: Y, tailnet: N)
#   DEFAULT_MAX_AUTH_TRIES    number (current value, sshd default 6)
#   DEFAULT_LOGIN_GRACE_TIME  seconds (current value, sshd default 120)
#   DEFAULT_X11_FORWARDING    Y|N  (N)
#   DEFAULT_CLIENT_ALIVE      Y|N  drop dead sessions after ~10 min (Y)
#   DEFAULT_FAIL2BAN          Y|N  offered in the public way (Y)
# Secret, from the environment only (never printed):
#   ADMIN_PASSWORD            password of the admin user (batch mode: without
#                             it no password is set - sudo then needs one later)
# Batch mode: BATCH=1 - no questions, every question takes its default and
# prints what it took. EXCEPTION (with and without presets): the login tests before anything is closed
# ("Does the key login ... work?", "Does the login on port N work?", "Does SSH
# over the tailnet work?") are always asked on the terminal (/dev/tty). Without
# a terminal they count as "no": the old access stays open.
set -euo pipefail

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
TS_SCRIPT="$DIR/tailscale-setup.sh"
SSHD_CONF=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/99-ssh-setup.conf"
SOCKET_DIR=/etc/systemd/system/ssh.socket.d
SOCKET_DROPIN="$SOCKET_DIR/10-ssh-setup-port.conf"

MARK_BEGIN='# >>> ssh-setup >>>'
MARK_END='# <<< ssh-setup <<<'

# Prefix put in front of conflicting sshd_config lines. The match pattern also
# accepts the German prefix written by versions up to 1.0.0 - otherwise an
# uninstall on such a server would leave those lines commented out forever.
NEUTRAL_PREFIX='# disabled by ssh-setup: '
NEUTRAL_MATCH='^# (disabled by ssh-setup|von ssh-setup deaktiviert): '

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# yn_value VALUE - a yes/no value (Y, N, yes, no, j, ja, 1, 0, true, false)
# as Y or N; fails on anything else
yn_value() {
    case "${1,,}" in
        y|yes|j|ja|1|true)   echo Y ;;
        n|no|nein|0|false)   echo N ;;
        *)                   return 1 ;;
    esac
}
# yn VALUE [FALLBACK] - like yn_value, FALLBACK (N) for an empty/unknown value
yn() { yn_value "${1:-}" || echo "${2:-N}"; }

# preset NAME - 0 when the caller set the variable NAME (non-empty). Its
# question is then not asked, neither interactively nor in batch mode.
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }

# confirm "Question" [default Y|N] [DEFAULT_NAME]
# A preset DEFAULT_NAME answers the question without asking it.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# takes its default - DEFAULT_* from the caller or the built-in one - and
# prints what it took. A required value without a default is an error.
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (${pre})" >&2; exit 1; }
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
# confirm_tty: safety questions (does the new login work?) - always asked,
# also in batch mode, on the terminal. No terminal: the answer is "no".
confirm_tty() {
    if [[ -z "${BATCH:-}" ]]; then confirm "$@"; return; fi
    { true </dev/tty; } 2>/dev/null || { echo "$1 -> no terminal, treated as no"; return 1; }
    BATCH='' confirm "$@" </dev/tty
}
# ask VAR "Question" [default] [required] [DEFAULT_NAME] - the answer lands in
# VAR; a preset DEFAULT_NAME is taken without asking
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
# ask_secret VAR "Question" ENVNAME - from the environment variable ENVNAME if
# set, else asked hidden; in batch mode a missing secret is an error.
ask_secret() {
    local __v=$1 __q=$2 __e=$3 __a
    if [[ -n "${!__e:-}" ]]; then printf -v "$__v" '%s' "${!__e}"; echo "${__q}: (from \$${__e})"; return 0; fi
    if [[ -n "${BATCH:-}" ]]; then echo "!!! ${__q}: \$${__e} not set (batch mode)" >&2; return 1; fi
    read -rsp "${__q}: " __a; echo
    printf -v "$__v" '%s' "$__a"
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

# ---------------------------------------------------------------------------
# Detect the environment
# ---------------------------------------------------------------------------
SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)

ssh_unit() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        echo ssh
    else
        echo sshd
    fi
}

# From Ubuntu 22.10 on, sshd starts through socket activation. It then ignores
# the Port directive in sshd_config entirely - the port has to be set on
# ssh.socket. Without that distinction you move the firewall to the new port
# while sshd keeps listening on 22: lockout.
socket_activated() {
    systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null
}

sshd_test() { "$SSHD_BIN" -t 2>&1; }

# A failed restart must not end the script without a word - the user has to see
# what went wrong while their session is still up.
restart_sshd() {
    local unit; unit=$(ssh_unit)
    if systemctl restart "$unit"; then
        return 0
    fi
    echo "!!! Restarting ${unit} failed:"
    systemctl status "$unit" --no-pager -l 2>&1 | head -20 || true
    echo "!!! Do NOT close the running session before this is fixed."
    return 1
}

# Effective setting from 'sshd -T' - the only reliable source, because it has
# already merged drop-ins, includes and defaults.
effective() {
    "$SSHD_BIN" -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}' || true
}

is_setup() { [[ -f "$DROPIN" ]]; }

# With sshd the directive read FIRST wins. So if sshd_config already has
# 'PasswordAuthentication yes' above the include line, the drop-in has no
# effect - and you usually notice that only when it is too late.
effective_matches() {
    local got want=${2,,}; got=$(effective "$1"); got=${got,,}
    # sshd -T reports prohibit-password under its old name
    [[ "$got" == without-password ]] && got=prohibit-password
    [[ "$want" == without-password ]] && want=prohibit-password
    [[ "$got" == "$want" ]]
}

# Comment out the conflicting line instead of deleting it: traceable, and
# reversible by the uninstall.
neutralize() {
    sed -i -E "s|^([[:space:]]*$1[[:space:]]+.*)$|${NEUTRAL_PREFIX}\1|I" "$SSHD_CONF"
}

listening_port() {
    if command -v ss &>/dev/null; then
        ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' '
    fi
}

# Users with a key on file - without at least one of them, password login must
# not be switched off.
users_with_keys() {
    local d u
    for d in /root /home/*; do
        [[ -d "$d" ]] || continue
        [[ -s "$d/.ssh/authorized_keys" ]] || continue
        [[ "$d" == /root ]] && u=root || u=$(basename "$d")
        echo "$u"
    done
}

# Older distributions do not have the include line. Without it the drop-in
# would have no effect - and that only shows once you are locked out.
ensure_include() {
    grep -qE "^[[:space:]]*Include[[:space:]]+${DROPIN_DIR}/\*\.conf" "$SSHD_CONF" && return 0

    echo ">>> $SSHD_CONF has no include for $DROPIN_DIR yet - adding it."
    cp "$SSHD_CONF" "$SSHD_CONF.ssh-setup.bak"
    # Must go right to the top: with sshd the directive read first wins.
    {
        echo "$MARK_BEGIN"
        echo "Include ${DROPIN_DIR}/*.conf"
        echo "$MARK_END"
        cat "$SSHD_CONF.ssh-setup.bak"
    } > "$SSHD_CONF"
}

ufw_active() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }

tailnet_ip() { if command -v tailscale &>/dev/null; then tailscale ip -4 2>/dev/null | head -1 || true; fi; }

# Tailscale SSH takes over port 22 on the tailnet IP and lets only what the
# tailnet ACLs allow through ("tailnet policy does not permit you to SSH") -
# the regular sshd is never reached. Off.
ensure_tailscale_ssh_off() {
    command -v tailscale &>/dev/null || return 0
    tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": *true' || return 0
    echo "Tailscale SSH is on - it would intercept SSH on the tailnet IP."
    if tailscale set --ssh=false; then
        echo "-> Switched off; SSH on the tailnet IP goes to sshd again."
    else
        echo "!!! Could not switch it off - run: tailscale set --ssh=false"
    fi
}

# sshd_answers <address> <port> - an SSH server greets on that address
sshd_answers() {
    [[ -n "$1" ]] || return 1
    timeout 10 ssh-keyscan -T 5 -p "$2" "$1" 2>/dev/null | grep -q .
}

# A port that does not look like SSH: 10000-29999, without "22" in it, not in
# use, and not one of the well-known services in that range.
random_port() {
    local used p
    used=$(ss -tulnH 2>/dev/null | awk '{print $5}' | sed 's/.*://' | sort -u || true)
    while :; do
        p=$(( RANDOM % 20000 + 10000 ))
        [[ "$p" == *22* ]] && continue
        case "$p" in 10000|11211|15672|19999|25565|27017|27018|27019) continue ;; esac
        grep -qx "$p" <<<"$used" && continue
        echo "$p"; return 0
    done
}

# Numbers of the ufw rules that let one of the given ports (or the OpenSSH
# profile) in from ANYWHERE - not those bound to an interface - highest first,
# so deleting them one after the other keeps the numbering valid.
public_ssh_rules() {
    local ports=$1
    ufw status numbered 2>/dev/null | awk -v re="^((${ports})(/tcp)?|OpenSSH)( [(]v6[)])?[ ]+(ALLOW|LIMIT)" '
        /^\[/ {
            n = $0; sub(/^\[ */, "", n); sub(/\].*/, "", n)
            r = $0; sub(/^\[[^]]*\] */, "", r)
            if (r ~ / on /) next
            if (r ~ re) print n
        }' | sort -rn || true
}

delete_public_ssh_rules() {
    local n
    for n in $(public_ssh_rules "$1"); do
        ufw --force delete "$n" >/dev/null || echo "!!! Could not delete rule ${n}."
    done
}

# Passwords allowed and the port open to the internet: say so loudly.
exposure_warning() {
    local root pw sp
    root=$(effective permitrootlogin); pw=$(effective passwordauthentication); sp=$(effective port)
    [[ "$root" == "yes" || "$pw" == "yes" ]] || return 0
    if ufw_active && [[ -z "$(public_ssh_rules "${sp:-22}")" ]]; then return 0; fi
    echo
    echo "!!! SSH accepts passwords (root login: ${root}, password login: ${pw})"
    echo "!!! and port ${sp:-22} is NOT closed to the internet. Either lock SSH to"
    echo "!!! the tailnet or switch to keys only: $(basename "$0") --setup"
    return 0
}

# ---------------------------------------------------------------------------
# Public keys, admin user
# ---------------------------------------------------------------------------
# add_key_for <user> [key] [preset] - stores the key (asked for when not given;
# Enter takes the preset), returns 1 if nothing was stored
add_key_for() {
    local u=$1 key=${2:-} def=${3:-} home
    id "$u" &>/dev/null || { echo "User '$u' does not exist."; return 1; }
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || { echo "No home directory for '$u'."; return 1; }
    if [[ -z "$key" ]]; then
        echo "Paste the PUBLIC key for '${u}' (one line, ssh-ed25519 / ssh-rsa / ecdsa-...):"
        [[ -n "$def" ]] && echo "(Enter = the preset key ...${def: -40})"
        read -r key
        key=${key:-$def}
    fi
    if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        echo "That does not look like a public key - nothing stored."
        return 1
    fi
    mkdir -p "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if grep -qxF "$key" "$home/.ssh/authorized_keys"; then
        echo "Key is already on file."
    else
        echo "$key" >> "$home/.ssh/authorized_keys"
        echo "Stored in $home/.ssh/authorized_keys"
    fi
    chmod 700 "$home/.ssh"
    chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$u": "$home/.ssh"
}

add_key() {
    local u
    read -rp "For which user? [root]: " u
    add_key_for "${u:-root}" || true
}

# Creates (or reuses) an admin user with sudo and a key. Sets ADMIN_USER.
ADMIN_USER=""
# preset_keys [quiet] - the keys from DEFAULT_ADMIN_KEY, DEFAULT_ADMIN_KEY_2 ...
# _9 into PRESET_KEYS, each checked with ssh-keygen. 1 if one is invalid.
# Preset keys are stored without asking for a key.
PRESET_KEYS=()
preset_keys() {
    local quiet=${1:-} i kv k fp
    PRESET_KEYS=()
    for i in "" _2 _3 _4 _5 _6 _7 _8 _9; do
        kv="DEFAULT_ADMIN_KEY${i}"; k=${!kv:-}
        [[ -n "$k" ]] || continue
        if ! fp=$(ssh-keygen -l -f <(printf '%s\n' "$k") 2>/dev/null); then
            echo "!!! \$${kv} is not a valid public key (ssh-keygen -l rejects it)." >&2
            return 1
        fi
        [[ -n "$quiet" ]] || echo "Key from \$${kv}: ${fp} (preset)"
        PRESET_KEYS+=("$k")
    done
}

# check_presets - every preset DEFAULT_* is checked before anything is
# changed: an invalid one is an error, and nothing is written.
check_presets() {
    local v bad=0
    for v in DEFAULT_TS_JOIN DEFAULT_CREATE_ADMIN DEFAULT_PASSWORD_OFF \
             DEFAULT_X11_FORWARDING DEFAULT_CLIENT_ALIVE DEFAULT_FAIL2BAN; do
        preset "$v" || continue
        yn_value "${!v}" >/dev/null || { echo "!!! ${v}='${!v}': yes or no expected." >&2; bad=1; }
    done
    if preset DEFAULT_SSH_ACCESS && [[ ! "$DEFAULT_SSH_ACCESS" =~ ^(tailnet|public|keep)$ ]]; then
        echo "!!! DEFAULT_SSH_ACCESS='${DEFAULT_SSH_ACCESS}': tailnet, public or keep expected." >&2; bad=1
    fi
    if preset DEFAULT_ADMIN_USER && [[ ! "$DEFAULT_ADMIN_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
        echo "!!! DEFAULT_ADMIN_USER='${DEFAULT_ADMIN_USER}': invalid user name (lowercase letters, digits, '.', '-', '_')." >&2; bad=1
    fi
    preset_keys quiet || bad=1
    if preset DEFAULT_SSH_PORT && [[ ! "$DEFAULT_SSH_PORT" =~ ^(random|keep)$ ]] \
        && ! { [[ "$DEFAULT_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$DEFAULT_SSH_PORT <= 65535 )); }; then
        echo "!!! DEFAULT_SSH_PORT='${DEFAULT_SSH_PORT}': random, keep or a number between 1 and 65535 expected." >&2; bad=1
    fi
    if preset DEFAULT_ROOTLOGIN_CHOICE && [[ ! "$DEFAULT_ROOTLOGIN_CHOICE" =~ ^[123]$ ]]; then
        echo "!!! DEFAULT_ROOTLOGIN_CHOICE='${DEFAULT_ROOTLOGIN_CHOICE}': 1, 2 or 3 expected." >&2; bad=1
    fi
    if preset DEFAULT_MAX_AUTH_TRIES && [[ ! "$DEFAULT_MAX_AUTH_TRIES" =~ ^[1-9][0-9]*$ ]]; then
        echo "!!! DEFAULT_MAX_AUTH_TRIES='${DEFAULT_MAX_AUTH_TRIES}': a number (1 or more) expected." >&2; bad=1
    fi
    if preset DEFAULT_LOGIN_GRACE_TIME && [[ ! "$DEFAULT_LOGIN_GRACE_TIME" =~ ^[0-9]+$ ]]; then
        echo "!!! DEFAULT_LOGIN_GRACE_TIME='${DEFAULT_LOGIN_GRACE_TIME}': a number of seconds expected." >&2; bad=1
    fi
    (( bad == 0 )) || { echo "Invalid preset - nothing changed." >&2; return 1; }
}

# hardening_preset - 0 when every value of the hardening screen is preset;
# the "Apply like this?" question is then not asked either.
hardening_preset() {
    local v
    for v in DEFAULT_SSH_PORT DEFAULT_ROOTLOGIN_CHOICE DEFAULT_PASSWORD_OFF DEFAULT_MAX_AUTH_TRIES \
             DEFAULT_LOGIN_GRACE_TIME DEFAULT_X11_FORWARDING DEFAULT_CLIENT_ALIVE; do
        preset "$v" || return 1
    done
}

create_admin_user() {
    local u
    check_presets || return 1
    echo "Admin user: the account admins log in with instead of root. Best one"
    echo "per person (traceable in the logs). Lowercase letters, digits, '.',"
    echo "'-', '_' - e.g. 'jane.doe' or 'opsadmin'."
    ask u "Name of the admin user" "${DEFAULT_ADMIN_USER:-}" "${BATCH:+required}" DEFAULT_ADMIN_USER || return 1
    [[ "$u" =~ ^[a-z_][a-z0-9_.-]*$ ]] || { echo "Invalid user name."; return 1; }
    # Preset keys: checked BEFORE the user is created - no half-made admin.
    preset_keys || return 1
    if [[ -n "${BATCH:-}" ]] && (( ${#PRESET_KEYS[@]} == 0 )); then
        echo "!!! No public key for the admin user: set DEFAULT_ADMIN_KEY (batch mode)." >&2
        return 1
    fi
    if id "$u" &>/dev/null; then
        echo "User '$u' exists already."
    else
        # useradd, not adduser: Debian's adduser rejects names with a dot
        # (NAME_REGEX) - 'jane.doe' is exactly the suggested form.
        useradd -m -s /bin/bash "$u" || return 1
        echo "User '$u' created."
    fi
    # Debian installed with a root password comes without sudo - the admin
    # would then have no way to root once root login is off.
    if ! command -v sudo &>/dev/null; then
        echo ">>> Installing sudo..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q </dev/null sudo >/dev/null 2>&1 \
            || { echo "!!! sudo could not be installed - '$u' would have no root rights."; return 1; }
    fi
    usermod -aG sudo "$u"
    echo "Member of the group 'sudo'."
    echo
    echo "sudo asks for this user's password - set one now (and store it in the"
    echo "password manager). Without it, the user can log in but not use sudo."
    if [[ -n "${BATCH:-}" ]]; then
        if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
            local pw
            ask_secret pw "Password for '$u'" ADMIN_PASSWORD
            if chpasswd <<<"${u}:${pw}"; then echo "Password for '$u' set."; else echo "!!! Setting the password failed."; fi
            pw=""
        else
            confirm "Set the password for '$u' now?" N || true
            echo "  (none set now - without one '$u' cannot use sudo: passwd $u)"
        fi
    elif confirm "Set the password for '$u' now?" Y; then
        passwd "$u" || true
    fi
    echo
    if (( ${#PRESET_KEYS[@]} > 0 )); then
        local k
        for k in "${PRESET_KEYS[@]}"; do add_key_for "$u" "$k" || return 1; done
    else
        add_key_for "$u" "" || return 1
    fi
    ADMIN_USER=$u
}

# ---------------------------------------------------------------------------
# Hardening values
# ---------------------------------------------------------------------------
# ask_hardening <default port> <root choice 1-3> <password off Y|N>
# Sets H_PORT H_ROOT H_PASS H_TRIES H_GRACE H_X11 H_KEEP.
ask_hardening() {
    local dport=$1 rdef=$2 pwdef=$3
    local cur_tries cur_grace
    cur_tries=$(effective maxauthtries);   cur_tries=${cur_tries:-6}
    cur_grace=$(effective logingracetime); cur_grace=${cur_grace:-120}
    local -a keyusers=()
    mapfile -t keyusers < <(users_with_keys)

    if preset DEFAULT_SSH_PORT; then
        # random|keep were translated into $dport by ssh_port_default
        H_PORT=$dport
        echo "SSH port: ${H_PORT} (preset$( [[ "$DEFAULT_SSH_PORT" =~ ^[0-9]+$ ]] || echo " ${DEFAULT_SSH_PORT}"))"
    else
        ask H_PORT "SSH port" "$dport" || return 1
    fi
    while [[ ! "$H_PORT" =~ ^[0-9]+$ ]] || (( H_PORT < 1 || H_PORT > 65535 )); do
        if [[ -n "${BATCH:-}" ]]; then
            echo "!!! SSH port '${H_PORT}' (DEFAULT_SSH_PORT): a number between 1 and 65535 is expected." >&2
            return 1
        fi
        read -rp "  -> number between 1 and 65535: " H_PORT
    done

    echo
    echo "Root login:"
    echo "  1) key only (prohibit-password)"
    echo "  2) forbid entirely (no)"
    echo "  3) allow with password too (yes)"
    local R; ask R "Choice" "$rdef" "" DEFAULT_ROOTLOGIN_CHOICE || return 1
    if [[ -n "${BATCH:-}" && ! "$R" =~ ^[123]$ ]]; then
        echo "!!! Root login choice '${R}' (DEFAULT_ROOTLOGIN_CHOICE): 1, 2 or 3 expected." >&2
        return 1
    fi
    case "$R" in
        2) H_ROOT="no" ;;
        3) H_ROOT="yes" ;;
        *) H_ROOT="prohibit-password" ;;
    esac

    echo
    H_PASS="yes"
    if (( ${#keyusers[@]} == 0 )); then
        echo "Password login stays on - without a key on file, switching it off"
        echo "would be a guaranteed lockout."
    elif confirm "Switch password login off (keys only)?" "$pwdef" DEFAULT_PASSWORD_OFF; then
        H_PASS="no"
    fi
    if [[ "$H_ROOT" == "no" && "$H_PASS" == "no" ]]; then
        local u ok=0
        for u in "${keyusers[@]}"; do [[ "$u" != root ]] && ok=1; done
        if (( ok == 0 )); then
            echo "!!! Root forbidden and passwords off, but only root has a key -"
            echo "!!! nobody would get in. Root login is set to 'prohibit-password'."
            H_ROOT="prohibit-password"
        fi
    fi

    echo
    ask H_TRIES "MaxAuthTries" "${DEFAULT_MAX_AUTH_TRIES:-$cur_tries}" "" DEFAULT_MAX_AUTH_TRIES || return 1
    ask H_GRACE "LoginGraceTime in seconds" "${DEFAULT_LOGIN_GRACE_TIME:-$cur_grace}" "" DEFAULT_LOGIN_GRACE_TIME || return 1
    if [[ -n "${BATCH:-}" ]] && ! [[ "$H_TRIES" =~ ^[1-9][0-9]*$ && "$H_GRACE" =~ ^[0-9]+$ ]]; then
        echo "!!! MaxAuthTries '${H_TRIES}' / LoginGraceTime '${H_GRACE}': numbers expected." >&2
        return 1
    fi
    H_X11="no"; H_KEEP="yes"
    confirm "Allow X11 forwarding?" "$(yn "${DEFAULT_X11_FORWARDING:-}" N)" DEFAULT_X11_FORWARDING && H_X11="yes" || true
    confirm "Drop dead sessions after ~10 min (ClientAlive)?" "$(yn "${DEFAULT_CLIENT_ALIVE:-}" Y)" DEFAULT_CLIENT_ALIVE || H_KEEP="no"
}

# ssh_port_default <random|keep> <current port> - DEFAULT_SSH_PORT wins
ssh_port_default() {
    case "${DEFAULT_SSH_PORT:-$1}" in
        random) random_port ;;
        keep)   echo "$2" ;;
        *)      echo "$DEFAULT_SSH_PORT" ;;
    esac
}

show_hardening() {
    local cur_port=$1
    echo
    echo "======================= Summary ========================="
    printf '  %-24s %s\n' "Port"                   "$H_PORT$( [[ "$H_PORT" != "$cur_port" ]] && echo "   (was $cur_port)" )"
    printf '  %-24s %s\n' "PermitRootLogin"        "$H_ROOT"
    printf '  %-24s %s\n' "PasswordAuthentication" "$H_PASS"
    printf '  %-24s %s\n' "PubkeyAuthentication"   "yes"
    printf '  %-24s %s\n' "MaxAuthTries"           "$H_TRIES"
    printf '  %-24s %s\n' "LoginGraceTime"         "$H_GRACE"
    printf '  %-24s %s\n' "X11Forwarding"          "$H_X11"
    printf '  %-24s %s\n' "ClientAlive"            "$H_KEEP"
    echo "  File:                  $DROPIN"
    socket_activated && echo "  in addition:           $SOCKET_DROPIN" || true
    echo "========================================================="
}

# apply_hardening <mode: tailnet|public|plain> - writes the drop-in, opens the
# new port in ufw first (the old one stays open), restarts sshd. 1 on failure.
apply_hardening() {
    local mode=$1
    ensure_include
    mkdir -p "$DROPIN_DIR"

    # ufw first: the new port must be open BEFORE sshd moves there.
    if ufw_active; then
        if [[ "$mode" == tailnet ]]; then
            ufw allow in on tailscale0 to any port "$H_PORT" proto tcp comment 'SSH via tailnet' >/dev/null || true
        else
            ufw limit "${H_PORT}/tcp" comment 'SSH (rate-limited)' >/dev/null || true
        fi
    fi

    local had_dropin=0
    if [[ -f "$DROPIN" ]]; then had_dropin=1; cp "$DROPIN" "$DROPIN.prev"; fi
    {
        echo "# generated by ssh-setup.sh on $(date '+%F %T')"
        echo "Port ${H_PORT}"
        echo "PermitRootLogin ${H_ROOT}"
        echo "PasswordAuthentication ${H_PASS}"
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo "MaxAuthTries ${H_TRIES}"
        echo "LoginGraceTime ${H_GRACE}"
        echo "X11Forwarding ${H_X11}"
        if [[ "$H_KEEP" == "yes" ]]; then
            echo "ClientAliveInterval 300"
            echo "ClientAliveCountMax 2"
        fi
    } > "$DROPIN"
    chmod 644 "$DROPIN"

    if ! sshd_test >/dev/null; then
        echo "!!! sshd rejects the configuration:"
        sshd_test || true
        if (( had_dropin == 1 )); then mv "$DROPIN.prev" "$DROPIN"; else rm -f "$DROPIN"; fi
        echo "Rolled back, nothing was applied."
        return 1
    fi
    rm -f "$DROPIN.prev"

    # Does the drop-in actually arrive?
    local -a mismatch=()
    effective_matches port "$H_PORT"                     || mismatch+=(Port)
    effective_matches permitrootlogin "$H_ROOT"          || mismatch+=(PermitRootLogin)
    effective_matches passwordauthentication "$H_PASS"   || mismatch+=(PasswordAuthentication)
    if (( ${#mismatch[@]} > 0 )); then
        echo
        echo "!!! These settings do not arrive: ${mismatch[*]}"
        echo "!!! In $SSHD_CONF the directive sits above the include line,"
        echo "!!! and with sshd the one read first wins."
        if confirm "Comment out the conflicting lines there?" Y; then
            cp "$SSHD_CONF" "$SSHD_CONF.ssh-setup.bak"
            local k
            for k in "${mismatch[@]}"; do neutralize "$k"; done
            if ! sshd_test >/dev/null; then
                echo "!!! sshd rejects the result - rolled back."
                sshd_test || true
                mv "$SSHD_CONF.ssh-setup.bak" "$SSHD_CONF"
            fi
        else
            echo "The hardening stays incomplete then."
        fi
    fi

    if socket_activated; then
        mkdir -p "$SOCKET_DIR"
        printf '%s\n' "# generated by ssh-setup.sh" "[Socket]" "ListenStream=" "ListenStream=${H_PORT}" > "$SOCKET_DROPIN"
        systemctl daemon-reload
        systemctl restart ssh.socket || true
    fi
    restart_sshd || return 1
    f2b_sync_port "$H_PORT"
    echo ">>> Applied. sshd listens on: $(listening_port)"
}

# ---------------------------------------------------------------------------
# fail2ban (public access only)
# ---------------------------------------------------------------------------
# Bans an address after repeated failed logins. Worth it where SSH is open to
# the internet; over the tailnet nobody unknown gets that far. The journal is
# the source (backend systemd): Debian 12 has no /var/log/auth.log without
# rsyslog, and fail2ban's default would not even start there.
F2B_JAIL=/etc/fail2ban/jail.d/ssh-setup.local
# fail2ban-setup.sh may keep an sshd jail of its own (thresholds, ignoreip).
# fail2ban reads jail.d alphabetically and that file comes after ours, so its
# values win - its port therefore has to follow every port change made here,
# or the ban blocks a port nobody uses while the attacker keeps knocking.
F2B_OTHER_JAIL=/etc/fail2ban/jail.d/sshd-mmo.local

# f2b_sync_port <port> - sets the port in every sshd jail file that exists.
f2b_sync_port() {
    local port=$1 f changed=0
    for f in "$F2B_JAIL" "$F2B_OTHER_JAIL"; do
        [[ -f "$f" ]] || continue
        grep -qE "^port[[:space:]]*=[[:space:]]*${port}[[:space:]]*$" "$f" && continue
        sed -i -E "s/^port[[:space:]]*=.*/port     = ${port}/" "$f"
        changed=1
    done
    if (( changed == 1 )) && systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl restart fail2ban >/dev/null 2>&1 || true
        # The restart returns before the jails are loaded - wait for the answer.
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            fail2ban-client status sshd >/dev/null 2>&1 && break
            sleep 1
        done
        if fail2ban-client status sshd >/dev/null 2>&1; then
            echo "fail2ban: the sshd jail now watches port ${port}."
        else
            echo "!!! fail2ban: the sshd jail does not run - see: journalctl -u fail2ban -n 20"
        fi
    fi
    return 0
}

f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then echo "  fail2ban: not installed"; return 0; fi
    local banned
    banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[[:space:]]/,"",$2); print $2}' || true)
    echo "  fail2ban: $(systemctl is-active fail2ban 2>/dev/null || true), sshd jail$([[ -f "$F2B_JAIL" ]] && echo " (ssh-setup)")$([[ -f "$F2B_OTHER_JAIL" ]] && echo " (fail2ban-setup)"), banned now: ${banned:-?}"
}

setup_fail2ban() {
    local port; port=$(effective port); port=${port:-22}
    echo "fail2ban bans an address for 1 hour after 5 failed logins within 10"
    echo "minutes (port ${port}; the tailnet 100.64.0.0/10 is never banned)."
    if ! command -v fail2ban-client &>/dev/null; then
        echo ">>> Installing fail2ban..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q </dev/null fail2ban python3-systemd >/dev/null 2>&1 \
            || { echo "!!! fail2ban could not be installed."; return 1; }
    fi
    mkdir -p "$(dirname "$F2B_JAIL")"
    cat > "$F2B_JAIL" <<EOF
# written by ssh-setup.sh
[sshd]
enabled  = true
port     = ${port}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10
EOF
    if [[ -f "$F2B_OTHER_JAIL" ]]; then
        sed -i -E "s/^port[[:space:]]*=.*/port     = ${port}/" "$F2B_OTHER_JAIL"
        # Written by fail2ban-setup before 3.0.0 its jail had no ignoreip of its
        # own and relied on [DEFAULT] - which the jail-level line above now
        # beats. Carry its list over, or its networks would no longer count.
        local ign
        if ! grep -q '^ignoreip' "$F2B_OTHER_JAIL"; then
            ign=$(sed -n 's/^ignoreip[[:space:]]*=[[:space:]]*//p' /etc/fail2ban/jail.d/00-mmo-defaults.local 2>/dev/null | head -1)
            [[ -n "$ign" ]] && echo "ignoreip = ${ign}" >> "$F2B_OTHER_JAIL"
        fi
        echo "(fail2ban-setup's sshd jail is there as well - its thresholds and ignoreip apply.)"
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo "fail2ban active, jail 'sshd' watches port ${port}."
    else
        echo "!!! fail2ban does not run - see: journalctl -u fail2ban -n 20"
        return 1
    fi
}

# Only the hardening values (menu / --harden).
configure() {
    local cur_port; cur_port=$(effective port); cur_port=${cur_port:-22}
    echo ">>> SSH hardening values"
    check_presets || return 1
    ask_hardening "$(ssh_port_default keep "$cur_port")" "${DEFAULT_ROOTLOGIN_CHOICE:-1}" \
        "$(yn "${DEFAULT_PASSWORD_OFF:-}" Y)" || return 1
    show_hardening "$cur_port"
    echo "The new port is opened in ufw first; the old one stays open until you"
    echo "close it (menu) after a successful test."
    if hardening_preset; then
        echo "Apply like this? -> yes (all values preset)"
    else
        confirm "Apply like this?" "$( [[ -n "${BATCH:-}" ]] && echo Y || echo N)" \
            || { echo "Cancelled, nothing changed."; return 0; }
    fi
    apply_hardening plain || return 0
    echo "Now test in a SECOND terminal: ssh -p ${H_PORT} <user>@<this-server>"
    exposure_warning
}

# ---------------------------------------------------------------------------
# Guided access setup (--setup)
# ---------------------------------------------------------------------------
# Lock SSH to the tailnet: rule on tailscale0, check, test, then remove the
# public rules for the old and the new port.
lock_to_tailnet() {
    local port=$1 old=$2 tip
    tip=$(tailnet_ip)
    if ! ufw_active; then
        echo "!!! ufw is not active - SSH stays reachable from everywhere. Set up the"
        echo "!!! firewall first (ufw-manager.sh --setup), then run this again."
        return 1
    fi
    ufw allow in on tailscale0 to any port "$port" proto tcp comment 'SSH via tailnet' >/dev/null || true
    ensure_tailscale_ssh_off
    if ! sshd_answers "$tip" "$port"; then
        echo "!!! sshd does not answer on ${tip}:${port} (ssh-keyscan) - check"
        echo "!!! ListenAddress in $SSHD_CONF before going on."
    fi
    echo
    echo "!!! Test NOW in a SECOND terminal, from a tailnet machine:"
    echo "!!!     ssh -p ${port} root@${tip}"
    echo "!!! 'tailnet policy does not permit you to SSH' = Tailscale SSH is"
    echo "!!! still on: answer n and run 'tailscale set --ssh=false'."
    until confirm_tty "Does SSH over the tailnet (${tip}) work?"; do
        confirm_tty "Try again? (No: SSH stays publicly reachable)" Y             || { echo "SSH stays publicly reachable as well - nothing closed."; return 1; }
    done
    local ports=$port; [[ "$old" != "$port" ]] && ports="${port}|${old}"
    delete_public_ssh_rules "$ports"
    if [[ -n "$(public_ssh_rules "$ports")" ]]; then
        echo "!!! Rules still open SSH publicly - check 'ufw status numbered'."
    else
        echo "Public SSH rules removed - SSH is tailnet-only now."
    fi
    echo "!!! Verify once more in a NEW terminal before closing this session."
}

setup_access() {
    local cur_port tip mode def c
    cur_port=$(effective port); cur_port=${cur_port:-22}
    tip=$(tailnet_ip)
    echo ">>> Secure the SSH access"
    check_presets || return 1
    echo "sshd: port ${cur_port}, root login $(effective permitrootlogin), password login $(effective passwordauthentication)"
    echo "Keys on file for: $(users_with_keys | tr '\n' ' ')"
    echo "Tailnet: ${tip:-not connected}   ufw: $(ufw_active && echo active || echo "not active")"
    echo
    if preset DEFAULT_SSH_ACCESS; then
        # tailnet|public|keep -> menu choice 1|2|3 (checked in check_presets)
        case "$DEFAULT_SSH_ACCESS" in tailnet) c=1 ;; public) c=2 ;; *) c=3 ;; esac
        echo "Access: ${DEFAULT_SSH_ACCESS} (preset)"
    else
        echo "  1) only over the tailnet - port closed to the internet; root login"
        echo "     (also with password) is fine, the tailnet is the gate"
        echo "  2) public - a non-root admin with sudo and key, root and passwords"
        echo "     off, a port that does not look like SSH"
        echo "  3) leave it as it is - nothing is changed"
        def=2
        ask c "Choice" "$def" || return 1
    fi
    case "$c" in
        1) mode=tailnet ;;
        2) mode=public ;;
        *) echo "Left as it is, nothing changed."; exposure_warning; return 2 ;;
    esac

    if [[ "$mode" == tailnet && -z "$tip" ]]; then
        echo "This server is not in a tailnet yet."
        if [[ -x "$TS_SCRIPT" ]] && confirm "Join it now (tailscale-setup.sh)?" "$(yn "${DEFAULT_TS_JOIN:-}" Y)" DEFAULT_TS_JOIN; then
            "$TS_SCRIPT" --login || true
            tip=$(tailnet_ip)
        fi
        [[ -n "$tip" ]] || { echo "!!! No tailnet - choose 'public' or join the tailnet first."; return 1; }
    fi

    local rdef pwdef dport=$cur_port
    if [[ "$mode" == tailnet ]]; then
        ensure_tailscale_ssh_off
        echo
        if confirm "Additionally create a personal admin user with sudo and key?" "$(yn "${DEFAULT_CREATE_ADMIN:-}" N)" DEFAULT_CREATE_ADMIN; then
            create_admin_user || true
        fi
        dport=$(ssh_port_default keep "$cur_port")
        rdef=3; pwdef=N
    else
        echo
        create_admin_user || { echo "!!! Without an admin user nothing is changed."; return 1; }
        echo
        echo "!!! Test NOW in a SECOND terminal, while this session stays open:"
        echo "!!!     ssh -p ${cur_port} ${ADMIN_USER}@<server>   and then   sudo -v"
        until confirm_tty "Does the key login as '${ADMIN_USER}' work, including sudo?"; do
            confirm_tty "Try again? (No: nothing is changed)" Y                 || { echo "Login not confirmed - sshd and the firewall stay unchanged."; return 1; }
        done
        echo
        dport=$(ssh_port_default random "$cur_port")
        if ! preset DEFAULT_SSH_PORT; then
            echo "Port: scanners try 22 (and 222, 2222 ...) all day; a random port that"
            echo "does not look like SSH keeps the logs quiet. Suggested: ${dport}"
            echo "(type ${cur_port} to keep the current one)."
        fi
        rdef=2; pwdef=Y
    fi
    [[ -n "${DEFAULT_ROOTLOGIN_CHOICE:-}" ]] && rdef=$DEFAULT_ROOTLOGIN_CHOICE
    [[ -n "${DEFAULT_PASSWORD_OFF:-}" ]] && pwdef=$(yn "$DEFAULT_PASSWORD_OFF" "$pwdef")
    echo
    ask_hardening "$dport" "$rdef" "$pwdef" || return 1
    show_hardening "$cur_port"
    if hardening_preset; then
        echo "Apply like this? -> yes (all values preset)"
    else
        confirm "Apply like this?" Y || { echo "Cancelled, nothing changed."; return 0; }
    fi
    apply_hardening "$mode" || return 1

    if [[ "$mode" == tailnet ]]; then
        echo
        lock_to_tailnet "$H_PORT" "$cur_port" || echo "SSH lock to the tailnet NOT done."
    elif [[ "$H_PORT" != "$cur_port" ]]; then
        echo
        echo "!!! Test the NEW port in a SECOND terminal:"
        echo "!!!     ssh -p ${H_PORT} ${ADMIN_USER}@<server>"
        local ok=1
        until confirm_tty "Does the login on port ${H_PORT} work?"; do
            confirm_tty "Try again? (No: port ${cur_port} stays open as well)" Y || { ok=0; break; }
        done
        if (( ok == 1 )) && ufw_active; then
            delete_public_ssh_rules "$cur_port"
            echo "Port ${cur_port} closed in ufw; SSH is on ${H_PORT} only."
        elif (( ok == 0 )); then
            echo "Port ${cur_port} stays open in ufw as well - close it after a test: menu item 6."
        fi
    fi
    if [[ "$mode" == public ]]; then
        echo
        if [[ -f "$F2B_JAIL" ]]; then
            setup_fail2ban || true      # port may have changed
        elif confirm "Install fail2ban (bans an address after repeated failed logins)?" "$(yn "${DEFAULT_FAIL2BAN:-}" Y)" DEFAULT_FAIL2BAN; then
            setup_fail2ban || true
        fi
    fi
    exposure_warning
}

# Close an old SSH port in ufw (after the login on the new one worked).
close_old_port() {
    local p old; p=$(effective port); p=${p:-22}
    ufw_active || { echo "ufw is not active, there is nothing to close."; return 0; }
    read -rp "Which old port should be closed? [22]: " old; old=${old:-22}
    if [[ "$old" == "$p" ]]; then
        echo "sshd listens on ${p} itself - closing it would lock you out. Aborting."
        return 0
    fi
    [[ -n "$(public_ssh_rules "$old")" ]] || { echo "No public rule for ${old}."; return 0; }
    confirm "Close port ${old}/tcp now?" || { echo "Cancelled."; return 0; }
    delete_public_ssh_rules "$old"
    echo "Closed."
}

show_status() {
    echo "--- Effective settings (sshd -T) ---"
    local k
    for k in port permitrootlogin passwordauthentication pubkeyauthentication \
             kbdinteractiveauthentication maxauthtries logingracetime x11forwarding; do
        printf '  %-30s %s\n' "$k" "$(effective "$k")"
    done
    echo
    echo "--- Drop-in ---"
    if [[ -f "$DROPIN" ]]; then
        sed 's/^/  /' "$DROPIN"
    else
        echo "  (none - the values above are the distribution default)"
    fi
    echo
    echo "--- Socket activation ---"
    if socket_activated; then
        echo "  yes (ssh.socket)"
        [[ -f "$SOCKET_DROPIN" ]] && sed 's/^/  /' "$SOCKET_DROPIN" || echo "  (no port drop-in)"
    else
        echo "  no"
    fi
    echo
    echo "--- Keys on file for ---"
    local -a ku=(); mapfile -t ku < <(users_with_keys)
    if (( ${#ku[@]} == 0 )); then echo "  (nobody)"; else printf '  %s\n' "${ku[@]}"; fi
    echo
    echo "--- Listening ports ---"
    echo "  $(listening_port)"
    echo
    echo "--- fail2ban ---"
    f2b_status
    exposure_warning
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall SSH hardening"
    echo

    local p; p=$(effective port); p=${p:-22}

    echo "The following will be removed:"
    [[ -f "$DROPIN" ]]        && echo "  - $DROPIN"                                  || true
    [[ -f "$SOCKET_DROPIN" ]] && echo "  - $SOCKET_DROPIN (port on ssh.socket)"      || true
    [[ -f "$F2B_JAIL" ]]      && echo "  - $F2B_JAIL (fail2ban stays installed)"    || true
    grep -qF "$MARK_BEGIN" "$SSHD_CONF" 2>/dev/null \
        && echo "  - the include line added to $SSHD_CONF"                           || true
    grep -qE "$NEUTRAL_MATCH" "$SSHD_CONF" 2>/dev/null \
        && echo "  - commented-out lines in $SSHD_CONF are reactivated"              || true
    echo
    echo "After that the distribution default applies again: port 22, password"
    echo "login usually allowed. The keys on file stay untouched."
    echo
    echo "Order: port 22 is opened in ufw BEFORE sshd falls back to it."
    [[ "$p" != "22" ]] && echo "The rule for the current port ${p}/tcp stays in place." || true
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup ssh-setup "$DROPIN" "$SOCKET_DROPIN" "$SSHD_CONF" || { pause; return; }

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        echo "ufw: 22/tcp opened."
    fi

    local restore=""
    if [[ -f "$DROPIN" ]]; then cp "$DROPIN" "$DROPIN.prev"; restore="$DROPIN.prev"; fi
    rm -f "$DROPIN"
    if [[ -f "$F2B_JAIL" ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; fi

    if grep -qF "$MARK_BEGIN" "$SSHD_CONF" 2>/dev/null; then
        sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$SSHD_CONF"
    fi
    # '@' as the delimiter: the pattern itself contains '|' and '#'.
    sed -i -E "s@${NEUTRAL_MATCH}@@" "$SSHD_CONF"

    if ! sshd_test >/dev/null; then
        echo "!!! sshd rejects the configuration after the removal:"
        sshd_test || true
        [[ -n "$restore" ]] && mv "$restore" "$DROPIN"
        echo "Rolled back, nothing was removed."
        pause; return
    fi
    rm -f "$restore"

    if [[ -f "$SOCKET_DROPIN" ]]; then
        rm -f "$SOCKET_DROPIN"
        rmdir "$SOCKET_DIR" 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
    fi

    restart_sshd || true
    # fail2ban-setup's sshd jail stays - it has to follow the port fallback.
    local np; np=$(effective port); f2b_sync_port "${np:-22}"

    echo
    echo "Removed. sshd now listens on: $(listening_port)"
    echo "Test the connection over port 22 before you close the running session."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " SSH access"
        echo "==========================================="
        echo "Port:            $(effective port)"
        echo "Root login:      $(effective permitrootlogin)"
        echo "Password login:  $(effective passwordauthentication)"
        echo "Tailnet-only:    $( ufw_active && [[ -z "$(public_ssh_rules "$(effective port)")" ]] && echo yes || echo no)"
        echo "Drop-in:         $([[ -f "$DROPIN" ]] && echo "$DROPIN" || echo "(none)")"
        socket_activated && echo "Socket activation: yes" || true
        exposure_warning
        echo
        echo "1) Secure the access (guided: tailnet or public, admin, port, lock)"
        echo "2) Hardening values only"
        echo "3) Show status"
        echo "4) Store a public key"
        echo "5) Create an admin user (sudo + key)"
        echo "6) Close an old SSH port in ufw"
        echo "f) fail2ban (ban addresses after failed logins)"
        echo "7) Uninstall"
        echo "q) Quit"
        local CH; read -rp "Choice: " CH || exit 0
        case "$CH" in
            1) setup_access || true; pause ;;
            2) configure || true; pause ;;
            3) show_status; pause ;;
            4) add_key; pause ;;
            5) create_admin_user || true; pause ;;
            6) close_old_port; pause ;;
            f|F) setup_fail2ban || true; pause ;;
            7) uninstall ;;
            q|Q) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --setup)     setup_access ;;
    --harden)    configure ;;
    --status)    show_status ;;
    --add-key)   add_key ;;
    --fail2ban)  setup_fail2ban ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--setup|--harden|--status|--add-key|--fail2ban|--uninstall|--version]"; exit 1 ;;
esac
