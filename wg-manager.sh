#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# wg-manager.sh - WireGuard server and client management
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

WG_DIR=/etc/wireguard
IFACE_CONF="$WG_DIR/wg0-interface.conf"
PEERS_DIR="$WG_DIR/peers.d"
CLIENTS_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
SERVER_PRIV_FILE="$WG_DIR/server_private.key"
SERVER_PUB_FILE="$WG_DIR/server_public.key"
ENDPOINT_FILE="$WG_DIR/server_endpoint.txt"

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
        echo ">>> Installing WireGuard..."
        apt update -qq
        apt install -y wireguard >/dev/null
    fi
}

create_server_config() {
    install_pkg
    mkdir -p "$WG_DIR" "$PEERS_DIR" "$CLIENTS_DIR"
    umask 077

    read -rp "Server tunnel IP [10.10.0.1]: " SRV_IP
    SRV_IP=${SRV_IP:-10.10.0.1}

    read -rp "Listen port (UDP) [51820]: " PORT
    PORT=${PORT:-51820}

    read -rp "Public IP/hostname of this server: " ENDPOINT
    while [[ -z "$ENDPOINT" ]]; do
        read -rp "  -> required: " ENDPOINT
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
    echo "Server config created."
    wg show
    pause
}

edit_server_config() {
    local cur_addr cur_port cur_ep
    cur_addr=$(awk -F'= ' '/^Address/ {print $2}' "$IFACE_CONF")
    cur_port=$(awk -F'= ' '/^ListenPort/ {print $2}' "$IFACE_CONF")
    cur_ep=$(cat "$ENDPOINT_FILE" 2>/dev/null || echo "")

    echo "--- Current ---"
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

    echo "Updated (the interface was restarted)."
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
        echo "(no clients created)"
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
            hs="$(( ($(date +%s) - hs) ))s ago"
        else
            hs="-"
        fi
        printf "%-22s %-16s %s\n" "$name" "$ip" "$hs"
    done
}

create_client() {
    echo "--- Existing clients ---"; list_clients; echo
    read -rp "Name for the new client: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] || -f "$PEERS_DIR/$NAME.conf" ]]; do
        echo "Invalid or already taken."
        read -rp "Name: " NAME
    done

    local sug; sug=$(next_free_ip)
    read -rp "Tunnel IP [$sug]: " CIP; CIP=${CIP:-$sug}

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
    echo "=== Client config '$NAME' ($CLIENTS_DIR/$NAME.conf) ==="
    cat "$CLIENTS_DIR/$NAME.conf"
    echo "=========================================================="
    if command -v qrencode &>/dev/null; then
        read -rp "Show a QR code? [y/N]: " Q
        [[ "$Q" =~ ^[YyJj]$ ]] && qrencode -t ansiutf8 < "$CLIENTS_DIR/$NAME.conf"
    fi
    pause
}

show_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name: " NAME
    [[ -f "$CLIENTS_DIR/$NAME.conf" ]] || { echo "Not found."; pause; return; }
    echo
    cat "$CLIENTS_DIR/$NAME.conf"
    echo
    pause
}

edit_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name to edit: " NAME
    [[ -f "$PEERS_DIR/$NAME.conf" ]] || { echo "Not found."; pause; return; }

    local cur_ip
    cur_ip=$(awk -F'[ /]+' '/AllowedIPs/ {print $3}' "$PEERS_DIR/$NAME.conf")
    read -rp "Tunnel IP [$cur_ip]: " NEW_IP; NEW_IP=${NEW_IP:-$cur_ip}

    read -rp "Generate a new key pair? [y/N]: " REKEY
    if [[ "$REKEY" =~ ^[YyJj]$ ]]; then
        umask 077
        local priv pub
        priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey)
        sed -i "s|^PublicKey = .*|PublicKey = ${pub}|" "$PEERS_DIR/$NAME.conf"
        sed -i "s|^PrivateKey = .*|PrivateKey = ${priv}|" "$CLIENTS_DIR/$NAME.conf"
    fi

    sed -i "s|^AllowedIPs = .*|AllowedIPs = ${NEW_IP}/32|" "$PEERS_DIR/$NAME.conf"
    sed -i "s|^Address = .*|Address = ${NEW_IP}/24|" "$CLIENTS_DIR/$NAME.conf"

    regenerate_wg0
    echo "Updated:"
    cat "$CLIENTS_DIR/$NAME.conf"
    pause
}

