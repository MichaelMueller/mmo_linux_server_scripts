#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# setup-wizard.sh - guided first setup: tools -> secure SSH -> operations
#
# The counterpart of setup.sh for the first hour on a fresh server: setup.sh is
# the toolbox where every module is one menu entry, this wizard walks the same
# modules in a safe order. The core is step 2: SSH is hardened and then locked
# to a VPN tunnel, and nothing is closed before a login over the tunnel has
# demonstrably worked - the current session stays open the whole time.
#
# Everything already installed is detected and only re-run on request; every
# step can be skipped. The modules stay usable on their own afterwards.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.1.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_SCRIPT="$DIR/base-tools.sh"
SSH_SCRIPT="$DIR/ssh-setup.sh"
MAIL_SCRIPT="$DIR/mail-setup.sh"
GRAPH_SCRIPT="$DIR/graph-mailer.sh"
UPDATE_SCRIPT="$DIR/auto-update.sh"
WG_SCRIPT="$DIR/wg-manager.sh"
TS_SCRIPT="$DIR/tailscale-setup.sh"
DISK_SCRIPT="$DIR/disk-monitor.sh"
CLAM_SCRIPT="$DIR/clamav-scanner.sh"

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

banner() {
    echo
    echo "==========================================="
    echo " $1"
    echo "==========================================="
}

run() {
    local script=$1 name=$2; shift 2
    if [[ ! -f "$script" ]]; then
        echo "Script not found: $script"
        return 1
    fi
    [[ -x "$script" ]] || chmod +x "$script"
    "$script" "$@" || { echo "($name exited with an error)"; return 1; }
}

# summary: one "step|status|note" line per entry
declare -a SUMMARY=()
note() { SUMMARY+=("$1|$2|${3:-}"); }

# Asks whether to run a component, aware of what is already there: installed
# defaults to No ("run again anyway?"), missing defaults to Yes.
confirm_install() {
    local label=$1 question=$2 installed=$3
    if [[ "$installed" == "1" ]]; then
        echo "${label} is already set up."
        confirm "Run the ${label} setup again anyway?"
    else
        confirm "$question" Y
    fi
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------
check_os() {
    local id="" ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id=${ID:-}
        ver=${VERSION_ID:-}
        echo "OS: ${PRETTY_NAME:-unknown}"
    else
        echo "OS: unknown (/etc/os-release missing)"
    fi

    if [[ "$id" != "ubuntu" ]]; then
        echo "!!! These scripts target Ubuntu; this is '${id:-unknown}'."
        confirm "Continue anyway, at your own risk?" || return 1
        return 0
    fi

    # dpkg does version comparison right; 24.04 is where the scripts are tested
    if dpkg --compare-versions "${ver:-0}" lt "24.04"; then
        echo "!!! Ubuntu ${ver} is older than 24.04 - the scripts are not tested there."
        confirm "Continue anyway?" || return 1
    fi
    return 0
}

ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}')
    echo "${p:-22}"
}

tailscale_ip() { tailscale ip -4 2>/dev/null | head -1; }

wg_server_ip() {
    local f
    for f in /etc/wireguard/wg0-interface.conf /etc/wireguard/wg0.conf; do
        [[ -f "$f" ]] || continue
        awk -F'= *' '/^Address/ {gsub(/ /,"",$2); sub(/\/.*/,"",$2); print $2; exit}' "$f"
        return 0
    done
}

wg_listen_port() {
    local f
    for f in /etc/wireguard/wg0-interface.conf /etc/wireguard/wg0.conf; do
        [[ -f "$f" ]] || continue
        awk -F'= *' '/^ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "$f"
        return 0
    done
}

