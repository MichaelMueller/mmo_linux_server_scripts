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
GITUP_SCRIPT="$DIR/git-updater.sh"
WG_SCRIPT="$DIR/wg-manager.sh"
TS_SCRIPT="$DIR/tailscale-setup.sh"
NGINX_SCRIPT="$DIR/nginx-manager.sh"
CADDY_SCRIPT="$DIR/caddy-manager.sh"
DOCKER_SCRIPT="$DIR/docker-setup.sh"
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

# "systemctl is-active" meldet bei inaktiven Diensten "inactive" UND Exitcode 3.
# Ein "|| echo -" würde deshalb beides ausgeben und die Statuszeile umbrechen.
svc_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null || true)
    echo "${s:--}"
}

status_line() {
    local wg ts nginx caddy dock fw sshp upd gitu tcp disk mta

    # Kein "head -1"/"awk exit" in der Pipeline: der Leser steigt vorzeitig aus,
    # der Schreiber bekommt SIGPIPE (141) und pipefail+set -e beenden das Menü.
    # awk liest deshalb bis zum Ende durch, "|| true" fängt fehlende Tools ab.
    fw=$(ufw status 2>/dev/null | awk 'NR==1 {print $2}' || true)
    sshp=$(sshd -T 2>/dev/null | awk '$1=="port" && !p {print $2; p=1}' || true)
    echo "sshd-Port: ${sshp:-?}   |   ufw: ${fw:--}"

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

    upd=$([[ -f /etc/cron.d/auto-update ]]  && echo "aktiv" || echo "-")
    gitu=$([[ -f /etc/cron.d/git-updater ]] && echo "aktiv" || echo "-")
    tcp=$([[ -f /etc/cron.d/tcp-monitor ]]  && echo "aktiv" || echo "-")
    disk=$([[ -f /etc/cron.d/disk-monitor ]] && echo "aktiv" || echo "-")
    echo "Mailer: $mta   |   auto-update: $upd   |   git-updater: $gitu"
    echo "tcp-monitor: $tcp   |   disk-monitor: $disk"
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
    run "$GITUP_SCRIPT"  "git-updater"    --uninstall
    run "$UPDATE_SCRIPT" "auto-update"    --uninstall
    run "$DOCKER_SCRIPT" "docker-setup"   --uninstall
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
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Deinstallation"
        echo "==========================================="
        echo "Entfernt wird jeweils nur, was das Tool selbst angelegt hat."
        echo "Pakete bleiben installiert; vorher wird nach /root gesichert."
        echo
        echo "--- Zugang -------------------------------"
        echo " 1) Basis-Werkzeuge  (Shell-/Editor-Voreinstellungen)"
        echo " 2) SSH-Härtung      (zurück auf Distributions-Default)"
        echo " 3) Firewall         (Regeln zurücksetzen, ufw abschalten)"
        echo " 4) WireGuard"
        echo " 5) Tailscale"
        echo
        echo "--- Betrieb ------------------------------"
        echo " 6) SMTP-Mailer (msmtp)"
        echo " 7) Microsoft-365-Mailer (Graph)"
        echo " 8) Automatische Updates (apt)"
        echo " 9) TCP-Monitoring"
        echo "10) Speicherplatz-Überwachung"
        echo
        echo "--- Applikationen ------------------------"
        echo "11) nginx-Relais"
        echo "12) Caddy"
        echo "13) Docker      (Einstellungen, nicht Docker selbst)"
        echo "14) Git-Updater"
        echo
        echo "15) Alles"
        echo "16) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1)  run "$BASE_SCRIPT"   "base-tools"     --uninstall ;;
            2)  run "$SSH_SCRIPT"    "ssh-setup"      --uninstall ;;
            3)  run "$UFW_SCRIPT"    "ufw-manager"    --uninstall ;;
            4)  run "$WG_SCRIPT"     "wg-manager"     --uninstall ;;
            5)  run "$TS_SCRIPT"     "tailscale-setup" --uninstall ;;
            6)  run "$MAIL_SCRIPT"   "mail-setup"     --uninstall ;;
            7)  run "$GRAPH_SCRIPT"  "graph-mailer"   --uninstall ;;
            8)  run "$UPDATE_SCRIPT" "auto-update"    --uninstall ;;
            9)  run "$TCPMON_SCRIPT" "tcp-monitor"    --uninstall ;;
            10) run "$DISK_SCRIPT"   "disk-monitor"   --uninstall ;;
            11) run "$NGINX_SCRIPT"  "nginx-manager"  --uninstall ;;
            12) run "$CADDY_SCRIPT"  "caddy-manager"  --uninstall ;;
            13) run "$DOCKER_SCRIPT" "docker-setup"   --uninstall ;;
            14) run "$GITUP_SCRIPT"  "git-updater"    --uninstall ;;
            15) uninstall_all ;;
            16) return ;;
            *)  sleep 1 ;;
        esac
    done
}

