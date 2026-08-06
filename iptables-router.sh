#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# iptables-router.sh - forwarding and NAT between the tunnel and other networks
# Modes: (no argument) = interactive menu
#        --apply       = rebuild the rules from the configuration (systemd unit)
#        --clear       = remove the rules from the running system, keep the config
#        --status      = settings, routes and counters on stdout
#        --uninstall   = uninstall
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.1.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/iptables-router.conf"
ROUTES_DIR="$DIR/var/routes.d"

# Own chains: everything this tool writes lives in them, nothing foreign is ever
# touched, and a rebuild only has to flush these three.
CH_FWD="IPTR-FORWARD"
CH_PRE="IPTR-PREROUTING"
CH_POST="IPTR-POSTROUTING"

UNIT_NAME="iptables-router.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
SYSCTL_FILE="/etc/sysctl.d/99-iptables-router.conf"

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
WAN_IF=""
TUN_IF=""
MANAGE_FORWARD=1

[[ -f "$CONF" ]] && . "$CONF"

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

# ---------------------------------------------------------------------------
# Small helpers: validation and address arithmetic
# ---------------------------------------------------------------------------
# No value may contain a space: the generated rules are stored as one line each
# and split on whitespace again when they are applied.
valid_name()  { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }
valid_iface() { [[ "$1" =~ ^[a-zA-Z0-9._@-]+$ ]]; }
valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

valid_cidr() {
    local ip=${1%/*} len=32 o
    [[ "$1" == */* ]] && len=${1#*/}
    [[ "$len" =~ ^[0-9]+$ ]] && (( len <= 32 )) || return 1
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    for o in ${ip//./ }; do (( o <= 255 )) || return 1; done
    return 0
}

ip2int() { local IFS=.; local -a o; read -r -a o <<<"$1"; echo $(( (o[0]<<24)+(o[1]<<16)+(o[2]<<8)+o[3] )); }
int2ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }

# 10.10.0.1/24 -> 10.10.0.0/24 ; a bare address -> address/32
cidr_network() {
    local ip=${1%/*} len mask
    if [[ "$1" != */* ]]; then echo "${ip}/32"; return; fi
    len=${1#*/}
    mask=$(( 0xFFFFFFFF ^ ((1 << (32-len)) - 1) ))
    echo "$(int2ip $(( $(ip2int "$ip") & mask )))/${len}"
}

# The bare address of a CIDR - good enough as a target for "ip route get".
cidr_addr() { echo "${1%/*}"; }

# Read to the end everywhere instead of "head -1"/"awk exit": a reader that
# leaves early sends SIGPIPE to the writer, and with pipefail that ends the
# script in the middle of the menu.
iface_list() { ip -br link show 2>/dev/null | awk '{print $1}' | tr '\n' ' '; }

detect_wan() { ip route show default 2>/dev/null | awk '$1=="default" && !s {print $5; s=1}'; }

detect_tun() {
    ip -br link show 2>/dev/null | awk '$1 ~ /^(wg|tun|tap)/ && !s {print $1; s=1}' | cut -d'@' -f1
}