# ---------------------------------------------------------------------------
# Step 1: Base tools
# ---------------------------------------------------------------------------
step_tools() {
    banner "Step 1 of 4: Base tools"
    if confirm "Install the base tools (nano, vim, screen, coloured shell)?" Y; then
        if run "$BASE_SCRIPT" "base-tools"; then
            note "Base tools" "done"
        else
            note "Base tools" "FAILED"
        fi
    else
        note "Base tools" "skipped"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Secure SSH
# ---------------------------------------------------------------------------
step_ssh() {
    banner "Step 2 of 4: Secure the SSH access"

    # --- 2a: harden sshd first; nothing is blocked yet ---------------------
    local hardened=0
    [[ -f /etc/ssh/sshd_config.d/99-ssh-setup.conf ]] && hardened=1
    if confirm_install "SSH hardening" \
        "Harden SSH now (keys instead of passwords, no root login)?" "$hardened"; then
        echo
        echo "In the ssh-setup menu: deposit your public key, TEST a key login"
        echo "from a second terminal, and only then switch passwords off - the"
        echo "script guides you through exactly that order."
        pause
        if run "$SSH_SCRIPT" "ssh-setup"; then
            note "SSH hardening" "done"
        else
            note "SSH hardening" "FAILED"
        fi
    else
        [[ "$hardened" == "1" ]] && note "SSH hardening" "skipped" "already set up" \
                                 || note "SSH hardening" "skipped"
    fi

    # --- 2b: choose the tunnel ----------------------------------------------
    echo
    echo "SSH is the admin channel AND the thing being protected - the only"
    echo "fallback if this goes wrong is your provider's console. Keep it at"
    echo "hand before continuing."
    echo
    echo "1) Tailscale   (mesh VPN, no open inbound port needed)"
    echo "2) WireGuard   (own server, one open UDP port)"
    echo "3) No tunnel   (SSH stays public: hardened + rate limit)"
    local choice tun_if="" tun_ip="" tun_label=""
    read -rp "Protect SSH via [1]: " choice; choice=${choice:-1}

    case "$choice" in
        1)
            tun_label="Tailscale"; tun_if="tailscale0"
            tun_ip=$(tailscale_ip)
            if [[ -n "$tun_ip" ]] && ! confirm "Tailscale is already connected (${tun_ip}). Run the setup again anyway?"; then
                :
            else
                run "$TS_SCRIPT" "tailscale-setup" || { note "SSH via Tailscale" "FAILED" "tunnel setup"; return; }
                tun_ip=$(tailscale_ip)
            fi
            if [[ -z "$tun_ip" ]]; then
                echo "!!! Tailscale has no IPv4 - SSH stays as it is, nothing was blocked."
                note "SSH via Tailscale" "FAILED" "no tunnel IP"
                return
            fi
            ;;
        2)
            tun_label="WireGuard"; tun_if="wg0"
            if [[ -f /etc/wireguard/wg0-interface.conf ]] \
                && ! confirm "A WireGuard server config already exists. Open wg-manager anyway (e.g. to add a client)?"; then
                :
            else
                echo
                echo "In the wg-manager menu: create the server config, create at"
                echo "least one client config and install it on your admin machine,"
                echo "then quit the menu to continue here."
                pause
                run "$WG_SCRIPT" "wg-manager" || true
            fi
            tun_ip=$(wg_server_ip)
            if [[ -z "$tun_ip" ]]; then
                echo "!!! No WireGuard server config - SSH stays as it is, nothing was blocked."
                note "SSH via WireGuard" "FAILED" "no server config"
                return
            fi
            ;;
        *)
            step_firewall_public
            return
            ;;
    esac

    step_firewall_tunnel "$tun_label" "$tun_if" "$tun_ip"
}

# Firewall for "no tunnel": open SSH stays, but rate-limited, plus web ports.
step_firewall_public() {
    local sp; sp=$(ssh_port)
    echo
    echo "SSH stays publicly reachable on port ${sp}. ufw will rate-limit it"
    echo "(6 connections / 30 s per IP), which blunts brute-force attempts."
    confirm "Set up the firewall like this now?" Y || { note "Firewall" "skipped"; return; }

    command -v ufw &>/dev/null || { apt update -qq; apt install -y ufw >/dev/null; }

    ufw limit "${sp}/tcp" comment 'SSH (rate-limited)' || true
    ask_web_ports
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    if ! ufw status | grep -q "Status: active"; then
        echo
        echo "Enabling ufw. The rule for port ${sp} is in place, the session survives."
        ufw --force enable
    fi
    ufw status verbose
    note "Firewall" "done" "SSH public + rate limit"
}

