#!/usr/bin/env bash
# setup.sh - Hauptmenü, ruft die einzelnen Verwaltungsscripte auf
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_SCRIPT="$DIR/base-tools.sh"
SSH_SCRIPT="$DIR/ssh-setup.sh"
UFW_SCRIPT="$DIR/ufw-manager.sh"
MAIL_SCRIPT="$DIR/mail-setup.sh"
GRAPH_SCRIPT="$DIR/graph-mailer.sh"
UPDATE_SCRIPT="$DIR/auto-update.sh"
WG_SCRIPT="$DIR/wg-manager.sh"
TS_SCRIPT="$DIR/tailscale-setup.sh"
NGINX_SCRIPT="$DIR/nginx-manager.sh"
CADDY_SCRIPT="$DIR/caddy-manager.sh"
TCPMON_SCRIPT="$DIR/tcp-monitor.sh"
DISK_SCRIPT="$DIR/disk-monitor.sh"

run() {
    local script=$1 name=$2; shift 2
    if [[ ! -f "$script" ]]; then
        echo "Script nicht gefunden: $script"
        read -rp "Weiter mit Enter..." _
        return
    fi
    [[ -x "$script" ]] || chmod +x "$script"
    "$script" "$@" || echo "($name mit Fehler beendet)"
}

status_line() {
    local wg ts nginx caddy fw sshp upd tcp disk mta

    fw=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
    sshp=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
    echo "sshd-Port: ${sshp:-?}   |   ufw: ${fw:--}"

    wg=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "-")
    ts=$(systemctl is-active tailscaled 2>/dev/null || echo "-")
    nginx=$(systemctl is-active nginx 2>/dev/null || echo "-")
    caddy=$(systemctl is-active caddy 2>/dev/null || echo "-")
    echo "wg0: $wg   |   tailscale: $ts   |   nginx: $nginx   |   caddy: $caddy"

    mta="-"
    [[ -f /etc/msmtprc ]] && mta="msmtp"
    if [[ -f /etc/graph-mailer.conf ]]; then
        [[ "$mta" == "-" ]] && mta="Graph" || mta="$mta + Graph"
    fi

    upd=$([[ -f /etc/cron.d/auto-update ]]  && echo "aktiv" || echo "-")
    tcp=$([[ -f /etc/cron.d/tcp-monitor ]]  && echo "aktiv" || echo "-")
    disk=$([[ -f /etc/cron.d/disk-monitor ]] && echo "aktiv" || echo "-")
    echo "Mailer: $mta   |   auto-update: $upd   |   tcp-monitor: $tcp   |   disk-monitor: $disk"
}

# Reihenfolge der Deinstallation: erst was nur beobachtet, dann was ausliefert,
# dann der Zugang. SSH vor ufw, damit die SSH-Deinstallation Port 22 noch in
# einer laufenden Firewall öffnen kann. Mail zuletzt, damit die Alerts bis zum
# Schluss rausgehen.
uninstall_all() {
    echo "Alle Module werden nacheinander deinstalliert."
    echo "Jedes Modul fragt einzeln nach - abbrechen ist jederzeit möglich."
    echo
    read -rp "Fortfahren? [j/N]: " C
    [[ "$C" =~ ^[Jj]$ ]] || return

    run "$DISK_SCRIPT"   "disk-monitor"   --uninstall
    run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall
    run "$UPDATE_SCRIPT" "auto-update"    --uninstall
    run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall
    run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall
    run "$TS_SCRIPT"     "tailscale-setup" --uninstall
    run "$WG_SCRIPT"     "wg-manager"     --uninstall
    run "$BASE_SCRIPT"   "base-tools"     --uninstall
    run "$SSH_SCRIPT"    "ssh-setup"      --uninstall
    run "$UFW_SCRIPT"    "ufw-manager"    --uninstall
    run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall
    run "$MAIL_SCRIPT"   "mail-setup"     --uninstall

    echo
    echo "Durchlauf beendet. Die Backups liegen unter /root/*-uninstall-*.tar.gz."
    read -rp "Weiter mit Enter..." _
}

