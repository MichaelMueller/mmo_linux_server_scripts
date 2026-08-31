#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ssh-setup.sh - SSH hardening via a drop-in, with protection against lockout
# Modes: (no argument) = interactive menu
#        --status      = effective settings on stdout
#        --uninstall   = uninstall
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.3.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

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
    "$SSHD_BIN" -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'
}

is_setup() { [[ -f "$DROPIN" ]]; }

# With sshd the directive read FIRST wins. So if sshd_config already has
# 'PasswordAuthentication yes' above the include line, the drop-in has no
# effect - and you usually notice that only when it is too late.
effective_matches() {
    local got; got=$(effective "$1")
    [[ "${got,,}" == "${2,,}" ]]
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

# ---------------------------------------------------------------------------
# Public keys
# ---------------------------------------------------------------------------
add_key() {
    local u
    read -rp "For which user? [root]: " u; u=${u:-root}
    if ! id "$u" &>/dev/null; then
        echo "User '$u' does not exist."; pause; return
    fi

    local home
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || { echo "No home directory for '$u'."; pause; return; }

    echo "Paste the public key (one line, starts with ssh-ed25519 / ssh-rsa / ecdsa-):"
    local key; read -r key
    if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        echo "That does not look like a public key. Cancelled."
        pause; return
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
    pause
}

# ---------------------------------------------------------------------------
# Hardening
# ---------------------------------------------------------------------------
configure() {
    local cur_port cur_root cur_pass cur_tries cur_grace
    cur_port=$(effective port);                 cur_port=${cur_port:-22}
    cur_root=$(effective permitrootlogin);      cur_root=${cur_root:-prohibit-password}
    cur_pass=$(effective passwordauthentication); cur_pass=${cur_pass:-yes}
    cur_tries=$(effective maxauthtries);        cur_tries=${cur_tries:-6}
    cur_grace=$(effective logingracetime);      cur_grace=${cur_grace:-120}

    local -a keyusers=()
    mapfile -t keyusers < <(users_with_keys)

    echo ">>> SSH hardening"
    echo
    echo "Everything is asked first, then a summary is shown, then you confirm"
    echo "once. Nothing is touched before that."
    echo
    if (( ${#keyusers[@]} > 0 )); then
        echo "Keys on file for: ${keyusers[*]}"
    else
        echo "!!! No user has an authorized_keys on file."
    fi
    socket_activated && echo "Note: sshd runs through socket activation (ssh.socket)." || true
    echo

    # --- Port
    local PORT
    read -rp "SSH port [${cur_port}]: " PORT; PORT=${PORT:-$cur_port}
    while [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); do
        read -rp "  -> number between 1 and 65535: " PORT
    done

    # --- Root login
    echo
    echo "Root login:"
    echo "  1) key only (prohibit-password)"
    echo "  2) forbid entirely (no)"
    echo "  3) allow with password too (yes)"
    local R ROOTLOGIN
    read -rp "Choice [1]: " R
    case "${R:-1}" in
        2) ROOTLOGIN="no" ;;
        3) ROOTLOGIN="yes" ;;
        *) ROOTLOGIN="prohibit-password" ;;
    esac

    # --- Password login
    echo
    local PASSAUTH="yes"
    if (( ${#keyusers[@]} == 0 )); then
        echo "Password login stays on - without a key on file, switching it off"
        echo "would be a guaranteed lockout. Use menu item 3 first."
    else
        if confirm "Switch password login off (keys only)?" Y; then
            PASSAUTH="no"
        fi
    fi

    if [[ "$ROOTLOGIN" == "no" && "$PASSAUTH" == "no" ]]; then
        local -a nonroot=()
        local u
        for u in "${keyusers[@]}"; do [[ "$u" != root ]] && nonroot+=("$u"); done
        if (( ${#nonroot[@]} == 0 )); then
            echo
            echo "!!! Root login forbidden and passwords off, but only root has a"
            echo "!!! key - nobody would get in any more. Root login is set to"
            echo "!!! 'prohibit-password'."
            ROOTLOGIN="prohibit-password"
        fi
    fi

    # --- Odds and ends
    echo
    local TRIES GRACE
    read -rp "MaxAuthTries [${cur_tries}]: " TRIES; TRIES=${TRIES:-$cur_tries}
    read -rp "LoginGraceTime in seconds [${cur_grace}]: " GRACE; GRACE=${GRACE:-$cur_grace}

    local X11="no" KEEPALIVE="yes"
    confirm "Allow X11 forwarding?" N && X11="yes" || true
    confirm "Drop dead sessions after ~10 min (ClientAlive)?" Y || KEEPALIVE="no"

    # --- Summary
    echo
    echo "======================= Summary ========================="
    printf '  %-24s %s\n' "Port"                 "$PORT$( [[ "$PORT" != "$cur_port" ]] && echo "   (was $cur_port)" )"
    printf '  %-24s %s\n' "PermitRootLogin"      "$ROOTLOGIN"
    printf '  %-24s %s\n' "PasswordAuthentication" "$PASSAUTH"
    printf '  %-24s %s\n' "PubkeyAuthentication" "yes"
    printf '  %-24s %s\n' "MaxAuthTries"         "$TRIES"
    printf '  %-24s %s\n' "LoginGraceTime"       "$GRACE"
    printf '  %-24s %s\n' "X11Forwarding"        "$X11"
    printf '  %-24s %s\n' "ClientAlive"          "$KEEPALIVE"
    echo "  File:                  $DROPIN"
    socket_activated && echo "  in addition:           $SOCKET_DROPIN" || true
    echo "========================================================="
    echo
    echo "Order: the new port is opened in ufw first, then sshd moves there."
    echo "Port 22 stays open alongside it for now."
    echo
    echo "!!! Keep a second SSH session open now and close it only once logging"
    echo "!!! in over the new port has worked."
    echo

    confirm "Apply like this?" || { echo "Cancelled, nothing changed."; pause; return; }

    # --- Apply
    ensure_include
    mkdir -p "$DROPIN_DIR"

    # ufw first: the new port must be open BEFORE sshd moves there.
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ">>> ufw: opening port ${PORT}/tcp (22 stays open for now)"
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow 22/tcp        >/dev/null 2>&1 || true
    fi

    local had_dropin=0
    if [[ -f "$DROPIN" ]]; then had_dropin=1; cp "$DROPIN" "$DROPIN.prev"; fi

    {
        echo "# generated by ssh-setup.sh on $(date '+%F %T')"
        echo "Port ${PORT}"
        echo "PermitRootLogin ${ROOTLOGIN}"
        echo "PasswordAuthentication ${PASSAUTH}"
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo "MaxAuthTries ${TRIES}"
        echo "LoginGraceTime ${GRACE}"
        echo "X11Forwarding ${X11}"
        if [[ "$KEEPALIVE" == "yes" ]]; then
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
        pause; return
    fi
    rm -f "$DROPIN.prev"

    # Does the drop-in actually arrive?
    local -a mismatch=()
    effective_matches port "$PORT"                    || mismatch+=(Port)
    effective_matches permitrootlogin "$ROOTLOGIN"    || mismatch+=(PermitRootLogin)
    effective_matches passwordauthentication "$PASSAUTH" || mismatch+=(PasswordAuthentication)

    if (( ${#mismatch[@]} > 0 )); then
        echo
        echo "!!! These settings do not arrive: ${mismatch[*]}"
        echo "!!! In $SSHD_CONF the directive sits above the include line,"
        echo "!!! and with sshd the one read first wins."
        echo
        if confirm "Comment out the conflicting lines there?" Y; then
            cp "$SSHD_CONF" "$SSHD_CONF.ssh-setup.bak"
            local k
            for k in "${mismatch[@]}"; do neutralize "$k"; done
            if ! sshd_test >/dev/null; then
                echo "!!! sshd rejects the result - rolled back."
                sshd_test || true
                mv "$SSHD_CONF.ssh-setup.bak" "$SSHD_CONF"
            else
                echo "Done."
            fi
        else
            echo "The hardening stays incomplete then."
        fi
    fi

    if socket_activated; then
        mkdir -p "$SOCKET_DIR"
        {
            echo "# generated by ssh-setup.sh"
            echo "[Socket]"
            echo "ListenStream="
            echo "ListenStream=${PORT}"
        } > "$SOCKET_DROPIN"
        systemctl daemon-reload
        systemctl restart ssh.socket || true
    fi

    restart_sshd || true

    echo
    echo ">>> Applied. Open ports according to ss: $(listening_port)"
    echo
    echo "Now test in a SECOND terminal:"
    echo "    ssh -p ${PORT} <user>@<this-server>"
    echo
    echo "Only once that works, close port 22 - menu item 4 does that."
    pause
}

close_22() {
    echo "Closes port 22 in ufw. That is only right once logging in over the new"
    echo "port has demonstrably worked."
    echo
    local p; p=$(effective port); p=${p:-22}
    if [[ "$p" == "22" ]]; then
        echo "sshd listens on 22 itself - closing it would lock you out. Aborting."
        pause; return
    fi
    echo "sshd listens on port ${p}."
    if ! command -v ufw &>/dev/null || ! ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw is not active, there is nothing to close."
        pause; return
    fi
    confirm "Close port 22/tcp now?" || { echo "Cancelled."; pause; return; }
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    echo "Closed."
    pause
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
        clear
        echo "==========================================="
        echo " SSH hardening"
        echo "==========================================="
        echo "Port:            $(effective port)"
        echo "Root login:      $(effective permitrootlogin)"
        echo "Password login:  $(effective passwordauthentication)"
        echo "Drop-in:         $([[ -f "$DROPIN" ]] && echo "$DROPIN" || echo "(none)")"
        socket_activated && echo "Socket activation: yes" || true
        echo
        echo "1) Set up / change settings"
        echo "2) Show status"
        echo "3) Store a public key"
        echo "4) Close port 22 in ufw (after a successful test)"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) configure ;;
            2) show_status; pause ;;
            3) add_key ;;
            4) close_22 ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