# Firewall for a tunnel, in the safe order: narrow rule and tunnel port first,
# then the test gate, and only after a confirmed tunnel login the public SSH
# rule is removed.
step_firewall_tunnel() {
    local tun_label=$1 tun_if=$2 tun_ip=$3
    local sp; sp=$(ssh_port)

    echo
    echo "Tunnel:    ${tun_label}"
    echo "IP:        ${tun_ip}"
    echo "Interface: ${tun_if}"
    echo "SSH port:  ${sp}"
    echo

    confirm "Lock SSH to the tunnel with ufw now?" Y || {
        note "SSH via ${tun_label}" "skipped" "tunnel up, firewall unchanged"
        return
    }

    command -v ufw &>/dev/null || { apt update -qq; apt install -y ufw >/dev/null; }

    # Order matters: everything that must stay reachable gets its rule BEFORE
    # ufw is enabled or anything is removed.
    # 1. SSH stays open publicly for now - this is the safety net.
    ufw allow "${sp}/tcp" comment 'SSH (temporary, removed after the tunnel test)' || true
    # 2. SSH over the tunnel interface.
    ufw allow in on "$tun_if" to any port "$sp" proto tcp comment "SSH via ${tun_label}" || true
    # 3. WireGuard needs its UDP port open, or the tunnel itself never comes up.
    if [[ "$tun_if" == "wg0" ]]; then
        local wgport; wgport=$(wg_listen_port)
        if [[ -n "$wgport" ]]; then
            ufw allow "${wgport}/udp" comment 'WireGuard' || true
        else
            echo "!!! WireGuard port unknown - check yourself that it is open."
        fi
    fi
    ask_web_ports
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    if ! ufw status | grep -q "Status: active"; then
        echo
        echo "Enabling ufw. Port ${sp} is still open publicly, the session survives."
        ufw --force enable
    fi

    # --- test gate: nothing is closed before this succeeds ------------------
    echo
    echo "!!! Test now, in a SECOND terminal, while this session stays open:"
    echo "!!!     ssh -p ${sp} <user>@${tun_ip}"
    echo "!!! (from a machine that is connected to the tunnel)"
    while ! confirm "Does SSH over ${tun_ip} work?"; do
        if ! confirm "Try again? (No aborts; SSH stays publicly reachable)" Y; then
            note "SSH via ${tun_label}" "aborted" "tunnel login not confirmed, SSH stays public"
            return
        fi
    done

    # --- only now: close the public door ------------------------------------
    echo
    echo "Removing the public SSH rule - after this, SSH is tunnel-only."
    ufw delete allow "${sp}/tcp" || echo "!!! Could not remove the rule - check 'ufw status numbered'."

    echo
    ufw status verbose
    echo
    echo "!!! Verify right now, in a NEW terminal, that SSH over ${tun_ip}"
    echo "!!! still works - while this session is still open."
    pause
    note "SSH via ${tun_label}" "done" "SSH on ${sp}/tcp only via ${tun_if}"
}