# The network the tunnel interface itself sits in, e.g. 10.10.0.0/24
tun_network() {
    local a
    a=$(ip -o -4 addr show dev "${1:-$TUN_IF}" 2>/dev/null | awk '!s {print $4; s=1}')
    [[ -n "$a" ]] || return 0
    cidr_network "$a"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
is_setup() { [[ -f "$CONF" ]]; }

save_conf() {
    cat > "$CONF" <<EOF
# iptables-router configuration
WAN_IF="${WAN_IF}"
TUN_IF="${TUN_IF}"
MANAGE_FORWARD=${MANAGE_FORWARD}
EOF
}

ensure_iptables() {
    command -v iptables &>/dev/null && return 0
    echo "iptables is not installed."
    confirm "Install it now?" Y || return 1
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >/dev/null
    command -v iptables &>/dev/null
}

setup() {
    echo ">>> First-time setup for iptables-router"
    echo
    echo "This tool passes traffic through this server: from the VPN tunnel into"
    echo "another network, out to the internet, or from outside to a machine"
    echo "behind the tunnel. It writes nothing but its own three iptables chains."
    echo

    local w t
    w=$(detect_wan); t=$(detect_tun)

    echo "Interfaces: $(iface_list)"
    echo
    read -rp "Interface towards the internet [${w:-eth0}]: " WAN_IF
    WAN_IF=${WAN_IF:-${w:-eth0}}
    while ! valid_iface "$WAN_IF"; do read -rp "  -> interface name: " WAN_IF; done

    read -rp "Tunnel interface [${t:-wg0}]: " TUN_IF
    TUN_IF=${TUN_IF:-${t:-wg0}}
    while ! valid_iface "$TUN_IF"; do read -rp "  -> interface name: " TUN_IF; done

    echo
    echo "Without net.ipv4.ip_forward the kernel drops every packet that is not"
    echo "addressed to this server - no rule here would have any effect then."
    if confirm "Enable IP forwarding permanently?" Y; then
        MANAGE_FORWARD=1
    else
        MANAGE_FORWARD=0
    fi

    mkdir -p "$ROUTES_DIR"
    save_conf
    if (( MANAGE_FORWARD == 1 )); then enable_forwarding; fi

    echo
    if confirm "Write the rules back after a reboot (systemd unit)?" Y; then
        write_unit
    fi

    echo
    echo "Configuration: $CONF"
    echo "Routes:        $ROUTES_DIR"
    echo ">>> Setup complete. There are no routes yet - menu item 1 or 2."
    pause
}

edit_settings() {
    echo "--- Current settings ---"
    echo "Internet interface: $WAN_IF"
    echo "Tunnel interface:   $TUN_IF"
    echo "IP forwarding:      $(forward_state) $( (( MANAGE_FORWARD == 1 )) && echo "(managed here)" || echo "(not managed here)")"
    echo "Boot unit:          $([[ -f "$UNIT_FILE" ]] && echo "installed" || echo "not installed")"
    echo
    echo "Interfaces: $(iface_list)"
    echo

    local W T
    read -rp "Internet interface [${WAN_IF}]: " W; WAN_IF=${W:-$WAN_IF}
    read -rp "Tunnel interface [${TUN_IF}]: " T; TUN_IF=${T:-$TUN_IF}

    if confirm "Manage IP forwarding through this tool?" "$( (( MANAGE_FORWARD == 1 )) && echo Y || echo N)"; then
        MANAGE_FORWARD=1; enable_forwarding
    else
        MANAGE_FORWARD=0
    fi

    if [[ -f "$UNIT_FILE" ]]; then
        confirm "Keep the boot unit?" Y || remove_unit
    else
        confirm "Install the boot unit?" Y && write_unit || true
    fi

    save_conf
    echo "Saved. The rules are rebuilt so the new interfaces take effect."
    apply_rules || true
    pause
}

# ---------------------------------------------------------------------------
# IP forwarding and the boot unit
# ---------------------------------------------------------------------------
forward_on() { [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; }
forward_state() { forward_on && echo "on" || echo "OFF"; }

enable_forwarding() {
    cat > "$SYSCTL_FILE" <<'EOF'
# from iptables-router.sh - without this the kernel passes no packet on
net.ipv4.ip_forward = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    echo "IP forwarding enabled ($SYSCTL_FILE)."
}

# iptables rules are gone after a reboot. A oneshot unit writes them back;
# --apply is idempotent, so it can also be run again at any time by hand.
write_unit() {
    local after="network-online.target"
    [[ "$TUN_IF" =~ ^wg[0-9]+$ ]] && after="${after} wg-quick@${TUN_IF}.service"

    cat > "$UNIT_FILE" <<EOF
[Unit]
# from iptables-router.sh - iptables rules do not survive a reboot
Description=iptables-router: forwarding and NAT rules
Documentation=file://${SELF}
Wants=network-online.target
After=${after} ufw.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SELF} --apply
ExecStop=${SELF} --clear

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
    echo "Boot unit installed and enabled ($UNIT_FILE)."
}

remove_unit() {
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    echo "Boot unit removed."
}

# ---------------------------------------------------------------------------
# Routes (CRUD)
# ---------------------------------------------------------------------------
route_file() { printf '%s/%s.conf\n' "$ROUTES_DIR" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')"; }

reset_fields() {
    NAME=""; TYPE=""; NET_A=""; NET_B=""; IF_A=""; IF_B=""; NAT="none"
    PROTO=""; LPORT=""; DEST=""; DPORT=""; ENABLED="1"; NOTE=""
}

write_route() {
    mkdir -p "$ROUTES_DIR"
    cat > "$(route_file "$NAME")" <<EOF
# iptables-router route - written by iptables-router.sh
NAME="${NAME}"
TYPE="${TYPE}"
NET_A="${NET_A}"
NET_B="${NET_B}"
IF_A="${IF_A}"
IF_B="${IF_B}"
NAT="${NAT}"
PROTO="${PROTO}"
LPORT="${LPORT}"
DEST="${DEST}"
DPORT="${DPORT}"
ENABLED="${ENABLED}"
NOTE="${NOTE}"
EOF
}

# One line describing what a route does - used in the list and in the checks.
route_summary() {
    case "$TYPE" in
        hub)     echo "${IF_A} <-> ${IF_A} (peers among each other)" ;;
        link)    echo "${NET_A:-any} <-> ${NET_B:-any}" ;;
        exit)    echo "${NET_A:-any} -> ${IF_B} (internet)" ;;
        publish) echo "${PROTO}/${LPORT} -> ${DEST}:${DPORT}" ;;
        *)       echo "?" ;;
    esac
}

