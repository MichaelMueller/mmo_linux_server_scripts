#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wg-manager.sh - WireGuard Server- und Client-Verwaltung
set -euo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

WG_DIR=/etc/wireguard
IFACE_CONF="$WG_DIR/wg0-interface.conf"
PEERS_DIR="$WG_DIR/peers.d"
CLIENTS_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
SERVER_PRIV_FILE="$WG_DIR/server_private.key"
SERVER_PUB_FILE="$WG_DIR/server_public.key"
ENDPOINT_FILE="$WG_DIR/server_endpoint.txt"

pause() { read -rp "Weiter mit Enter..." _; }

# confirm "Frage" [J]   -> Default J statt N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

# make_backup <name> <pfad>...   -> /root/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

server_exists() { [[ -f "$IFACE_CONF" ]]; }
iface_up() { wg show wg0 &>/dev/null; }

regenerate_wg0() {
    mkdir -p "$PEERS_DIR" "$CLIENTS_DIR"
    umask 077
    {
        cat "$IFACE_CONF"
        echo
        for f in "$PEERS_DIR"/*.conf; do
            [[ -e "$f" ]] || continue
            cat "$f"
            echo
        done
    } > "$WG_CONF"

    if iface_up; then
        wg syncconf wg0 <(wg-quick strip wg0)
    fi
}

install_pkg() {
    if ! command -v wg &>/dev/null; then
        echo ">>> Installiere WireGuard..."
        apt update -qq
        apt install -y wireguard >/dev/null
    fi
}

create_server_config() {
    install_pkg
    mkdir -p "$WG_DIR" "$PEERS_DIR" "$CLIENTS_DIR"
    umask 077

    read -rp "Server-Tunnel-IP [10.10.0.1]: " SRV_IP
    SRV_IP=${SRV_IP:-10.10.0.1}

    read -rp "Listen-Port (UDP) [51820]: " PORT
    PORT=${PORT:-51820}

    read -rp "Öffentliche IP/Hostname dieses Servers: " ENDPOINT
    while [[ -z "$ENDPOINT" ]]; do
        read -rp "  -> Pflichtfeld: " ENDPOINT
    done

    [[ -f "$SERVER_PRIV_FILE" ]] || wg genkey | tee "$SERVER_PRIV_FILE" | wg pubkey > "$SERVER_PUB_FILE"
    echo "$ENDPOINT" > "$ENDPOINT_FILE"

    cat > "$IFACE_CONF" <<EOF
[Interface]
Address = ${SRV_IP}/24
ListenPort = ${PORT}
PrivateKey = $(cat "$SERVER_PRIV_FILE")
EOF

    regenerate_wg0
    systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
    wg-quick down wg0 2>/dev/null || true
    wg-quick up wg0

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${PORT}/udp"
    fi

    echo
    echo "Server-Config angelegt."
    wg show
    pause
}

edit_server_config() {
    local cur_addr cur_port cur_ep
    cur_addr=$(awk -F'= ' '/^Address/ {print $2}' "$IFACE_CONF")
    cur_port=$(awk -F'= ' '/^ListenPort/ {print $2}' "$IFACE_CONF")
    cur_ep=$(cat "$ENDPOINT_FILE" 2>/dev/null || echo "")

    echo "--- Aktuell ---"
    echo "Address:    $cur_addr"
    echo "ListenPort: $cur_port"
    echo "Endpoint:   $cur_ep"
    echo

    read -rp "Address [$cur_addr]: " NEW_ADDR;  NEW_ADDR=${NEW_ADDR:-$cur_addr}
    read -rp "ListenPort [$cur_port]: " NEW_PORT; NEW_PORT=${NEW_PORT:-$cur_port}
    read -rp "Endpoint [$cur_ep]: " NEW_EP;     NEW_EP=${NEW_EP:-$cur_ep}

    cat > "$IFACE_CONF" <<EOF
[Interface]
Address = ${NEW_ADDR}
ListenPort = ${NEW_PORT}
PrivateKey = $(cat "$SERVER_PRIV_FILE")
EOF
    echo "$NEW_EP" > "$ENDPOINT_FILE"

    regenerate_wg0
    wg-quick down wg0 2>/dev/null || true
    wg-quick up wg0

    for f in "$CLIENTS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        sed -i "s|^Endpoint = .*|Endpoint = ${NEW_EP}:${NEW_PORT}|" "$f"
        sed -i "s|^AllowedIPs = .*|AllowedIPs = $(echo "$NEW_ADDR" | cut -d'/' -f1)/32|" "$f"
    done

    echo "Aktualisiert (Interface wurde neu gestartet)."
    wg show
    pause
}

next_free_ip() {
    local base used
    base=$(awk -F'= ' '/^Address/ {print $2}' "$IFACE_CONF" | cut -d'/' -f1 | cut -d'.' -f1-3)
    used=$(grep -h AllowedIPs "$PEERS_DIR"/*.conf 2>/dev/null | awk -F'[ /]+' '{print $3}')
    for i in $(seq 2 254); do
        echo "$used" | grep -qx "${base}.${i}" || { echo "${base}.${i}"; return; }
    done
}

list_clients() {
    if [[ ! -d "$PEERS_DIR" ]] || [[ -z "$(ls -A "$PEERS_DIR" 2>/dev/null)" ]]; then
        echo "(keine Clients angelegt)"
        return
    fi
    printf "%-22s %-16s %s\n" "NAME" "IP" "HANDSHAKE"
    for f in "$PEERS_DIR"/*.conf; do
        local name ip pub hs
        name=$(basename "$f" .conf)
        ip=$(awk -F'[ /]+' '/AllowedIPs/ {print $3}' "$f")
        pub=$(awk -F'= ' '/PublicKey/ {print $2}' "$f")
        hs=$(wg show wg0 latest-handshakes 2>/dev/null | grep -F "$pub" | awk '{print $2}')
        if [[ -n "${hs:-}" && "$hs" != "0" ]]; then
            hs="vor $(( ($(date +%s) - hs) ))s"
        else
            hs="-"
        fi
        printf "%-22s %-16s %s\n" "$name" "$ip" "$hs"
    done
}

create_client() {
    echo "--- Vorhandene Clients ---"; list_clients; echo
    read -rp "Name für neuen Client: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] || -f "$PEERS_DIR/$NAME.conf" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Name: " NAME
    done

    local sug; sug=$(next_free_ip)
    read -rp "Tunnel-IP [$sug]: " CIP; CIP=${CIP:-$sug}

    umask 077
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)

    cat > "$PEERS_DIR/$NAME.conf" <<EOF
# CLIENT: ${NAME}
[Peer]
PublicKey = ${pub}
AllowedIPs = ${CIP}/32
EOF

    cat > "$CLIENTS_DIR/$NAME.conf" <<EOF
[Interface]
Address = ${CIP}/24
PrivateKey = ${priv}

[Peer]
PublicKey = $(cat "$SERVER_PUB_FILE")
Endpoint = $(cat "$ENDPOINT_FILE"):$(awk -F'= ' '/^ListenPort/ {print $2}' "$IFACE_CONF")
AllowedIPs = $(awk -F'= ' '/^Address/ {print $2}' "$IFACE_CONF" | cut -d'/' -f1)/32
PersistentKeepalive = 25
EOF

    regenerate_wg0

    echo
    echo "=== Client-Config '$NAME' ($CLIENTS_DIR/$NAME.conf) ==="
    cat "$CLIENTS_DIR/$NAME.conf"
    echo "=========================================================="
    if command -v qrencode &>/dev/null; then
        read -rp "QR-Code anzeigen? [j/N]: " Q
        [[ "$Q" =~ ^[Jj]$ ]] && qrencode -t ansiutf8 < "$CLIENTS_DIR/$NAME.conf"
    fi
    pause
}

show_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name: " NAME
    [[ -f "$CLIENTS_DIR/$NAME.conf" ]] || { echo "Nicht gefunden."; pause; return; }
    echo
    cat "$CLIENTS_DIR/$NAME.conf"
    echo
    pause
}

edit_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name zum Bearbeiten: " NAME
    [[ -f "$PEERS_DIR/$NAME.conf" ]] || { echo "Nicht gefunden."; pause; return; }

    local cur_ip
    cur_ip=$(awk -F'[ /]+' '/AllowedIPs/ {print $3}' "$PEERS_DIR/$NAME.conf")
    read -rp "Tunnel-IP [$cur_ip]: " NEW_IP; NEW_IP=${NEW_IP:-$cur_ip}

    read -rp "Schlüsselpaar neu erzeugen? [j/N]: " REKEY
    if [[ "$REKEY" =~ ^[Jj]$ ]]; then
        umask 077
        local priv pub
        priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey)
        sed -i "s|^PublicKey = .*|PublicKey = ${pub}|" "$PEERS_DIR/$NAME.conf"
        sed -i "s|^PrivateKey = .*|PrivateKey = ${priv}|" "$CLIENTS_DIR/$NAME.conf"
    fi

    sed -i "s|^AllowedIPs = .*|AllowedIPs = ${NEW_IP}/32|" "$PEERS_DIR/$NAME.conf"
    sed -i "s|^Address = .*|Address = ${NEW_IP}/24|" "$CLIENTS_DIR/$NAME.conf"

    regenerate_wg0
    echo "Aktualisiert:"
    cat "$CLIENTS_DIR/$NAME.conf"
    pause
}

delete_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name zum Löschen: " NAME
    [[ -f "$PEERS_DIR/$NAME.conf" ]] || { echo "Nicht gefunden."; pause; return; }
    read -rp "'$NAME' wirklich löschen? [j/N]: " C
    if [[ "$C" =~ ^[Jj]$ ]]; then
        rm -f "$PEERS_DIR/$NAME.conf" "$CLIENTS_DIR/$NAME.conf"
        regenerate_wg0
        echo "Gelöscht."
    else
        echo "Abgebrochen."
    fi
    pause
}

client_menu() {
    while true; do
        clear
        echo "=== Client-Configs ==="
        list_clients
        echo
        echo "1) Erstellen"
        echo "2) Config anzeigen"
        echo "3) Bearbeiten"
        echo "4) Löschen"
        echo "5) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) create_client ;;
            2) show_client ;;
            3) edit_client ;;
            4) delete_client ;;
            5) return ;;
            *) sleep 1 ;;
        esac
    done
}

uninstall() {
    echo ">>> Deinstallation WireGuard-Verwaltung"
    echo

    local port clients=0
    port=$(awk -F'= ' '/^ListenPort/ {print $2}' "$IFACE_CONF" 2>/dev/null || true)
    [[ -d "$PEERS_DIR" ]] && clients=$(find "$PEERS_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "Folgendes wird entfernt:"
    echo "  - Interface wg0: wg-quick down + systemctl disable"
    echo "  - $WG_CONF und $IFACE_CONF"
    echo "  - ${clients} Client-Config(s) inkl. privater Schlüssel   [Rückfrage]"
    echo "  - Server-Schlüsselpaar                                  [Rückfrage]"
    [[ -n "${port:-}" ]] && echo "  - ufw-Regel ${port}/udp                                     [Rückfrage]" || true
    echo
    echo "Andere Interfaces in $WG_DIR (wg1 usw.) bleiben unberührt."
    echo "Das Paket wireguard bleibt installiert. Manuell: apt purge wireguard"
    echo
    echo "!!! Wenn du diesen Server nur über den Tunnel erreichst, brichst du dir"
    echo "!!! damit die Verbindung ab. Vorher einen zweiten Zugang sicherstellen."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup wireguard "$WG_DIR" || { pause; return; }

    wg-quick down wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 >/dev/null 2>&1 || true

    if [[ -n "${port:-}" ]] && command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if confirm "ufw-Regel ${port}/udp entfernen?" J; then
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$WG_CONF" "$IFACE_CONF" "$ENDPOINT_FILE"

    if confirm "Client-Configs und Peer-Definitionen ebenfalls löschen?"; then
        rm -rf "$PEERS_DIR" "$CLIENTS_DIR"
    fi

    if confirm "Server-Schlüsselpaar ebenfalls löschen?"; then
        rm -f "$SERVER_PRIV_FILE" "$SERVER_PUB_FILE"
    fi

    rmdir "$WG_DIR" 2>/dev/null || true

    echo
    echo "Entfernt."
    pause
}

main_menu() {
    while true; do
        clear
        echo "======================================"
        echo " WireGuard-Verwaltung"
        echo "======================================"
        if server_exists; then
            echo "Server-Config: vorhanden  ($(awk -F'= ' '/^Address/{print $2}' "$IFACE_CONF"), Port $(awk -F'= ' '/^ListenPort/{print $2}' "$IFACE_CONF"))"
            echo "Interface:     $(iface_up && echo aktiv || echo inaktiv)"
            echo
            echo "1) Server-Config bearbeiten"
            echo "2) Client-Configs verwalten"
            echo "3) Status (wg show)"
            echo "4) Interface neu starten"
            echo "5) Deinstallieren"
            echo "6) Beenden"
            read -rp "Auswahl: " CH
            case "$CH" in
                1) edit_server_config ;;
                2) client_menu ;;
                3) wg show; pause ;;
                4) wg-quick down wg0 2>/dev/null || true; wg-quick up wg0; pause ;;
                5) uninstall ;;
                6) exit 0 ;;
                *) sleep 1 ;;
            esac
        else
            echo "Keine Server-Config vorhanden."
            echo
            echo "1) Server-Config anlegen"
            echo "2) Reste entfernen (Schlüssel, Client-Configs)"
            echo "3) Beenden"
            read -rp "Auswahl: " CH
            case "$CH" in
                1) create_server_config ;;
                2) uninstall ;;
                3) exit 0 ;;
                *) sleep 1 ;;
            esac
        fi
    done
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Verwendung: $0 [--uninstall|--version]"; exit 1 ;;
esac