uninstall_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Deinstallation"
        echo "==========================================="
        echo "Entfernt wird jeweils nur, was das Tool selbst angelegt hat."
        echo "Pakete bleiben installiert; vorher wird nach /root gesichert."
        echo
        echo " 1) Basis-Werkzeuge  (Shell-/Editor-Voreinstellungen)"
        echo " 2) SSH-Härtung      (zurück auf Distributions-Default)"
        echo " 3) Firewall         (Regeln zurücksetzen, ufw abschalten)"
        echo " 4) SMTP-Mailer (msmtp)"
        echo " 5) Microsoft-365-Mailer (Graph)"
        echo " 6) Automatische Updates"
        echo " 7) WireGuard"
        echo " 8) Tailscale"
        echo " 9) nginx-Relais"
        echo "10) Caddy"
        echo "11) TCP-Monitoring"
        echo "12) Speicherplatz-Überwachung"
        echo "13) Alles"
        echo "14) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1)  run "$BASE_SCRIPT"   "base-tools"     --uninstall ;;
            2)  run "$SSH_SCRIPT"    "ssh-setup"      --uninstall ;;
            3)  run "$UFW_SCRIPT"    "ufw-manager"    --uninstall ;;
            4)  run "$MAIL_SCRIPT"   "mail-setup"     --uninstall ;;
            5)  run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall ;;
            6)  run "$UPDATE_SCRIPT" "auto-update"    --uninstall ;;
            7)  run "$WG_SCRIPT"     "wg-manager"     --uninstall ;;
            8)  run "$TS_SCRIPT"     "tailscale-setup" --uninstall ;;
            9)  run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall ;;
            10) run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall ;;
            11) run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall ;;
            12) run "$DISK_SCRIPT"   "disk-monitor"   --uninstall ;;
            13) uninstall_all ;;
            14) return ;;
            *)  sleep 1 ;;
        esac
    done
}

while true; do
    clear
    echo "==========================================="
    echo " Server-Verwaltung"
    echo "==========================================="
    status_line
    echo
    echo " 1) Basis-Werkzeuge     (nano, vim, screen, farbige Shell)"
    echo " 2) SSH-Härtung         (Port, Root-Login, Schlüssel statt Passwort)"
    echo " 3) Firewall            (ufw-Regeln verwalten)"
    echo " 4) SMTP-Mailer         (msmtp, klassischer SMTP-Zugang)"
    echo " 5) Microsoft-365-Mailer (Graph-API, wenn SMTP AUTH gesperrt ist)"
    echo " 6) Automatische Updates (apt per Cron, mit Mail-Report)"
    echo " 7) WireGuard-Verwaltung"
    echo " 8) Tailscale           (Mesh-VPN mit zentraler Verwaltung)"
    echo " 9) nginx-Verwaltung    (TCP-Relais, SNI-Routing, TLS beim Backend)"
    echo "10) Caddy-Verwaltung    (TLS-Terminierung am Server)"
    echo "11) TCP-Monitoring      (Erreichbarkeit von Diensten)"
    echo "12) Speicherplatz       (Belegung, Inodes, Prognose)"
    echo "13) Deinstallation"
    echo "14) Beenden"
    read -rp "Auswahl: " CH
    case "$CH" in
        1)  run "$BASE_SCRIPT"   "base-tools" ;;
        2)  run "$SSH_SCRIPT"    "ssh-setup" ;;
        3)  run "$UFW_SCRIPT"    "ufw-manager" ;;
        4)  run "$MAIL_SCRIPT"   "mail-setup" ;;
        5)  run "$GRAPH_SCRIPT"  "graph-mailer" ;;
        6)  run "$UPDATE_SCRIPT" "auto-update" ;;
        7)  run "$WG_SCRIPT"     "wg-manager" ;;
        8)  run "$TS_SCRIPT"     "tailscale-setup" ;;
        9)  run "$NGINX_SCRIPT"  "nginx-manager" ;;
        10) run "$CADDY_SCRIPT"  "caddy-manager" ;;
        11) run "$TCPMON_SCRIPT" "tcp-monitor" ;;
        12) run "$DISK_SCRIPT"   "disk-monitor" ;;
        13) uninstall_menu ;;
        14) exit 0 ;;
        *)  sleep 1 ;;
    esac
done
