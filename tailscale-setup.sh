#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tailscale-setup.sh - install, log in to and configure Tailscale
# Modes: (no argument) = interactive menu
#        --status      = status on stdout
#        --uninstall   = uninstall
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.2.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

SYSCTL_FILE=/etc/sysctl.d/99-tailscale.conf
REPO_LIST=/etc/apt/sources.list.d/tailscale.list
REPO_KEY=/usr/share/keyrings/tailscale-archive-keyring.gpg
IFACE=tailscale0

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
    if (( ${#existing[@]} == 0 )); then echo "(nothing to back up)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

installed()  { command -v tailscale &>/dev/null; }
logged_in()  { tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; }
tailnet_ip() { tailscale ip -4 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
install_tailscale() {
    installed && return 0

    echo ">>> Installing Tailscale from the official repo..."

    # shellcheck disable=SC1091
    . /etc/os-release
    local id=${ID:-debian} code=${VERSION_CODENAME:-}

    if [[ -z "$code" ]]; then
        echo "!!! /etc/os-release does not name a VERSION_CODENAME."
        read -rp "Codename of the distribution (e.g. bookworm, jammy): " code
        [[ -n "$code" ]] || return 1
    fi

    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg apt-transport-https >/dev/null

    if ! curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.noarmor.gpg" -o "$REPO_KEY"; then
        echo "!!! Key for ${id}/${code} cannot be fetched - is the codename right?"
        return 1
    fi
    curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.tailscale-keyring.list" -o "$REPO_LIST" || return 1

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale >/dev/null || return 1

    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    echo ">>> Installed: $(tailscale version 2>/dev/null | head -1)"
}

# IP forwarding is only needed when this node passes traffic on for others -
# that is, as a subnet router or exit node.
enable_forwarding() {
    cat > "$SYSCTL_FILE" <<'EOF'
# from tailscale-setup.sh - needed for subnet routers and exit nodes
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    echo "IP forwarding enabled ($SYSCTL_FILE)."
}

# ---------------------------------------------------------------------------
# Log in and configure
# ---------------------------------------------------------------------------
# The tags the node carries right now. Read from the daemon's own preferences,
# because they may come from an earlier run or from the auth key rather than
# from anything this script did.
#
# sed instead of jq: jq is not installed on a fresh server, and a tag list
# cannot contain quotes, commas or brackets, so the parse is safe here even
# though it would not be in general.
current_tags() {
    tailscale debug prefs 2>/dev/null \
        | tr -d ' \n' \
        | sed -n 's/.*"AdvertiseTags":\[\([^]]*\)\].*/\1/p' \
        | tr -d '"'
}

# 'tailscale up' resets options you do NOT pass to their default and demands
# --reset for that. So all managed flags are always asked for together and set
# together here.
build_up_args() {
    UP_ARGS=()
    local host ssh exitnode routes acceptroutes acceptdns shields tags

    read -rp "Hostname in the tailnet [$(hostname -s)]: " host
    UP_ARGS+=("--hostname=${host:-$(hostname -s)}")

    echo
    echo "Tailscale SSH: login over the tailnet, access governed centrally by the"
    echo "ACLs. The regular sshd is not affected by it."
    if confirm "Enable Tailscale SSH?" N; then ssh=1; else ssh=0; fi
    (( ssh == 1 )) && UP_ARGS+=(--ssh) || UP_ARGS+=(--ssh=false)

    echo
    if confirm "Offer local subnets to other nodes (subnet router)?" N; then
        read -rp "  Subnets, comma-separated (e.g. 192.168.1.0/24): " routes
        [[ -n "$routes" ]] && UP_ARGS+=("--advertise-routes=${routes}")
    fi

    if confirm "Offer this server as an exit node?" N; then
        exitnode=1
        UP_ARGS+=(--advertise-exit-node)
    fi

    echo
    if confirm "Accept subnets offered by others (--accept-routes)?" N; then
        acceptroutes=1; UP_ARGS+=(--accept-routes)
    else
        UP_ARGS+=(--accept-routes=false)
    fi

    echo
    echo "MagicDNS writes the Tailscale nameservers into /etc/resolv.conf. On a"
    echo "server with its own DNS configuration you often do not want that."
    if confirm "Take over MagicDNS/DNS settings?" N; then
        acceptdns=1; UP_ARGS+=(--accept-dns)
    else
        UP_ARGS+=(--accept-dns=false)
    fi

    echo
    echo "Shields up: this node accepts NO incoming connections from the tailnet,"
    echo "but can still reach out itself."
    if confirm "Enable shields up?" N; then shields=1; UP_ARGS+=(--shields-up); fi

    # Tags have to be repeated on every 'tailscale up' - they are a property of
    # the call, not something the daemon remembers on your behalf. Leaving the
    # question empty on a tagged node is therefore the classic way to get the
    # "requires mentioning all non-default flags" refusal, so the current value
    # is offered as the default instead of an empty field.
    echo
    local curtags; curtags=$(current_tags)
    if [[ -n "$curtags" ]]; then
        echo "This node currently carries: ${curtags}"
        echo "Tags have to be given again on every login - leaving this empty"
        echo "keeps them. Enter '-' to remove them."
        read -rp "Tags [${curtags}]: " tags
        if [[ "$tags" == "-" ]]; then tags=""; else tags=${tags:-$curtags}; fi
    else
        read -rp "Tags (e.g. tag:server, empty = none): " tags
    fi
    [[ -n "$tags" ]] && UP_ARGS+=("--advertise-tags=${tags}")

    if [[ -n "${routes:-}" || "${exitnode:-0}" == "1" ]]; then
        echo
        enable_forwarding
    fi
}

run_up() {
    local -a extra=("$@")
    local reset_tried=0 a
    for a in ${extra[@]+"${extra[@]}"}; do
        [[ "$a" == "--reset" ]] && reset_tried=1
    done

    echo
    echo "This will be run:"
    printf '    tailscale up'; printf ' %q' "${UP_ARGS[@]}" ${extra[@]+"${extra[@]}"}; echo
    echo
    confirm "Run it?" Y || { echo "Cancelled."; return 1; }

    # The output is shown live *and* captured. Swallowing it into a variable
    # would hide the very thing an interactive login is about: 'tailscale up'
    # prints the URL to open and then waits. Hence tee.
    local logf rc=0
    logf=$(mktemp)
    tailscale up "${UP_ARGS[@]}" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$logf" || rc=$?

    if (( rc == 0 )); then
        rm -f "$logf"
        echo
        echo ">>> Connected. Tailnet IP: $(tailnet_ip)"
        return 0
    fi

    # 'tailscale up' refuses the whole call when the node currently carries a
    # non-default setting that is not mentioned again - a tag from an earlier
    # run or from the auth key is the usual case, and it is not something the
    # questions above ask about. Offering --reset right here matters: at this
    # point the auth key that was just typed in is still available, whereas
    # sending the user off to another menu item means typing it again.
    if (( reset_tried == 0 )) && grep -q -- '--reset' "$logf"; then
        rm -f "$logf"
        echo
        echo "!!! Tailscale refuses this call: the node still carries settings that"
        echo "!!! were not asked for above - a tag from an earlier login, for"
        echo "!!! instance. Tailscale wants every non-default setting mentioned."
        echo
        echo "--reset applies exactly what was asked for here and returns"
        echo "everything else to its default. If you need to keep a tag, answer"
        echo "no and enter it at the tag question on the next run."
        echo
        if confirm "Run again with --reset?" Y; then
            run_up ${extra[@]+"${extra[@]}"} --reset
            return $?
        fi
        echo "Cancelled - nothing was changed."
        return 1
    fi

    rm -f "$logf"
    echo
    echo "!!! 'tailscale up' was not successful."
    return 1
}

first_setup() {
    install_tailscale || { echo "!!! Installation failed."; pause; return; }

    echo
    echo "Login:"
    echo "  1) interactive - Tailscale shows a URL to open in a browser"
    echo "  2) with an auth key from the admin console (tskey-auth-...)"
    local M; read -rp "Choice [1]: " M

    build_up_args

    if [[ "${M:-1}" == "2" ]]; then
        local key kf
        read -rsp "Auth key: " key; echo
        if [[ -z "$key" ]]; then echo "No key given."; pause; return; fi
        # Through a file rather than the command line: otherwise the key would
        # show up in the process list.
        kf=$(mktemp); chmod 600 "$kf"; printf '%s' "$key" > "$kf"
        # The file is deleted again as soon as 'tailscale up' has read it - a
        # valid auth key must not stay behind in /tmp, and a Ctrl-C in the
        # middle of the login must not leave one there either.
        trap 'rm -f "$kf"; echo; echo "(auth key file removed)"; exit 130' INT TERM
        run_up "--auth-key=file:${kf}" || true
        rm -f "$kf"
        trap - INT TERM
    else
        echo
        echo "A URL will appear shortly. Open it in a browser and approve the node"
        echo "- after that things continue here."
        run_up || true
    fi
    pause
}

change_settings() {
    installed || { echo "Tailscale is not installed."; pause; return; }
    build_up_args
    echo
    echo "Note: --reset returns every option not asked for here to its default."
    local -a extra=()
    confirm "Run with --reset?" Y && extra=(--reset)
    run_up "${extra[@]}" || true
    pause
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
firewall_rule() {
    if ! command -v ufw &>/dev/null; then
        echo "ufw is not installed - there is nothing to configure here."
        pause; return
    fi

    echo "With a rule on interface ${IFACE}, nodes from the tailnet can reach"
    echo "services on this server without any port being publicly open."
    echo
    echo "Existing rules for ${IFACE}:"
    ufw status 2>/dev/null | grep -E "on ${IFACE}" || echo "  (none)"
    echo
    echo "1) Allow all traffic from the tailnet  (allow in on ${IFACE})"
    echo "2) Allow one specific port only"
    echo "3) Back"
    local CH; read -rp "Choice: " CH
    case "$CH" in
        1)
            confirm "Run ufw allow in on ${IFACE}?" Y \
                && ufw allow in on "$IFACE" comment 'Tailnet' || true
            ;;
        2)
            local p
            read -rp "Port: " p
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Not a number."; pause; return; }
            confirm "Run ufw allow in on ${IFACE} to any port ${p} proto tcp?" Y \
                && ufw allow in on "$IFACE" to any port "$p" proto tcp comment 'Tailnet' || true
            ;;
        *) return ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    if ! installed; then
        echo "Tailscale is not installed."
        return
    fi
    echo "--- Version ---"
    tailscale version 2>/dev/null | sed 's/^/  /'
    echo
    echo "--- Service ---"
    printf '  tailscaled: %s\n' "$(systemctl is-active tailscaled 2>/dev/null || echo '-')"
    printf '  login:      %s\n' "$(logged_in && echo 'logged in' || echo 'not logged in')"
    printf '  tailnet IP: %s\n' "$(tailnet_ip || echo '-')"
    echo
    echo "--- Nodes in the tailnet ---"
    tailscale status 2>/dev/null | sed 's/^/  /' || echo "  (no output)"
    echo
    echo "--- IP forwarding ---"
    if [[ -f "$SYSCTL_FILE" ]]; then
        echo "  enabled through $SYSCTL_FILE"
    else
        echo "  not set by this tool (currently: $(sysctl -n net.ipv4.ip_forward 2>/dev/null))"
    fi
}

do_logout() {
    echo "Logs the node out of the tailnet. The software stays installed."
    echo
    echo "!!! If you reach this server only over Tailscale, you are cutting off"
    echo "!!! your own connection."
    echo
    confirm "Really log out?" || { echo "Cancelled."; pause; return; }
    tailscale logout || true
    tailscale down 2>/dev/null || true
    echo "Logged out."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall Tailscale"
    echo

    if ! installed; then
        echo "Tailscale is not installed."
        [[ -f "$SYSCTL_FILE" ]] || { pause; return; }
    fi

    echo "The following will be removed:"
    logged_in            && echo "  - logout from the tailnet (tailscale logout)"
    installed            && echo "  - the tailscaled service is stopped and disabled"
    [[ -f "$SYSCTL_FILE" ]] && echo "  - $SYSCTL_FILE (IP forwarding)"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}" \
        && echo "  - ufw rules for ${IFACE}                            [asked]"
    echo
    echo "The package stays installed, and so does the state under /var/lib/tailscale."
    echo "To remove it completely:"
    echo "    apt purge tailscale && rm -rf /var/lib/tailscale \\"
    echo "        ${REPO_LIST} ${REPO_KEY}"
    echo
    echo "!!! The node stays registered in the admin console and has to be deleted"
    echo "!!! there separately."
    echo
    echo "!!! If you reach this server only over Tailscale, you are cutting off"
    echo "!!! your own connection."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup tailscale "$SYSCTL_FILE" /var/lib/tailscale || { pause; return; }

    if installed; then
        tailscale logout 2>/dev/null || true
        tailscale down 2>/dev/null || true
        systemctl stop tailscaled    >/dev/null 2>&1 || true
        systemctl disable tailscaled >/dev/null 2>&1 || true
    fi

    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        # Do not blindly set it back to 0: other services (Docker, WireGuard
        # routing) may need forwarding as well.
        echo "$SYSCTL_FILE removed. IP forwarding stays active until the next"
        echo "reboot; other services may need it too."
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}"; then
        if confirm "Remove the ufw rules for ${IFACE}?" Y; then
            # Delete from the back, so the numbers do not shift.
            local n
            for n in $(ufw status numbered 2>/dev/null | grep "on ${IFACE}" \
                       | grep -oE '^\[[ ]*[0-9]+\]' | grep -oE '[0-9]+' | sort -rn); do
                ufw --force delete "$n" >/dev/null 2>&1 || true
            done
            echo "Removed."
        fi
    fi

    echo
    echo "Done."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Tailscale"
        echo "==========================================="
        if installed; then
            echo "Version:    $(tailscale version 2>/dev/null | head -1)"
            echo "tailscaled: $(systemctl is-active tailscaled 2>/dev/null || echo '-')"
            if logged_in; then
                echo "Status:     logged in, IP $(tailnet_ip)"
            else
                echo "Status:     not logged in"
            fi
        else
            echo "Status: not installed"
        fi
        echo
        echo "1) Install and log in"
        echo "2) Show status"
        echo "3) Change settings (SSH, routes, exit node, DNS)"
        echo "4) Firewall: allow access over the tailnet"
        echo "5) Log out"
        echo "6) Uninstall"
        echo "7) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) first_setup ;;
            2) show_status; pause ;;
            3) change_settings ;;
            4) firewall_rule ;;
            5) do_logout ;;
            6) uninstall ;;
            7) exit 0 ;;
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