delete_client() {
    echo "--- Clients ---"; list_clients; echo
    read -rp "Name to delete: " NAME
    [[ -f "$PEERS_DIR/$NAME.conf" ]] || { echo "Not found."; pause; return; }
    read -rp "Really delete '$NAME'? [y/N]: " C
    if [[ "$C" =~ ^[YyJj]$ ]]; then
        rm -f "$PEERS_DIR/$NAME.conf" "$CLIENTS_DIR/$NAME.conf"
        regenerate_wg0
        echo "Deleted."
    else
        echo "Cancelled."
    fi
    pause
}

client_menu() {
    while true; do
        clear
        echo "=== Client configs ==="
        list_clients
        echo
        echo "1) Create"
        echo "2) Show config"
        echo "3) Edit"
        echo "4) Delete"
        echo "5) Back"
        read -rp "Choice: " CH
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
    echo ">>> Uninstall WireGuard management"
    echo

    local port clients=0
    port=$(awk -F'= ' '/^ListenPort/ {print $2}' "$IFACE_CONF" 2>/dev/null || true)
    [[ -d "$PEERS_DIR" ]] && clients=$(find "$PEERS_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "The following will be removed:"
    echo "  - interface wg0: wg-quick down + systemctl disable"
    echo "  - $WG_CONF and $IFACE_CONF"
    echo "  - ${clients} client config(s) including private keys        [asked]"
    echo "  - server key pair                                       [asked]"
    [[ -n "${port:-}" ]] && echo "  - ufw rule ${port}/udp                                  [asked]" || true
    echo
    echo "Other interfaces in $WG_DIR (wg1 etc.) stay untouched."
    echo "The wireguard package stays installed. Manually: apt purge wireguard"
    echo
    echo "!!! If you reach this server only over the tunnel, you are cutting off"
    echo "!!! your own connection. Make sure of a second way in first."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup wireguard "$WG_DIR" || { pause; return; }

    wg-quick down wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 >/dev/null 2>&1 || true

    if [[ -n "${port:-}" ]] && command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if confirm "Remove the ufw rule ${port}/udp?" Y; then
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$WG_CONF" "$IFACE_CONF" "$ENDPOINT_FILE"

    if confirm "Delete client configs and peer definitions as well?"; then
        rm -rf "$PEERS_DIR" "$CLIENTS_DIR"
    fi

    if confirm "Delete the server key pair as well?"; then
        rm -f "$SERVER_PRIV_FILE" "$SERVER_PUB_FILE"
    fi

    rmdir "$WG_DIR" 2>/dev/null || true

    echo
    echo "Removed."
    pause
}

main_menu() {
    while true; do
        clear
        echo "======================================"
        echo " WireGuard management"
        echo "======================================"
        if server_exists; then
            echo "Server config: present  ($(awk -F'= ' '/^Address/{print $2}' "$IFACE_CONF"), port $(awk -F'= ' '/^ListenPort/{print $2}' "$IFACE_CONF"))"
            echo "Interface:     $(iface_up && echo active || echo inactive)"
            echo
            echo "1) Edit the server config"
            echo "2) Manage client configs"
            echo "3) Status (wg show)"
            echo "4) Restart the interface"
            echo "5) Uninstall"
            echo "6) Quit"
            read -rp "Choice: " CH
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
            echo "No server config present."
            echo
            echo "1) Create the server config"
            echo "2) Remove leftovers (keys, client configs)"
            echo "3) Quit"
            read -rp "Choice: " CH
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
    *)           echo "Usage: $0 [--uninstall|--version]"; exit 1 ;;
esac