while true; do
    clear 2>/dev/null || true
    echo "==========================================="
    echo " Server-Verwaltung"
    echo "==========================================="
    status_line
    echo
    echo "--- Zugang sichern ------------------------"
    echo " 1) Basis-Werkzeuge     (nano, vim, screen, farbige Shell)"
    echo " 2) SSH-Härtung         (Port, Root-Login, Schlüssel statt Passwort)"
    echo " 3) Firewall            (ufw-Regeln verwalten)"
    echo " 4) WireGuard-Verwaltung"
    echo " 5) Tailscale           (Mesh-VPN mit zentraler Verwaltung)"
    echo
    echo "--- Betrieb überwachen --------------------"
    echo " 6) SMTP-Mailer         (msmtp, klassischer SMTP-Zugang)"
    echo " 7) Microsoft-365-Mailer (Graph-API, wenn SMTP AUTH gesperrt ist)"
    echo " 8) Automatische Updates (apt per Cron, mit Mail-Report)"
    echo " 9) TCP-Monitoring      (Erreichbarkeit von Diensten)"
    echo "10) Speicherplatz       (Belegung, Inodes, Prognose)"
    echo
    echo "--- Applikationen -------------------------"
    echo "11) nginx-Verwaltung    (TCP-Relais, SNI-Routing, TLS beim Backend)"
    echo "12) Caddy-Verwaltung    (TLS-Terminierung am Server)"
    echo "13) Docker             (Installation, Log-Rotation, Aufräumen)"
    echo "14) Git-Updater        (Arbeitskopien per Cron aktuell halten)"
    echo
    echo "15) Deinstallation"
    echo "16) Beenden"
    read -rp "Auswahl: " CH
    case "$CH" in
        1)  run "$BASE_SCRIPT"   "base-tools" ;;
        2)  run "$SSH_SCRIPT"    "ssh-setup" ;;
        3)  run "$UFW_SCRIPT"    "ufw-manager" ;;
        4)  run "$WG_SCRIPT"     "wg-manager" ;;
        5)  run "$TS_SCRIPT"     "tailscale-setup" ;;
        6)  run "$MAIL_SCRIPT"   "mail-setup" ;;
        7)  run "$GRAPH_SCRIPT"  "graph-mailer" ;;
        8)  run "$UPDATE_SCRIPT" "auto-update" ;;
        9)  run "$TCPMON_SCRIPT" "tcp-monitor" ;;
        10) run "$DISK_SCRIPT"   "disk-monitor" ;;
        11) run "$NGINX_SCRIPT"  "nginx-manager" ;;
        12) run "$CADDY_SCRIPT"  "caddy-manager" ;;
        13) run "$DOCKER_SCRIPT" "docker-setup" ;;
        14) run "$GITUP_SCRIPT"  "git-updater" ;;
        15) uninstall_menu ;;
        16) exit 0 ;;
        *)  sleep 1 ;;
    esac
done
