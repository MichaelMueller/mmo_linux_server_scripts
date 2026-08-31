#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# root-password.sh - set the root password, generated or typed
# Modes: (no argument) = interactive menu
#        --status      = state of the root account on stdout
#
# There is no --uninstall: a password is not something that can be "removed
# again". What the tool does is change the account, and the way back is to set
# another password.
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.3.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# Generating
# ---------------------------------------------------------------------------
# Letters and digits only, deliberately. A password with shell metacharacters
# in it gets mangled sooner or later - in a copy-paste, in a config file, in a
# provider's web console - and 24 alphanumeric characters are around 140 bits,
# which is far beyond anything that gets brute-forced.
#
# 'head' closing the pipe sends SIGPIPE to 'tr'; under 'pipefail' that would be
# a failed pipeline. Hence the subshell with pipefail switched off.
gen_password() {
    local len=${1:-24}
    ( set +o pipefail
      LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len" )
}

root_state() {
    # passwd -S: the second field is L (locked), NP (no password) or P (set).
    local s
    s=$(passwd -S root 2>/dev/null | awk '{print $2}') || true
    case "${s:-}" in
        L)  echo "locked (no password login as root)" ;;
        NP) echo "!!! NO PASSWORD - anyone at the console is root" ;;
        P)  echo "set" ;;
        *)  echo "unknown" ;;
    esac
}

last_change() {
    local d
    d=$(passwd -S root 2>/dev/null | awk '{print $3}') || true
    [[ -n "${d:-}" ]] && echo "$d" || echo "-"
}

ssh_root_login() {
    local v
    v=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}') || true
    echo "${v:-unknown}"
}

show_status() {
    echo "Root password: $(root_state)"
    echo "Last changed:  $(last_change)"
    echo "SSH root login: $(ssh_root_login)"
}

# ---------------------------------------------------------------------------
# Setting
# ---------------------------------------------------------------------------
# chpasswd reads from stdin, so the password never appears in the process list
# - unlike 'passwd' driven by an echo, and unlike anything passed as an
# argument, which every user on the machine could read out of /proc.
set_password() {
    local pw=$1
    if chpasswd <<<"root:${pw}"; then
        echo "Root password changed."
        return 0
    fi
    echo "!!! Changing it failed." >&2
    return 1
}

generate_and_set() {
    local len pw
    read -rp "Length [24]: " len; len=${len:-24}
    while [[ ! "$len" =~ ^[0-9]+$ ]] || (( len < 12 )); do
        echo "  -> a number, at least 12."
        read -rp "Length [24]: " len; len=${len:-24}
    done

    pw=$(gen_password "$len")
    if [[ ${#pw} -ne $len ]]; then
        echo "!!! Could not generate a password (is /dev/urandom readable?)."
        pause; return
    fi

    echo
    echo "==========================================================="
    echo "  ${pw}"
    echo "==========================================================="
    echo
    echo "!!! Write it down NOW, into a password manager. It is not stored"
    echo "!!! anywhere and cannot be shown again."
    echo "!!! It is on your screen and in the scrollback of this session."
    echo

    if ! confirm "Set this password for root now?" Y; then
        echo "Cancelled - the old password stays."
        pause; return
    fi

    set_password "$pw" || { pause; return; }
    echo
    echo "Test it in a SECOND terminal before closing this one:  su - root"
    pause
}

type_and_set() {
    local p1 p2
    echo "The input stays invisible."
    read -rsp "New root password: " p1; echo
    if (( ${#p1} < 8 )); then
        echo "!!! Shorter than 8 characters - not accepted."
        pause; return
    fi
    read -rsp "Repeat: " p2; echo
    if [[ "$p1" != "$p2" ]]; then
        echo "!!! The two do not match - nothing changed."
        pause; return
    fi

    set_password "$p1" || { pause; return; }
    echo
    echo "Test it in a SECOND terminal before closing this one:  su - root"
    pause
}

# Locking is not the same as "no password": the account stays, its password
# just can no longer be used. Anyone with sudo remains able to become root, and
# 'sudo -i' keeps working - which is exactly the usual setup on a server.
lock_root() {
    echo "Locking prevents logging in AS root with a password. What keeps"
    echo "working: sudo, key-based logins, and the console in single-user mode."
    echo
    echo "Only do this while a sudo-capable user with a working login exists -"
    echo "otherwise nobody gets in any more except through the provider's"
    echo "rescue system."
    echo

    if ! id -nG 2>/dev/null | grep -qw sudo && [[ "$(ssh_root_login)" == "no" ]]; then
        echo "!!! Careful: SSH root login is 'no' already. Make sure another"
        echo "!!! account can log in and use sudo."
        echo
    fi

    confirm "Really lock the root password?" || { echo "Cancelled."; pause; return; }
    passwd -l root >/dev/null && echo "Root password locked." || echo "!!! Failed."
    pause
}

unlock_root() {
    confirm "Unlock the root password again?" || { echo "Cancelled."; pause; return; }
    passwd -u root >/dev/null 2>&1 \
        && echo "Unlocked." \
        || echo "!!! Failed - an account with no password at all cannot be unlocked; set one first."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Root password"
        echo "==========================================="
        show_status
        echo
        echo "1) Generate a password and set it"
        echo "2) Type a password and set it"
        echo "3) Lock the root password"
        echo "4) Unlock the root password"
        echo "5) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) generate_and_set ;;
            2) type_and_set ;;
            3) lock_root ;;
            4) unlock_root ;;
            5) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status) show_status ;;
    "")       main_menu ;;
    *)        echo "Usage: $0 [--status|--version]"; exit 1 ;;
esac
