#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# setup.sh - main menu, calls the individual management scripts
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.1.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_SCRIPT="$DIR/base-tools.sh"
SSH_SCRIPT="$DIR/ssh-setup.sh"
UFW_SCRIPT="$DIR/ufw-manager.sh"
MAIL_SCRIPT="$DIR/mail-setup.sh"
GRAPH_SCRIPT="$DIR/graph-mailer.sh"
UPDATE_SCRIPT="$DIR/auto-update.sh"
GITUP_SCRIPT="$DIR/git-updater.sh"
WG_SCRIPT="$DIR/wg-manager.sh"
TS_SCRIPT="$DIR/tailscale-setup.sh"
IPTR_SCRIPT="$DIR/iptables-router.sh"
NGINX_SCRIPT="$DIR/nginx-manager.sh"
CADDY_SCRIPT="$DIR/caddy-manager.sh"
DOCKER_SCRIPT="$DIR/docker-setup.sh"
TCPMON_SCRIPT="$DIR/tcp-monitor.sh"
HTTPMON_SCRIPT="$DIR/http-monitor.sh"
DISK_SCRIPT="$DIR/disk-monitor.sh"
CLAM_SCRIPT="$DIR/clamav-scanner.sh"

run() {
    local script=$1 name=$2; shift 2
    if [[ ! -f "$script" ]]; then
        echo "Script not found: $script"
        read -rp "Press Enter to continue..." _
        return
    fi
    [[ -x "$script" ]] || chmod +x "$script"
    "$script" "$@" || echo "($name exited with an error)"
}

# "systemctl is-active" reports "inactive" AND exit code 3 for inactive
# services. An "|| echo -" would therefore print both and wrap the status line.
svc_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null || true)
    echo "${s:--}"
}

status_line() {
    local wg ts nginx caddy dock fw sshp upd gitu tcp http disk clam mta iptr

    # No "head -1"/"awk exit" in the pipeline: the reader would leave early, the
    # writer would get SIGPIPE (141), and pipefail+set -e would end the menu.
    # awk therefore reads to the end; "|| true" catches missing tools.
    fw=$(ufw status 2>/dev/null | awk 'NR==1 {print $2}' || true)
    sshp=$(sshd -T 2>/dev/null | awk '$1=="port" && !p {print $2; p=1}' || true)

    # The routing rules are only really in effect when the jump sits in FORWARD -
    # the presence of the configuration says nothing about that.
    iptr="-"
    if command -v iptables &>/dev/null && iptables -C FORWARD -j IPTR-FORWARD 2>/dev/null; then
        iptr="active"
    fi
    echo "sshd port: ${sshp:-?}   |   ufw: ${fw:--}   |   routing: ${iptr}"

    wg=$(svc_state wg-quick@wg0)
    ts=$(svc_state tailscaled)
    nginx=$(svc_state nginx)
    caddy=$(svc_state caddy)
    dock=$(svc_state docker)
    echo "wg0: $wg   |   tailscale: $ts   |   nginx: $nginx   |   caddy: $caddy   |   docker: $dock"

    mta="-"
    [[ -f /etc/msmtprc ]] && mta="msmtp"
    if [[ -f /etc/graph-mailer.conf ]]; then
        [[ "$mta" == "-" ]] && mta="Graph" || mta="$mta + Graph"
    fi

    upd=$([[ -f /etc/cron.d/auto-update ]]  && echo "active" || echo "-")
    gitu=$([[ -f /etc/cron.d/git-updater ]] && echo "active" || echo "-")
    tcp=$([[ -f /etc/cron.d/tcp-monitor ]]  && echo "active" || echo "-")
    http=$([[ -f /etc/cron.d/http-monitor ]] && echo "active" || echo "-")
    disk=$([[ -f /etc/cron.d/disk-monitor ]] && echo "active" || echo "-")
    clam=$([[ -f /etc/cron.d/clamav-scanner ]] && echo "active" || echo "-")
    echo "Mailer: $mta   |   auto-update: $upd   |   git-updater: $gitu"
    echo "tcp-monitor: $tcp   |   http-monitor: $http   |   disk-monitor: $disk   |   clamav: $clam"
}

# Uninstall order: first what only observes, then what serves, then access.
# SSH before ufw, so the SSH uninstall can still open port 22 in a running
# firewall. Mail last, so alerts keep going out until the very end.
uninstall_all() {
    echo "All modules are uninstalled one after another."
    echo "Each module asks separately - you can cancel at any point."
    echo
    read -rp "Continue? [y/N]: " C
    [[ "$C" =~ ^[YyJj]$ ]] || return

    run "$CLAM_SCRIPT"   "clamav-scanner" --uninstall
    run "$DISK_SCRIPT"   "disk-monitor"   --uninstall
    run "$HTTPMON_SCRIPT" "http-monitor"  --uninstall
    run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall
    run "$GITUP_SCRIPT"  "git-updater"    --uninstall
    run "$UPDATE_SCRIPT" "auto-update"    --uninstall
    run "$DOCKER_SCRIPT" "docker-setup"   --uninstall
    run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall
    run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall
    run "$IPTR_SCRIPT"   "iptables-router" --uninstall
    run "$TS_SCRIPT"     "tailscale-setup" --uninstall
    run "$WG_SCRIPT"     "wg-manager"     --uninstall
    run "$BASE_SCRIPT"   "base-tools"     --uninstall
    run "$SSH_SCRIPT"    "ssh-setup"      --uninstall
    run "$UFW_SCRIPT"    "ufw-manager"    --uninstall
    run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall
    run "$MAIL_SCRIPT"   "mail-setup"     --uninstall

    echo
    echo "Run finished. The backups are under /root/*-uninstall-*.tar.gz."
    read -rp "Press Enter to continue..." _
}

