#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tailscale-setup.sh - Tailscale installieren, anmelden und einstellen
# Modi:  (ohne Argument) = interaktives Menü
#        --status        = Status auf stdout
#        --uninstall     = Deinstallation
set -uo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

SYSCTL_FILE=/etc/sysctl.d/99-tailscale.conf
REPO_LIST=/etc/apt/sources.list.d/tailscale.list
REPO_KEY=/usr/share/keyrings/tailscale-archive-keyring.gpg
IFACE=tailscale0

pause() { read -rp "Weiter mit Enter..." _; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nichts zu sichern)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
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

    echo ">>> Installiere Tailscale aus dem offiziellen Repo..."

    # shellcheck disable=SC1091
    . /etc/os-release
    local id=${ID:-debian} code=${VERSION_CODENAME:-}

    if [[ -z "$code" ]]; then
        echo "!!! /etc/os-release nennt keinen VERSION_CODENAME."
        read -rp "Codename der Distribution (z.B. bookworm, jammy): " code
        [[ -n "$code" ]] || return 1
    fi

    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg apt-transport-https >/dev/null

    if ! curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.noarmor.gpg" -o "$REPO_KEY"; then
        echo "!!! Schlüssel für ${id}/${code} nicht abrufbar - stimmt der Codename?"
        return 1
    fi
    curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.tailscale-keyring.list" -o "$REPO_LIST" || return 1

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale >/dev/null || return 1

    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    echo ">>> Installiert: $(tailscale version 2>/dev/null | head -1)"
}

# IP-Forwarding wird nur gebraucht, wenn dieser Knoten Verkehr für andere
# weiterleitet - also als Subnetz-Router oder Exit-Node.
enable_forwarding() {
    cat > "$SYSCTL_FILE" <<'EOF'
# von tailscale-setup.sh - nötig für Subnetz-Router und Exit-Node
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    echo "IP-Forwarding aktiviert ($SYSCTL_FILE)."
}

# ---------------------------------------------------------------------------
# Anmelden und einstellen
# ---------------------------------------------------------------------------
# 'tailscale up' setzt Optionen, die man NICHT mitgibt, auf ihren Default
# zurück und verlangt dafür --reset. Deshalb werden hier immer alle verwalteten
# Flags zusammen gefragt und gemeinsam gesetzt.
build_up_args() {
    UP_ARGS=()
    local host ssh exitnode routes acceptroutes acceptdns shields tags

    read -rp "Hostname im Tailnet [$(hostname -s)]: " host
    UP_ARGS+=("--hostname=${host:-$(hostname -s)}")

    echo
    echo "Tailscale SSH: Anmeldung über das Tailnet, Zugriff wird zentral über"
    echo "die ACLs geregelt. Der normale sshd bleibt davon unberührt."
    if confirm "Tailscale SSH aktivieren?" N; then ssh=1; else ssh=0; fi
    (( ssh == 1 )) && UP_ARGS+=(--ssh) || UP_ARGS+=(--ssh=false)

    echo
    if confirm "Lokale Subnetze für andere Knoten anbieten (Subnetz-Router)?" N; then
        read -rp "  Subnetze, kommagetrennt (z.B. 192.168.1.0/24): " routes
        [[ -n "$routes" ]] && UP_ARGS+=("--advertise-routes=${routes}")
    fi

    if confirm "Diesen Server als Exit-Node anbieten?" N; then
        exitnode=1
        UP_ARGS+=(--advertise-exit-node)
    fi

    echo
    if confirm "Von anderen angebotene Subnetze annehmen (--accept-routes)?" N; then
        acceptroutes=1; UP_ARGS+=(--accept-routes)
    else
        UP_ARGS+=(--accept-routes=false)
    fi

    echo
    echo "MagicDNS trägt die Tailscale-Nameserver in /etc/resolv.conf ein. Auf"
    echo "einem Server mit eigener DNS-Konfiguration will man das oft nicht."
    if confirm "MagicDNS/DNS-Einstellungen übernehmen?" N; then
        acceptdns=1; UP_ARGS+=(--accept-dns)
    else
        UP_ARGS+=(--accept-dns=false)
    fi

    echo
    echo "Shields up: dieser Knoten nimmt KEINE eingehenden Verbindungen aus dem"
    echo "Tailnet an, kann selbst aber raus."
    if confirm "Shields up aktivieren?" N; then shields=1; UP_ARGS+=(--shields-up); fi

    echo
    read -rp "Tags (z.B. tag:server, leer = keine): " tags
    [[ -n "$tags" ]] && UP_ARGS+=("--advertise-tags=${tags}")

    if [[ -n "${routes:-}" || "${exitnode:-0}" == "1" ]]; then
        echo
        enable_forwarding
    fi
}