list_routes() {
    if [[ ! -d "$ROUTES_DIR" ]] || ! ls "$ROUTES_DIR"/*.conf &>/dev/null; then
        echo "(no routes created)"
        return
    fi
    printf "%-18s %-8s %-40s %-6s %s\n" "NAME" "TYPE" "WHAT" "NAT" "ACTIVE"
    printf "%-18s %-8s %-40s %-6s %s\n" "------------------" "--------" \
        "----------------------------------------" "------" "------"
    local f
    for f in "$ROUTES_DIR"/*.conf; do
        ( . "$f"
          printf "%-18s %-8s %-40s %-6s %s\n" \
              "$NAME" "$TYPE" "$(route_summary)" "$NAT" \
              "$([[ "$ENABLED" == "1" ]] && echo yes || echo no)"
        )
    done
}

ask_nat_link() {
    echo
    echo "NAT towards ${NET_B}: the packets then arrive there with this server's"
    echo "address as the sender. Needed when the far side does not know the way"
    echo "back to ${NET_A:-the source network}. Not needed when it does - and"
    echo "without NAT you keep the real source addresses in the logs over there."
    if confirm "Masquerade towards ${NET_B}?"; then NAT="b"; else NAT="none"; fi
}

create_route() {
    echo "--- Existing routes ---"; list_routes; echo
    reset_fields

    echo "Type:"
    echo "  1) link     two networks may talk to each other (site-to-site)"
    echo "  2) hub      the peers of one tunnel may talk to each other"
    echo "  3) exit     a network reaches the internet through this server"
    echo "  4) publish  a port of this server leads to a machine behind the tunnel"
    local T
    read -rp "Choice [1]: " T
    case "${T:-1}" in
        2) TYPE=hub ;;
        3) TYPE=exit ;;
        4) TYPE=publish ;;
        *) TYPE=link ;;
    esac

    read -rp "Name: " NAME
    while ! valid_name "${NAME:-}" || [[ -f "$(route_file "$NAME")" ]]; do
        echo "Invalid (letters, digits, . _ -) or already taken."
        read -rp "Name: " NAME
    done

    echo
    echo "Interfaces: $(iface_list)"
    echo

    case "$TYPE" in
        hub)
            read -rp "Interface [${TUN_IF}]: " IF_A; IF_A=${IF_A:-$TUN_IF}
            while ! valid_iface "$IF_A"; do read -rp "  -> interface name: " IF_A; done
            ;;
        link)
            local suggest; suggest=$(tun_network)
            read -rp "Network A (this side) [${suggest:-any}]: " NET_A
            NET_A=${NET_A:-${suggest:-any}}
            while [[ "$NET_A" != "any" ]] && ! valid_cidr "$NET_A"; do
                read -rp "  -> IP or CIDR, or 'any': " NET_A
            done

            read -rp "Network B (the far side, e.g. 192.168.178.0/24): " NET_B
            while [[ "$NET_B" != "any" ]] && ! valid_cidr "${NET_B:-}"; do
                read -rp "  -> IP or CIDR, or 'any': " NET_B
            done

            read -rp "Interface of A (empty = any): " IF_A
            read -rp "Interface of B [${TUN_IF}]: " IF_B; IF_B=${IF_B:-$TUN_IF}
            ask_nat_link
            ;;
        exit)
            local suggest; suggest=$(tun_network)
            read -rp "Source network [${suggest:-any}]: " NET_A
            NET_A=${NET_A:-${suggest:-any}}
            while [[ "$NET_A" != "any" ]] && ! valid_cidr "$NET_A"; do
                read -rp "  -> IP or CIDR, or 'any': " NET_A
            done
            read -rp "Incoming interface [${TUN_IF}]: " IF_A; IF_A=${IF_A:-$TUN_IF}
            read -rp "Outgoing interface [${WAN_IF}]: " IF_B; IF_B=${IF_B:-$WAN_IF}
            echo
            echo "Without masquerading, the upstream router would have to know the"
            echo "way back to ${NET_A} - it usually does not."
            if confirm "Masquerade out of ${IF_B}?" Y; then NAT="b"; else NAT="none"; fi
            ;;
        publish)
            echo "  1) tcp   2) udp"
            local P; read -rp "Protocol [1]: " P
            [[ "${P:-1}" == "2" ]] && PROTO=udp || PROTO=tcp

            read -rp "Port on this server: " LPORT
            while ! valid_port "${LPORT:-}"; do read -rp "  -> port 1-65535: " LPORT; done

            read -rp "Target IP (behind the tunnel): " DEST
            while ! valid_cidr "${DEST:-}" || [[ "$DEST" == */* ]]; do
                read -rp "  -> a single IP address: " DEST
            done

            read -rp "Port on the target [${LPORT}]: " DPORT; DPORT=${DPORT:-$LPORT}
            while ! valid_port "$DPORT"; do read -rp "  -> port 1-65535: " DPORT; done

            read -rp "Allowed sources (CIDR, empty = everyone): " NET_A
            while [[ -n "$NET_A" ]] && ! valid_cidr "$NET_A"; do
                read -rp "  -> IP or CIDR, empty = everyone: " NET_A
            done
            read -rp "Incoming interface [${WAN_IF}]: " IF_A; IF_A=${IF_A:-$WAN_IF}
            echo
            echo "Without masquerading, ${DEST} would answer the client directly -"
            echo "past this server, and the connection would never come up."
            if confirm "Masquerade towards ${DEST}?" Y; then NAT="b"; else NAT="none"; fi
            ;;
    esac

    read -rp "Note (optional): " NOTE
    NOTE=${NOTE//|/ }
    ENABLED="1"
    write_route

    echo
    echo "This is created:"
    show_route_rules "$NAME"
    echo
    if confirm "Apply now?" Y; then apply_rules || true; fi
    pause
}