uninstall_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Uninstall"
        echo "==========================================="
        echo "Only what the tool itself created is removed."
        echo "Packages stay installed; a backup is written to /root first."
        echo
        echo "--- Access -------------------------------"
        echo " 1) Base tools       (shell and editor defaults)"
        echo " 2) SSH hardening    (back to the distribution default)"
        echo " 3) Firewall         (reset rules, switch ufw off)"
        echo " 4) WireGuard"
        echo " 5) Tailscale"
        echo " 6) Routing          (iptables chains, forwarding, boot unit)"
        echo
        echo "--- Operation ----------------------------"
        echo " 7) SMTP mailer (msmtp)"
        echo " 8) Microsoft 365 mailer (Graph)"
        echo " 9) Automatic updates (apt)"
        echo "10) TCP monitoring"
        echo "11) HTTP monitoring"
        echo "12) Disk space monitoring"
        echo "13) Virus scan (ClamAV)"
        echo
        echo "--- Applications -------------------------"
        echo "14) nginx relay"
        echo "15) Caddy"
        echo "16) Docker          (settings, not Docker itself)"
        echo "17) Git updater"
        echo
        echo "18) Everything"
        echo "19) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1)  run "$BASE_SCRIPT"   "base-tools"     --uninstall ;;
            2)  run "$SSH_SCRIPT"    "ssh-setup"      --uninstall ;;
            3)  run "$UFW_SCRIPT"    "ufw-manager"    --uninstall ;;
            4)  run "$WG_SCRIPT"     "wg-manager"     --uninstall ;;
            5)  run "$TS_SCRIPT"     "tailscale-setup" --uninstall ;;
            6)  run "$IPTR_SCRIPT"   "iptables-router" --uninstall ;;
            7)  run "$MAIL_SCRIPT"   "mail-setup"     --uninstall ;;
            8)  run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall ;;
            9)  run "$UPDATE_SCRIPT" "auto-update"    --uninstall ;;
            10) run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall ;;
            11) run "$HTTPMON_SCRIPT" "http-monitor"  --uninstall ;;
            12) run "$DISK_SCRIPT"   "disk-monitor"   --uninstall ;;
            13) run "$CLAM_SCRIPT"   "clamav-scanner" --uninstall ;;
            14) run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall ;;
            15) run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall ;;
            16) run "$DOCKER_SCRIPT" "docker-setup"   --uninstall ;;
            17) run "$GITUP_SCRIPT"  "git-updater"    --uninstall ;;
            18) uninstall_all ;;
            19) return ;;
            *)  sleep 1 ;;
        esac
    done
}

while true; do
    clear 2>/dev/null || true
    echo "==========================================="
    echo " Server administration ${VERSION}"
    echo "==========================================="
    status_line
    echo
    echo "--- Secure access -------------------------"
    echo " 1) Base tools          (nano, vim, screen, coloured shell)"
    echo " 2) SSH hardening       (port, root login, keys instead of passwords)"
    echo " 3) Firewall            (manage ufw rules)"
    echo " 4) WireGuard"
    echo " 5) Tailscale           (mesh VPN with central management)"
    echo " 6) Routing             (iptables: pass traffic between networks)"
    echo
    echo "--- Monitor operation ---------------------"
    echo " 7) SMTP mailer         (msmtp, classic SMTP account)"
    echo " 8) Microsoft 365 mailer (Graph API, when SMTP AUTH is blocked)"
    echo " 9) Automatic updates   (apt via cron, with mail report)"
    echo "10) TCP monitoring      (reachability of services)"
    echo "11) HTTP monitoring     (URL, status code, response time, certificate)"
    echo "12) Disk space          (usage, inodes, forecast)"
    echo "13) Virus scan          (ClamAV: signatures, daily scan, alerts)"
    echo
    echo "--- Applications --------------------------"
    echo "14) nginx               (TCP relay, SNI routing, TLS at the backend)"
    echo "15) Caddy               (TLS termination on this server)"
    echo "16) Docker              (installation, log rotation, cleanup)"
    echo "17) Git updater         (keep working copies current via cron)"
    echo
    echo "18) Uninstall"
    echo "19) Quit"
    read -rp "Choice: " CH
    case "$CH" in
        1)  run "$BASE_SCRIPT"   "base-tools" ;;
        2)  run "$SSH_SCRIPT"    "ssh-setup" ;;
        3)  run "$UFW_SCRIPT"    "ufw-manager" ;;
        4)  run "$WG_SCRIPT"     "wg-manager" ;;
        5)  run "$TS_SCRIPT"     "tailscale-setup" ;;
        6)  run "$IPTR_SCRIPT"   "iptables-router" ;;
        7)  run "$MAIL_SCRIPT"   "mail-setup" ;;
        8)  run "$GRAPH_SCRIPT"  "graph-mailer" ;;
        9)  run "$UPDATE_SCRIPT" "auto-update" ;;
        10) run "$TCPMON_SCRIPT" "tcp-monitor" ;;
        11) run "$HTTPMON_SCRIPT" "http-monitor" ;;
        12) run "$DISK_SCRIPT"   "disk-monitor" ;;
        13) run "$CLAM_SCRIPT"   "clamav-scanner" ;;
        14) run "$NGINX_SCRIPT"  "nginx-manager" ;;
        15) run "$CADDY_SCRIPT"  "caddy-manager" ;;
        16) run "$DOCKER_SCRIPT" "docker-setup" ;;
        17) run "$GITUP_SCRIPT"  "git-updater" ;;
        18) uninstall_menu ;;
        19) exit 0 ;;
        *)  sleep 1 ;;
    esac
done
