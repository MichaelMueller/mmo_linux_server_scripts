#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# setup.sh - main menu, calls the individual management scripts
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.4.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_SCRIPT="$DIR/base-tools.sh"
HOST_SCRIPT="$DIR/hostname-setup.sh"
ROOTPW_SCRIPT="$DIR/root-password.sh"
SSH_SCRIPT="$DIR/ssh-setup.sh"
UFW_SCRIPT="$DIR/ufw-manager.sh"
F2B_SCRIPT="$DIR/fail2ban-setup.sh"
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
RES_SCRIPT="$DIR/resource-monitor.sh"
NET_SCRIPT="$DIR/net-monitor.sh"
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
    local wg ts nginx caddy dock fw sshp upd gitu tcp http disk res net clam mta iptr host f2b

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
    host=$(hostname -s 2>/dev/null || echo "?")
    echo "host: ${host}   |   sshd port: ${sshp:-?}   |   ufw: ${fw:--}   |   routing: ${iptr}"

    wg=$(svc_state wg-quick@wg0)
    ts=$(svc_state tailscaled)
    nginx=$(svc_state nginx)
    caddy=$(svc_state caddy)
    dock=$(svc_state docker)
    f2b=$(svc_state fail2ban)
    echo "wg0: $wg   |   tailscale: $ts   |   nginx: $nginx   |   caddy: $caddy   |   docker: $dock   |   fail2ban: $f2b"

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
    res=$([[ -f /etc/cron.d/resource-monitor ]] && echo "active" || echo "-")
    net=$([[ -f /etc/cron.d/net-monitor ]] && echo "active" || echo "-")
    clam=$([[ -f /etc/cron.d/clamav-scanner ]] && echo "active" || echo "-")
    echo "Mailer: $mta   |   auto-update: $upd   |   git-updater: $gitu"
    echo "tcp: $tcp   |   http: $http   |   disk: $disk   |   cpu/ram: $res   |   net: $net   |   clamav: $clam"
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
    run "$NET_SCRIPT"    "net-monitor"    --uninstall
    run "$RES_SCRIPT"    "resource-monitor" --uninstall
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
    run "$F2B_SCRIPT"    "fail2ban-setup" --uninstall
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
        echo "Hostname and root password are not listed: they change the system"
        echo "itself, not something that could be taken back out again."
        echo
        echo "--- Basic setup and access ---------------"
        echo " 1) Base tools       (shell and editor defaults)"
        echo " 2) SSH hardening    (back to the distribution default)"
        echo " 3) WireGuard"
        echo " 4) Tailscale"
        echo " 5) Firewall         (reset rules, switch ufw off)"
        echo " 6) fail2ban         (jails, filter, package)"
        echo
        echo "--- Operation ----------------------------"
        echo " 7) SMTP mailer (msmtp)"
        echo " 8) Microsoft 365 mailer (Graph)"
        echo " 9) Automatic updates (apt)"
        echo "10) TCP monitoring"
        echo "11) HTTP monitoring"
        echo "12) Disk space monitoring"
        echo "13) CPU and RAM monitoring"
        echo "14) Network traffic monitoring"
        echo "15) Virus scan (ClamAV)"
        echo
        echo "--- Applications -------------------------"
        echo "16) Routing          (iptables chains, forwarding, boot unit)"
        echo "17) nginx relay"
        echo "18) Caddy"
        echo "19) Docker          (settings, not Docker itself)"
        echo "20) Git updater"
        echo
        echo "21) Everything"
        echo "22) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1)  run "$BASE_SCRIPT"   "base-tools"     --uninstall ;;
            2)  run "$SSH_SCRIPT"    "ssh-setup"      --uninstall ;;
            3)  run "$WG_SCRIPT"     "wg-manager"     --uninstall ;;
            4)  run "$TS_SCRIPT"     "tailscale-setup" --uninstall ;;
            5)  run "$UFW_SCRIPT"    "ufw-manager"    --uninstall ;;
            6)  run "$F2B_SCRIPT"    "fail2ban-setup" --uninstall ;;
            7)  run "$MAIL_SCRIPT"   "mail-setup"     --uninstall ;;
            8)  run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall ;;
            9)  run "$UPDATE_SCRIPT" "auto-update"    --uninstall ;;
            10) run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall ;;
            11) run "$HTTPMON_SCRIPT" "http-monitor"  --uninstall ;;
            12) run "$DISK_SCRIPT"   "disk-monitor"   --uninstall ;;
            13) run "$RES_SCRIPT"    "resource-monitor" --uninstall ;;
            14) run "$NET_SCRIPT"    "net-monitor"    --uninstall ;;
            15) run "$CLAM_SCRIPT"   "clamav-scanner" --uninstall ;;
            16) run "$IPTR_SCRIPT"   "iptables-router" --uninstall ;;
            17) run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall ;;
            18) run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall ;;
            19) run "$DOCKER_SCRIPT" "docker-setup"   --uninstall ;;
            20) run "$GITUP_SCRIPT"  "git-updater"    --uninstall ;;
            21) uninstall_all ;;
            22) return ;;
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
    echo "--- Basic setup and secure access ---------"
    echo " 1) Base tools          (nano, vim, screen, coloured shell)"
    echo " 2) Hostname            (set it, or generate it from the date)"
    echo " 3) Root password       (set it, or generate a strong one)"
    echo " 4) SSH hardening       (port, root login, keys instead of passwords)"
    echo " 5) WireGuard"
    echo " 6) Tailscale           (mesh VPN with central management)"
    echo " 7) Firewall            (ufw rules; on top of a tunnel: SSH via VPN only)"
    echo " 8) fail2ban            (ban hosts after repeated failed attempts)"
    echo
    echo "--- Monitor operation ---------------------"
    echo " 9) SMTP mailer         (msmtp, classic SMTP account)"
    echo "10) Microsoft 365 mailer (Graph API, when SMTP AUTH is blocked)"
    echo "11) Automatic updates   (apt via cron, exclusions, mail report)"
    echo "12) TCP monitoring      (reachability of services)"
    echo "13) HTTP monitoring     (URL, status code, response time, certificate)"
    echo "14) Disk space          (usage, inodes, forecast)"
    echo "15) CPU and RAM         (sustained load, swapping)"
    echo "16) Network traffic     (throughput per interface)"
    echo "17) Virus scan          (ClamAV: signatures, daily scan, alerts)"
    echo
    echo "--- Applications --------------------------"
    echo "18) Routing             (iptables: pass traffic between networks)"
    echo "19) nginx               (TCP relay, SNI routing, TLS at the backend)"
    echo "20) Caddy               (TLS termination on this server)"
    echo "21) Docker              (installation, log rotation, cleanup)"
    echo "22) Git updater         (keep working copies current via cron)"
    echo
    echo "23) Uninstall"
    echo "24) Quit"
    read -rp "Choice: " CH
    case "$CH" in
        1)  run "$BASE_SCRIPT"   "base-tools" ;;
        2)  run "$HOST_SCRIPT"   "hostname-setup" ;;
        3)  run "$ROOTPW_SCRIPT" "root-password" ;;
        4)  run "$SSH_SCRIPT"    "ssh-setup" ;;
        5)  run "$WG_SCRIPT"     "wg-manager" ;;
        6)  run "$TS_SCRIPT"     "tailscale-setup" ;;
        7)  run "$UFW_SCRIPT"    "ufw-manager" ;;
        8)  run "$F2B_SCRIPT"    "fail2ban-setup" ;;
        9)  run "$MAIL_SCRIPT"   "mail-setup" ;;
        10) run "$GRAPH_SCRIPT"  "graph-mailer" ;;
        11) run "$UPDATE_SCRIPT" "auto-update" ;;
        12) run "$TCPMON_SCRIPT" "tcp-monitor" ;;
        13) run "$HTTPMON_SCRIPT" "http-monitor" ;;
        14) run "$DISK_SCRIPT"   "disk-monitor" ;;
        15) run "$RES_SCRIPT"    "resource-monitor" ;;
        16) run "$NET_SCRIPT"    "net-monitor" ;;
        17) run "$CLAM_SCRIPT"   "clamav-scanner" ;;
        18) run "$IPTR_SCRIPT"   "iptables-router" ;;
        19) run "$NGINX_SCRIPT"  "nginx-manager" ;;
        20) run "$CADDY_SCRIPT"  "caddy-manager" ;;
        21) run "$DOCKER_SCRIPT" "docker-setup" ;;
        22) run "$GITUP_SCRIPT"  "git-updater" ;;
        23) uninstall_menu ;;
        24) exit 0 ;;
        *)  sleep 1 ;;
    esac
done