run_up() {
    local -a extra=("$@")
    echo
    echo "Ausgeführt wird:"
    printf '    tailscale up'; printf ' %q' "${UP_ARGS[@]}" "${extra[@]}"; echo
    echo
    confirm "Ausführen?" J || { echo "Abgebrochen."; return 1; }

    if tailscale up "${UP_ARGS[@]}" "${extra[@]}"; then
        echo
        echo ">>> Verbunden. Tailnet-IP: $(tailnet_ip)"
        return 0
    fi
    echo
    echo "!!! 'tailscale up' war nicht erfolgreich."
    echo "Ändert man Optionen, die vorher gesetzt waren, verlangt Tailscale ein"
    echo "--reset. Menüpunkt 3 bietet das an."
    return 1
}

first_setup() {
    install_tailscale || { echo "!!! Installation fehlgeschlagen."; pause; return; }

    echo
    echo "Anmeldung:"
    echo "  1) interaktiv - Tailscale zeigt eine URL, die im Browser geöffnet wird"
    echo "  2) mit Auth-Key aus der Admin-Konsole (tskey-auth-...)"
    local M; read -rp "Auswahl [1]: " M

    build_up_args

    if [[ "${M:-1}" == "2" ]]; then
        local key kf
        read -rsp "Auth-Key: " key; echo
        if [[ -z "$key" ]]; then echo "Kein Key angegeben."; pause; return; fi
        # Über eine Datei statt über die Kommandozeile: sonst stünde der Key in
        # der Prozessliste.
        kf=$(mktemp); chmod 600 "$kf"; printf '%s' "$key" > "$kf"
        run_up "--auth-key=file:${kf}" || true
        rm -f "$kf"
    else
        echo
        echo "Gleich erscheint eine URL. Diese im Browser öffnen und den Knoten"
        echo "freigeben - danach läuft es hier weiter."
        run_up || true
    fi
    pause
}

change_settings() {
    installed || { echo "Tailscale ist nicht installiert."; pause; return; }
    build_up_args
    echo
    echo "Hinweis: --reset setzt alle Optionen, die hier nicht gefragt werden,"
    echo "auf ihren Default zurück."
    local -a extra=()
    confirm "Mit --reset ausführen?" J && extra=(--reset)
    run_up "${extra[@]}" || true
    pause
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
firewall_rule() {
    if ! command -v ufw &>/dev/null; then
        echo "ufw ist nicht installiert - hier gibt es nichts einzustellen."
        pause; return
    fi

    echo "Mit einer Regel auf die Schnittstelle ${IFACE} erreichen Knoten aus dem"
    echo "Tailnet Dienste auf diesem Server, ohne dass ein Port öffentlich offen"
    echo "sein muss."
    echo
    echo "Bestehende Regeln für ${IFACE}:"
    ufw status 2>/dev/null | grep -E "on ${IFACE}" || echo "  (keine)"
    echo
    echo "1) Allen Verkehr aus dem Tailnet erlauben  (allow in on ${IFACE})"
    echo "2) Nur einen bestimmten Port erlauben"
    echo "3) Zurück"
    local CH; read -rp "Auswahl: " CH
    case "$CH" in
        1)
            confirm "ufw allow in on ${IFACE} ausführen?" J \
                && ufw allow in on "$IFACE" comment 'Tailnet' || true
            ;;
        2)
            local p
            read -rp "Port: " p
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Keine Zahl."; pause; return; }
            confirm "ufw allow in on ${IFACE} to any port ${p} proto tcp ausführen?" J \
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
        echo "Tailscale ist nicht installiert."
        return
    fi
    echo "--- Version ---"
    tailscale version 2>/dev/null | sed 's/^/  /'
    echo
    echo "--- Dienst ---"
    printf '  tailscaled: %s\n' "$(systemctl is-active tailscaled 2>/dev/null || echo '-')"
    printf '  Anmeldung:  %s\n' "$(logged_in && echo 'angemeldet' || echo 'nicht angemeldet')"
    printf '  Tailnet-IP: %s\n' "$(tailnet_ip || echo '-')"
    echo
    echo "--- Knoten im Tailnet ---"
    tailscale status 2>/dev/null | sed 's/^/  /' || echo "  (keine Ausgabe)"
    echo
    echo "--- IP-Forwarding ---"
    if [[ -f "$SYSCTL_FILE" ]]; then
        echo "  aktiviert über $SYSCTL_FILE"
    else
        echo "  nicht von diesem Tool gesetzt (aktuell: $(sysctl -n net.ipv4.ip_forward 2>/dev/null))"
    fi
}