edit_route() {
    echo "--- Routes ---"; list_routes; echo
    local N; read -rp "Name to edit: " N
    local f; f=$(route_file "${N:-}")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    reset_fields
    . "$f"

    local V
    case "$TYPE" in
        hub)
            read -rp "Interface [${IF_A}]: " V; IF_A=${V:-$IF_A}
            ;;
        link)
            read -rp "Network A [${NET_A}]: " V; NET_A=${V:-$NET_A}
            read -rp "Network B [${NET_B}]: " V; NET_B=${V:-$NET_B}
            read -rp "Interface of A [${IF_A:-any}]: " V; [[ -n "$V" ]] && IF_A=$V
            read -rp "Interface of B [${IF_B:-any}]: " V; [[ -n "$V" ]] && IF_B=$V
            echo "NAT: 1) none   2) towards B   3) towards A   4) both"
            read -rp "Choice [current: ${NAT}]: " V
            case "$V" in 1) NAT=none ;; 2) NAT=b ;; 3) NAT=a ;; 4) NAT=both ;; esac
            ;;
        exit)
            read -rp "Source network [${NET_A}]: " V; NET_A=${V:-$NET_A}
            read -rp "Incoming interface [${IF_A}]: " V; IF_A=${V:-$IF_A}
            read -rp "Outgoing interface [${IF_B}]: " V; IF_B=${V:-$IF_B}
            confirm "Masquerade out of ${IF_B}?" "$([[ "$NAT" == none ]] && echo N || echo Y)" \
                && NAT="b" || NAT="none"
            ;;
        publish)
            read -rp "Protocol (tcp/udp) [${PROTO}]: " V; PROTO=${V:-$PROTO}
            read -rp "Port on this server [${LPORT}]: " V; LPORT=${V:-$LPORT}
            read -rp "Target IP [${DEST}]: " V; DEST=${V:-$DEST}
            read -rp "Port on the target [${DPORT}]: " V; DPORT=${V:-$DPORT}
            read -rp "Allowed sources [${NET_A:-everyone}]: " V; [[ -n "$V" ]] && NET_A=$V
            read -rp "Incoming interface [${IF_A}]: " V; IF_A=${V:-$IF_A}
            ;;
    esac

    read -rp "Active (1/0) [${ENABLED}]: " V; ENABLED=${V:-$ENABLED}
    read -rp "Note [${NOTE}]: " V; [[ -n "$V" ]] && NOTE=${V//|/ }

    write_route
    echo
    echo "New rules:"
    show_route_rules "$NAME"
    echo
    apply_rules || true
    pause
}

toggle_route() {
    echo "--- Routes ---"; list_routes; echo
    local N; read -rp "Name to switch on/off: " N
    local f; f=$(route_file "${N:-}")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    reset_fields
    . "$f"
    [[ "$ENABLED" == "1" ]] && ENABLED="0" || ENABLED="1"
    write_route
    echo "'$NAME' is now $([[ "$ENABLED" == "1" ]] && echo active || echo inactive)."
    apply_rules || true
    pause
}

delete_route() {
    echo "--- Routes ---"; list_routes; echo
    local N; read -rp "Name to delete: " N
    local f; f=$(route_file "${N:-}")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    echo
    ( . "$f"; echo "Route '$NAME' ($TYPE): $(route_summary)" )
    confirm "Really delete?" || { echo "Cancelled."; pause; return; }

    rm -f "$f"
    echo "Deleted."
    apply_rules || true
    pause
}

route_menu() {
    while true; do
        clear
        echo "=== Manage routes ==="
        list_routes
        echo
        echo "1) Create a route"
        echo "2) Edit a route"
        echo "3) Switch a route on/off"
        echo "4) Delete a route"
        echo "5) Back"
        local CH; read -rp "Choice: " CH
        case "$CH" in
            1) create_route ;;
            2) edit_route ;;
            3) toggle_route ;;
            4) delete_route ;;
            5) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Rule generation
# ---------------------------------------------------------------------------
# Every rule is emitted as one line "<table> <chain> <arguments...>" and only
# then executed. That way the same function serves the display and the run, and
# what you see in the menu is literally what lands in the kernel.
o_s() { if [[ -n "${1:-}" && "$1" != "any" ]]; then printf -- ' -s %s' "$1"; fi; }
o_d() { if [[ -n "${1:-}" && "$1" != "any" ]]; then printf -- ' -d %s' "$1"; fi; }
o_i() { if [[ -n "${1:-}" && "$1" != "any" ]]; then printf -- ' -i %s' "$1"; fi; }
o_o() { if [[ -n "${1:-}" && "$1" != "any" ]]; then printf -- ' -o %s' "$1"; fi; }
o_c() { printf -- ' -m comment --comment iptr:%s' "$1"; }

emit_route() {
    # shellcheck disable=SC1090
    ( . "$1"
      [[ "$ENABLED" == "1" ]] || exit 0

      case "$TYPE" in
        hub)
            printf 'filter %s%s%s -j ACCEPT%s\n' \
                "$CH_FWD" "$(o_i "$IF_A")" "$(o_o "$IF_A")" "$(o_c "$NAME")"
            ;;
        link)
            printf 'filter %s%s%s%s%s -j ACCEPT%s\n' \
                "$CH_FWD" "$(o_i "$IF_A")" "$(o_o "$IF_B")" "$(o_s "$NET_A")" "$(o_d "$NET_B")" "$(o_c "$NAME")"
            printf 'filter %s%s%s%s%s -j ACCEPT%s\n' \
                "$CH_FWD" "$(o_i "$IF_B")" "$(o_o "$IF_A")" "$(o_s "$NET_B")" "$(o_d "$NET_A")" "$(o_c "$NAME")"
            if [[ "$NAT" == "b" || "$NAT" == "both" ]]; then
                printf 'nat %s%s%s%s -j MASQUERADE%s\n' \
                    "$CH_POST" "$(o_s "$NET_A")" "$(o_d "$NET_B")" "$(o_o "$IF_B")" "$(o_c "$NAME")"
            fi
            if [[ "$NAT" == "a" || "$NAT" == "both" ]]; then
                printf 'nat %s%s%s%s -j MASQUERADE%s\n' \
                    "$CH_POST" "$(o_s "$NET_B")" "$(o_d "$NET_A")" "$(o_o "$IF_A")" "$(o_c "$NAME")"
            fi
            ;;
        exit)
            printf 'filter %s%s%s%s -j ACCEPT%s\n' \
                "$CH_FWD" "$(o_i "$IF_A")" "$(o_o "$IF_B")" "$(o_s "$NET_A")" "$(o_c "$NAME")"
            if [[ "$NAT" != "none" ]]; then
                printf 'nat %s%s%s -j MASQUERADE%s\n' \
                    "$CH_POST" "$(o_s "$NET_A")" "$(o_o "$IF_B")" "$(o_c "$NAME")"
            fi
            ;;
        publish)
            printf 'nat %s%s -p %s%s --dport %s -j DNAT --to-destination %s:%s%s\n' \
                "$CH_PRE" "$(o_i "$IF_A")" "$PROTO" "$(o_s "$NET_A")" "$LPORT" "$DEST" "$DPORT" "$(o_c "$NAME")"
            printf 'filter %s -p %s%s -d %s --dport %s -j ACCEPT%s\n' \
                "$CH_FWD" "$PROTO" "$(o_s "$NET_A")" "$DEST" "$DPORT" "$(o_c "$NAME")"
            if [[ "$NAT" != "none" ]]; then
                printf 'nat %s -p %s -d %s --dport %s -j MASQUERADE%s\n' \
                    "$CH_POST" "$PROTO" "$DEST" "$DPORT" "$(o_c "$NAME")"
            fi
            ;;
      esac
      exit 0
    )
}