ask_web_ports() {
    # Most of these servers run web applications - offer the standard ports.
    if confirm "Open the standard web ports 80/443 (HTTP/HTTPS)?" Y; then
        ufw allow 80/tcp  comment 'HTTP'  || true
        ufw allow 443/tcp comment 'HTTPS' || true
        note "Web ports 80/443" "done"
    else
        note "Web ports 80/443" "skipped"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Operations
# ---------------------------------------------------------------------------
step_operations() {
    banner "Step 3 of 4: Monitor the operation"

    local mailer=0
    { [[ -f /etc/msmtprc ]] || [[ -f /etc/graph-mailer.conf ]]; } && mailer=1
    if confirm_install "Mail delivery" \
        "Set up mail delivery (the channel for updates, disk and scan alerts)?" "$mailer"; then
        echo "1) SMTP account (msmtp)"
        echo "2) Microsoft 365 (Graph API, when SMTP AUTH is blocked)"
        local m; read -rp "Choice [1]: " m
        if [[ "${m:-1}" == "2" ]]; then
            run "$GRAPH_SCRIPT" "graph-mailer" && note "Mail delivery" "done" "Graph" || note "Mail delivery" "FAILED"
        else
            run "$MAIL_SCRIPT" "mail-setup" && note "Mail delivery" "done" "msmtp" || note "Mail delivery" "FAILED"
        fi
    else
        [[ "$mailer" == "1" ]] && note "Mail delivery" "skipped" "already configured" \
                               || note "Mail delivery" "skipped"
    fi

    local m
    for m in \
        "auto-update|$UPDATE_SCRIPT|/etc/cron.d/auto-update|Automatic apt updates with a mail report?" \
        "disk-monitor|$DISK_SCRIPT|/etc/cron.d/disk-monitor|Disk space monitoring?" \
        "clamav-scanner|$CLAM_SCRIPT|/etc/cron.d/clamav-scanner|Daily virus scan (ClamAV)?"
    do
        local name script cron question installed=0
        IFS='|' read -r name script cron question <<<"$m"
        [[ -f "$cron" ]] && installed=1
        if confirm_install "$name" "$question" "$installed"; then
            run "$script" "$name" && note "$name" "done" || note "$name" "FAILED"
        else
            [[ "$installed" == "1" ]] && note "$name" "skipped" "already configured" \
                                      || note "$name" "skipped"
        fi
    done
}

# ---------------------------------------------------------------------------
# Step 4: Updates and virus scan now
# ---------------------------------------------------------------------------
step_finish() {
    banner "Step 4 of 4: Updates and virus scan"

    if confirm "Check for and install pending updates now (apt)?" Y; then
        echo ">>> apt update"
        apt update
        echo
        apt list --upgradable 2>/dev/null | grep -v '^Listing' || true
        echo
        if confirm "Install these now?" Y; then
            if DEBIAN_FRONTEND=noninteractive apt upgrade -y; then
                note "System updates" "done"
            else
                note "System updates" "FAILED"
            fi
            if [[ -f /var/run/reboot-required ]]; then
                echo
                echo "!!! A reboot is required to finish the updates."
                if confirm "Reboot NOW?"; then
                    note "Reboot" "now"
                    show_summary
                    reboot
                    exit 0
                else
                    echo "Remember to reboot soon."
                    note "Reboot" "pending" "/var/run/reboot-required"
                fi
            fi
        else
            note "System updates" "skipped" "list shown, install declined"
        fi
    else
        note "System updates" "skipped"
    fi

    echo
    if confirm "Update the virus signatures and run a first scan now?" Y; then
        if [[ ! -f "$DIR/clamav-scanner.conf" ]]; then
            echo "clamav-scanner is not set up yet - its setup runs first."
            run "$CLAM_SCRIPT" "clamav-scanner" || true
        fi
        if [[ -f "$DIR/clamav-scanner.conf" ]]; then
            run "$CLAM_SCRIPT" "clamav-scanner" --update || true
            echo
            echo "The scan runs with low priority; on a full disk it takes a while."
            if run "$CLAM_SCRIPT" "clamav-scanner" --check; then
                note "Virus scan" "done" "clean"
            else
                note "Virus scan" "done" "findings or errors - see the report"
            fi
        else
            note "Virus scan" "skipped" "not set up"
        fi
    else
        note "Virus scan" "skipped"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
show_summary() {
    banner "Summary"
    local line step status extra
    printf '%-22s %-9s %s\n' "STEP" "STATUS" "NOTE"
    printf '%-22s %-9s %s\n' "----------------------" "---------" "----"
    for line in "${SUMMARY[@]}"; do
        IFS='|' read -r step status extra <<<"$line"
        printf '%-22s %-9s %s\n' "$step" "$status" "$extra"
    done
    echo
    echo "Afterwards useful:"
    echo "  sudo ./setup.sh              the toolbox with all modules"
    echo "  sudo ufw status verbose      what is reachable"
    echo "  sudo ./ssh-setup.sh --status effective sshd settings"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
banner "Server setup wizard ${VERSION}"
echo "Walks through: base tools -> secure SSH over a VPN tunnel -> operations"
echo "-> updates and virus scan. Every step asks first and can be skipped."
echo "Already installed components are detected and not installed twice."
echo "Nothing is closed in the firewall before a login over the tunnel has"
echo "demonstrably worked."
echo

check_os || { echo "Aborted."; exit 1; }
echo

step_tools
step_ssh
step_operations
step_finish
show_summary