do_logout() {
    echo "Meldet den Knoten vom Tailnet ab. Die Software bleibt installiert."
    echo
    echo "!!! Wenn du diesen Server nur über Tailscale erreichst, brichst du dir"
    echo "!!! damit die Verbindung ab."
    echo
    confirm "Wirklich abmelden?" || { echo "Abgebrochen."; pause; return; }
    tailscale logout || true
    tailscale down 2>/dev/null || true
    echo "Abgemeldet."
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation Tailscale"
    echo

    if ! installed; then
        echo "Tailscale ist nicht installiert."
        [[ -f "$SYSCTL_FILE" ]] || { pause; return; }
    fi

    echo "Folgendes wird entfernt:"
    logged_in            && echo "  - Abmeldung vom Tailnet (tailscale logout)"
    installed            && echo "  - Dienst tailscaled wird gestoppt und deaktiviert"
    [[ -f "$SYSCTL_FILE" ]] && echo "  - $SYSCTL_FILE (IP-Forwarding)"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}" \
        && echo "  - ufw-Regeln für ${IFACE}                          [Rückfrage]"
    echo
    echo "Das Paket bleibt installiert, der Zustand unter /var/lib/tailscale auch."
    echo "Vollständig entfernen:"
    echo "    apt purge tailscale && rm -rf /var/lib/tailscale \\"
    echo "        ${REPO_LIST} ${REPO_KEY}"
    echo
    echo "!!! Der Knoten bleibt in der Admin-Konsole eingetragen und muss dort"
    echo "!!! separat gelöscht werden."
    echo
    echo "!!! Wenn du diesen Server nur über Tailscale erreichst, brichst du dir"
    echo "!!! damit die Verbindung ab."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup tailscale "$SYSCTL_FILE" /var/lib/tailscale || { pause; return; }

    if installed; then
        tailscale logout 2>/dev/null || true
        tailscale down 2>/dev/null || true
        systemctl stop tailscaled    >/dev/null 2>&1 || true
        systemctl disable tailscaled >/dev/null 2>&1 || true
    fi

    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        # Nicht blind auf 0 setzen: andere Dienste (Docker, WireGuard-Routing)
        # brauchen Forwarding womöglich auch.
        echo "$SYSCTL_FILE entfernt. IP-Forwarding bleibt bis zum Neustart aktiv;"
        echo "andere Dienste können es ebenfalls brauchen."
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}"; then
        if confirm "ufw-Regeln für ${IFACE} entfernen?" J; then
            # Von hinten löschen, damit sich die Nummern nicht verschieben.
            local n
            for n in $(ufw status numbered 2>/dev/null | grep "on ${IFACE}" \
                       | grep -oE '^\[[ ]*[0-9]+\]' | grep -oE '[0-9]+' | sort -rn); do
                ufw --force delete "$n" >/dev/null 2>&1 || true
            done
            echo "Entfernt."
        fi
    fi

    echo
    echo "Fertig."
    pause
}

# ---------------------------------------------------------------------------
# Menü
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
                echo "Status:     angemeldet, IP $(tailnet_ip)"
            else
                echo "Status:     nicht angemeldet"
            fi
        else
            echo "Status: nicht installiert"
        fi
        echo
        echo "1) Installieren und anmelden"
        echo "2) Status anzeigen"
        echo "3) Einstellungen ändern (SSH, Routen, Exit-Node, DNS)"
        echo "4) Firewall: Zugriff über das Tailnet erlauben"
        echo "5) Abmelden"
        echo "6) Deinstallieren"
        echo "7) Beenden"
        read -rp "Auswahl: " CH
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
    *)           echo "Verwendung: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