emit_rules() {
    # Return traffic first, once for everything: without it every rule would
    # have to be written twice, and a stateless ACCEPT in one direction only
    # would not carry a single TCP connection.
    printf 'filter %s -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT%s\n' \
        "$CH_FWD" "$(o_c "established")"

    local f
    for f in "$ROUTES_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        emit_route "$f"
    done
}

show_route_rules() {
    local f; f=$(route_file "$1")
    local line
    while read -r line; do
        [[ -n "$line" ]] || continue
        local -a p; read -r -a p <<<"$line"
        printf '    iptables -t %s -A %s %s\n' "${p[0]}" "${p[1]}" "${p[*]:2}"
    done < <(emit_route "$f")
}

show_rules() {
    echo "--- The commands this configuration produces ---"
    echo
    local line
    while read -r line; do
        [[ -n "$line" ]] || continue
        local -a p; read -r -a p <<<"$line"
        printf 'iptables -t %s -A %s %s\n' "${p[0]}" "${p[1]}" "${p[*]:2}"
    done < <(emit_rules)
    echo
    echo "Plus the three jumps that hook the chains in:"
    echo "iptables -I FORWARD 1 -j ${CH_FWD}"
    echo "iptables -t nat -I PREROUTING 1 -j ${CH_PRE}"
    echo "iptables -t nat -I POSTROUTING 1 -j ${CH_POST}"
    echo
    echo "--- What is in the kernel right now ---"
    echo
    iptables -n -v -L "$CH_FWD" 2>/dev/null || echo "(chain $CH_FWD does not exist)"
    echo
    iptables -t nat -n -v -L "$CH_PRE" 2>/dev/null || echo "(chain $CH_PRE does not exist)"
    echo
    iptables -t nat -n -v -L "$CH_POST" 2>/dev/null || echo "(chain $CH_POST does not exist)"
}

# ---------------------------------------------------------------------------
# Apply and remove
# ---------------------------------------------------------------------------
ensure_chain() {
    iptables -t "$1" -n -L "$2" &>/dev/null || iptables -t "$1" -N "$2"
}

# The jump has to sit at position 1: ufw rejects forwarded packets at the end of
# its own chains, and Docker inserts rules of its own at the top. So any
# existing occurrence is removed first and then put back in front.
ensure_jump() {
    local t=$1 parent=$2 child=$3
    while iptables -t "$t" -C "$parent" -j "$child" 2>/dev/null; do
        iptables -t "$t" -D "$parent" -j "$child" || break
    done
    iptables -t "$t" -I "$parent" 1 -j "$child"
}

rules_applied() { iptables -C FORWARD -j "$CH_FWD" 2>/dev/null; }

apply_rules() {
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }

    ensure_chain filter "$CH_FWD"
    ensure_chain nat "$CH_PRE"
    ensure_chain nat "$CH_POST"

    iptables -F "$CH_FWD"
    iptables -t nat -F "$CH_PRE"
    iptables -t nat -F "$CH_POST"

    local line fails=0 count=0
    while read -r line; do
        [[ -n "$line" ]] || continue
        local -a p; read -r -a p <<<"$line"
        if iptables -t "${p[0]}" -A "${p[1]}" "${p[@]:2}"; then
            count=$((count+1))
        else
            echo "!!! rejected: iptables -t ${p[0]} -A ${p[1]} ${p[*]:2}" >&2
            fails=$((fails+1))
        fi
    done < <(emit_rules)

    ensure_jump filter FORWARD "$CH_FWD"
    ensure_jump nat PREROUTING "$CH_PRE"
    ensure_jump nat POSTROUTING "$CH_POST"

    if (( MANAGE_FORWARD == 1 )) && ! forward_on; then
        enable_forwarding
    fi

    echo "${count} rule(s) applied$( (( fails > 0 )) && echo ", ${fails} rejected" || true)."
    (( fails == 0 ))
}

clear_rules() {
    local spec t parent child
    for spec in "filter:FORWARD:$CH_FWD" "nat:PREROUTING:$CH_PRE" "nat:POSTROUTING:$CH_POST"; do
        IFS=: read -r t parent child <<<"$spec"
        while iptables -t "$t" -C "$parent" -j "$child" 2>/dev/null; do
            iptables -t "$t" -D "$parent" -j "$child" || break
        done
        iptables -t "$t" -F "$child" 2>/dev/null || true
        iptables -t "$t" -X "$child" 2>/dev/null || true
    done
    echo "Rules removed from the running system (the configuration is kept)."
}

# ---------------------------------------------------------------------------
# The recipe: a network behind a VPN peer
# ---------------------------------------------------------------------------
# The one case this tool exists for, and the one where three things have to fit
# together: the route (AllowedIPs), the forwarding rule, and the way back on the
# far side. Two of them are checked here, the third is spelled out.
wg_allowed_ips() { wg show "${1:-$TUN_IF}" allowed-ips 2>/dev/null || true; }

wg_covers() {
    local iface=$1 net=$2
    grep -qF -- "$net" <<<"$(wg_allowed_ips "$iface")"
}

# Offers to add a subnet to a peer's AllowedIPs - in the running interface and
# in the peer file wg-manager keeps, so it survives the next regeneration.
wg_add_allowed_ips() {
    local iface=$1 peer_ip=$2 net=$3
    local rows pub cur newlist file

    rows=$(wg_allowed_ips "$iface")
    [[ -n "$rows" ]] || { echo "    (no peers on ${iface} - nothing to extend)"; return; }

    pub=$(awk -v ip="$peer_ip" '$0 ~ ip && !s {print $1; s=1}' <<<"$rows")
    if [[ -z "$pub" ]]; then
        echo "    !!! No peer on ${iface} has ${peer_ip} in its AllowedIPs."
        echo "        Create the peer in wg-manager first."
        return
    fi

    cur=$(awk -v p="$pub" '$1==p {$1=""; print}' <<<"$rows" | tr -s ' ' | sed 's/^ //;s/ /,/g')
    # A peer without any AllowedIPs shows up as "(none)" - appending to that
    # would build a list 'wg set' rejects.
    if [[ -z "$cur" || "$cur" == "(none)" ]]; then newlist="$net"; else newlist="${cur},${net}"; fi

    echo "    Peer:        ${pub}"
    echo "    AllowedIPs:  ${cur}"
    echo "    becomes:     ${newlist}"
    confirm "    Change it?" Y || { echo "    Skipped."; return; }

    if ! wg set "$iface" peer "$pub" allowed-ips "$newlist"; then
        echo "    !!! 'wg set' failed - nothing changed."
        return
    fi

    file=$(grep -l -F -- "$pub" /etc/wireguard/peers.d/*.conf 2>/dev/null | awk '!s {print; s=1}' || true)
    if [[ -n "$file" ]]; then
        sed -i "s|^AllowedIPs = .*|AllowedIPs = ${newlist}|" "$file"
        echo "    Applied and written to ${file}."
    else
        echo "    Applied to the running interface."
        echo "    !!! Not found in /etc/wireguard/peers.d - write the line"
        echo "        'AllowedIPs = ${newlist}' into the peer's configuration by"
        echo "        hand, otherwise it is gone after the next restart."
    fi
}

show_peer_hints() {
    local tunnet=$1 lan=$2
    echo "--- What the far side has to do ---"
    echo
    echo "This server can only route as far as the peer. The last stretch - from"
    echo "the peer into ${lan} and back - happens over there:"
    echo
    echo "  1. The peer's WireGuard config must list the networks of this side"
    echo "     under AllowedIPs, otherwise it does not even send the replies"
    echo "     into the tunnel:"
    echo "         AllowedIPs = ${tunnet}"
    echo
    echo "  2. The peer has to pass packets on into its LAN. On a Linux peer:"
    echo "         sysctl -w net.ipv4.ip_forward=1"
    echo "         iptables -t nat -A POSTROUTING -s ${tunnet} -o <lan-if> -j MASQUERADE"
    echo "     With that the machines in ${lan} see the traffic as coming from"
    echo "     the peer itself and need no route of their own."
    echo
    echo "  3. Without that NAT on the peer, the LAN router needs a static route:"
    echo "         ${tunnet}  via  <the peer's LAN address>"
    echo
    echo "  A Windows or macOS peer does not route by default. Then only the peer"
    echo "  itself is reachable, not the machines behind it."
}

recipe_site() {
    echo "=== Recipe: reach a network behind a VPN peer ==="
    echo
    echo "  [this server] === ${TUN_IF} === [peer] --- its LAN"
    echo
    echo "For the server and the peer alone nothing here is needed - the tunnel"
    echo "already does that. This starts one hop further: at the machines behind"
    echo "the peer, or at other peers that are to reach them."
    echo

    local iface peer_ip lan tunnet name net_a def_name
    read -rp "Tunnel interface [${TUN_IF}]: " iface; iface=${iface:-$TUN_IF}
    if ! ip link show "$iface" &>/dev/null; then
        echo "!!! There is no interface '${iface}'. Set the tunnel up first."
        pause; return
    fi

    tunnet=$(tun_network "$iface")
    echo
    if command -v wg &>/dev/null && [[ -n "$(wg_allowed_ips "$iface")" ]]; then
        echo "--- Peers on ${iface} ---"
        wg_allowed_ips "$iface"
        echo
    fi

    read -rp "Tunnel IP of the peer (e.g. 10.10.0.2): " peer_ip
    while ! valid_cidr "${peer_ip:-}"; do read -rp "  -> IP address: " peer_ip; done
    peer_ip=${peer_ip%/*}

    read -rp "Network behind the peer (e.g. 192.168.178.0/24): " lan
    while ! valid_cidr "${lan:-}"; do read -rp "  -> CIDR: " lan; done
    lan=$(cidr_network "$lan")

    read -rp "Which network on this side may reach it [${tunnet:-any}]: " net_a
    net_a=${net_a:-${tunnet:-any}}
    while [[ "$net_a" != "any" ]] && ! valid_cidr "$net_a"; do
        read -rp "  -> IP or CIDR, or 'any': " net_a
    done

    def_name="lan-$(printf '%s' "${lan%/*}" | tr '.' '-')"
    read -rp "Name for the route [${def_name}]: " name
    name=${name:-$def_name}
    while ! valid_name "$name"; do read -rp "  -> letters, digits, . _ - : " name; done

    reset_fields
    NAME="$name"; TYPE="link"; NET_A="$net_a"; NET_B="$lan"; IF_A=""; IF_B="$iface"
    ask_nat_link
    NOTE="via peer ${peer_ip}"
    ENABLED="1"

    echo
    echo "--- 1. The route to ${lan} ---"
    if command -v wg &>/dev/null && [[ -n "$(wg_allowed_ips "$iface")" ]]; then
        if wg_covers "$iface" "$lan"; then
            echo "    [x] ${lan} is in the peer's AllowedIPs - the kernel route exists."
        else
            echo "    [ ] ${lan} is in no peer's AllowedIPs. WireGuard then drops"
            echo "        the packets and there is no route for it either."
            wg_add_allowed_ips "$iface" "$peer_ip" "$lan"
        fi
    else
        echo "    (no WireGuard information on ${iface} - check yourself that a"
        echo "     route to ${lan} exists over ${iface})"
    fi

    echo
    echo "--- 2. Forwarding on this server ---"
    if forward_on; then
        echo "    [x] net.ipv4.ip_forward = 1"
    else
        echo "    [ ] IP forwarding is off - without it nothing is passed on."
        if confirm "    Enable it now?" Y; then MANAGE_FORWARD=1; save_conf; enable_forwarding; fi
    fi

    write_route
    echo "    Route '${NAME}' created:"
    show_route_rules "$NAME"
    echo
    if confirm "Apply now?" Y; then
        apply_rules || true
    else
        echo "Not applied - menu item 3 does it later."
    fi

    echo
    show_peer_hints "${tunnet:-<the tunnel network>}" "$lan"
    echo
    echo "--- Test ---"
    echo "    ping ${peer_ip}                       # the peer itself"
    echo "    ping $(cidr_addr "$lan")                   # a machine in its LAN"
    echo "    ${SELF} --status              # do the counters go up?"
    pause
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
diagnose() {
    echo "=== Check ==="
    echo
    echo "--- Kernel ---"
    echo "  net.ipv4.ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
    echo "  sysctl file:         $([[ -f "$SYSCTL_FILE" ]] && echo "$SYSCTL_FILE" || echo "not written by this tool")"
    echo

    echo "--- Chains ---"
    local first
    first=$(iptables -n -L FORWARD --line-numbers 2>/dev/null | awk 'NR==3 {print $2}' || true)
    if rules_applied; then
        if [[ "$first" == "$CH_FWD" ]]; then
            echo "  [x] ${CH_FWD} is hooked into FORWARD, at position 1"
        else
            echo "  [ ] ${CH_FWD} is hooked in, but '${first:-?}' comes first."
            echo "      ufw rejects forwarded packets at the end of its chains, so"
            echo "      that can eat the traffic. Menu item 3 puts it back in front."
        fi
    else
        echo "  [ ] ${CH_FWD} is not hooked into FORWARD - no rule is in effect."
        echo "      Menu item 3 applies them."
    fi
    echo "      nat/PREROUTING:  $(iptables -t nat -C PREROUTING -j "$CH_PRE" 2>/dev/null && echo present || echo missing)"
    echo "      nat/POSTROUTING: $(iptables -t nat -C POSTROUTING -j "$CH_POST" 2>/dev/null && echo present || echo missing)"
    echo

    echo "--- Routes to the far networks ---"
    if [[ -d "$ROUTES_DIR" ]] && ls "$ROUTES_DIR"/*.conf &>/dev/null; then
        local f
        for f in "$ROUTES_DIR"/*.conf; do
            ( . "$f"
              [[ "$ENABLED" == "1" ]] || exit 0
              local target=""
              case "$TYPE" in
                  link)    target=$NET_B ;;
                  publish) target=$DEST ;;
              esac
              [[ -n "$target" && "$target" != "any" ]] || exit 0

              # "ip route get" always finds something as long as there is a
              # default route - so the interface it names has to be checked, not
              # just the fact that an answer came back.
              local dev expect=""
              [[ "$TYPE" == "link" ]] && expect=$IF_B
              dev=$(ip route get "$(cidr_addr "$target")" 2>/dev/null | awk '!s && /dev/ {for(i=1;i<NF;i++) if($i=="dev") print $(i+1); s=1}')

              if [[ -z "$dev" ]]; then
                  echo "  [ ] ${NAME}: no route to ${target} at all"
              elif [[ -n "$expect" && "$dev" != "$expect" ]]; then
                  echo "  [ ] ${NAME}: ${target} goes out over '${dev}', not over"
                  echo "      '${expect}'. That is the default route catching it - there is"
                  echo "      no route of its own. With WireGuard the subnet belongs in"
                  echo "      the peer's AllowedIPs."
              elif [[ -z "$expect" && "$dev" == "$WAN_IF" ]]; then
                  echo "  [ ] ${NAME}: ${target} goes out over the internet interface"
                  echo "      '${dev}' - probably only the default route, not a route to"
                  echo "      the target network."
              else
                  echo "  [x] ${NAME}: ${target} goes out over '${dev}'"
              fi
            )
        done
    else
        echo "  (no routes configured)"
    fi
    echo

    if command -v wg &>/dev/null && [[ -n "$(wg_allowed_ips "$TUN_IF")" ]]; then
        echo "--- AllowedIPs on ${TUN_IF} ---"
        wg_allowed_ips "$TUN_IF" | sed 's/^/  /'
        echo
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "--- ufw ---"
        echo "  ufw is active. Its FORWARD policy does not matter here as long as"
        echo "  ${CH_FWD} sits in front of it - see above."
        echo "  !!! 'ufw reload', 'ufw enable' and a Docker restart rebuild FORWARD"
        echo "      and throw the jump out. Afterwards: systemctl restart ${UNIT_NAME}"
        echo
    fi

    echo "--- Counters (packets/bytes per rule) ---"
    echo "  Zero everywhere means: nothing arrives - look at routing, not at these"
    echo "  rules."
    echo
    iptables -n -v -L "$CH_FWD" 2>/dev/null || echo "  (chain does not exist)"
    echo
    iptables -t nat -n -v -L "$CH_PRE" 2>/dev/null || true
    echo
    iptables -t nat -n -v -L "$CH_POST" 2>/dev/null || true
    pause
}

# ---------------------------------------------------------------------------
# Status (non-interactive)
# ---------------------------------------------------------------------------
show_status() {
    if ! is_setup; then
        echo "iptables-router is not set up."
        return
    fi
    echo "Internet interface: ${WAN_IF}"
    echo "Tunnel interface:   ${TUN_IF}"
    echo "IP forwarding:      $(forward_state)"
    echo "Rules:              $(rules_applied && echo applied || echo "NOT applied")"
    echo "Boot unit:          $([[ -f "$UNIT_FILE" ]] && echo installed || echo "not installed")"
    echo
    list_routes
    echo
    iptables -n -v -L "$CH_FWD" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall iptables-router"
    echo

    local n=0
    [[ -d "$ROUTES_DIR" ]] && n=$(find "$ROUTES_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "The following will be removed:"
    echo "  - the chains ${CH_FWD}, ${CH_PRE}, ${CH_POST} and their jumps"
    [[ -f "$UNIT_FILE" ]]   && echo "  - the boot unit ${UNIT_FILE}" || true
    [[ -f "$SYSCTL_FILE" ]] && echo "  - ${SYSCTL_FILE} (IP forwarding)             [asked]" || true
    [[ -f "$CONF" ]]        && echo "  - the configuration ${CONF}" || true
    [[ -d "$ROUTES_DIR" ]]  && echo "  - ${n} route(s) in ${ROUTES_DIR}                  [asked]" || true
    echo
    echo "Rules from other sources - ufw, Docker, netfilter-persistent - stay"
    echo "untouched. No package is removed."
    echo
    echo "!!! Afterwards nothing is routed through this server any more. If you"
    echo "!!! reach this machine over a path that runs through these rules, that"
    echo "!!! path is gone."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup iptables-router "$CONF" "$ROUTES_DIR" "$UNIT_FILE" "$SYSCTL_FILE" || { pause; return; }

    clear_rules
    [[ -f "$UNIT_FILE" ]] && remove_unit || true

    if [[ -f "$SYSCTL_FILE" ]] && confirm "Switch IP forwarding off again?"; then
        rm -f "$SYSCTL_FILE"
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
        echo "Forwarding off. Careful: other tools (Docker, Tailscale) may need it."
    fi

    rm -f "$CONF"

    if [[ -d "$ROUTES_DIR" ]] && confirm "Delete the routes as well?"; then
        rm -rf "$ROUTES_DIR"
        rmdir "$DIR/var" 2>/dev/null || true
    fi

    echo
    echo "Removed."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Routing between networks (iptables)"
        echo "==========================================="
        echo "WAN: ${WAN_IF}   |   tunnel: ${TUN_IF}   |   forwarding: $(forward_state)"
        echo "Rules: $(rules_applied && echo applied || echo "NOT applied")   |   boot unit: $([[ -f "$UNIT_FILE" ]] && echo yes || echo no)"
        echo
        list_routes
        echo
        echo "1) Manage routes"
        echo "2) Recipe: reach a network behind a VPN peer"
        echo "3) Apply rules now"
        echo "4) Check"
        echo "5) Show the rules (generated and active)"
        echo "6) Settings (interfaces, forwarding, boot unit)"
        echo "7) Remove the rules from the running system (keep the configuration)"
        echo "8) Uninstall"
        echo "9) Quit"
        local CH; read -rp "Choice: " CH
        case "$CH" in
            1) route_menu ;;
            2) recipe_site ;;
            3) apply_rules || true; pause ;;
            4) diagnose ;;
            5) show_rules; pause ;;
            6) edit_settings ;;
            7) confirm "Really remove all rules of this tool?" && clear_rules || echo "Cancelled."; pause ;;
            8) uninstall ;;
            9) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --apply)     apply_rules ;;
    --clear)     clear_rules ;;
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          ensure_iptables || { echo "Nothing works here without iptables."; exit 1; }
                 is_setup || setup
                 main_menu ;;
    *)           echo "Usage: $0 [--apply|--clear|--status|--uninstall|--version]"; exit 1 ;;
esac
