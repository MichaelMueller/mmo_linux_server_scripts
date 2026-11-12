#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ufw-manager.sh - manage firewall rules (CRUD on ufw)
# Modes: (no argument) = interactive menu
#        --setup       = baseline: default deny, SSH kept reachable, web ports,
#                        review of the listening services
#        --status      = rules on stdout
#        --uninstall   = uninstall
#
# Presets: a DEFAULT_* that is set (not empty) is taken without a question -
# interactively as well - and printed as "<question>: <value> (preset)". An
# invalid preset is an error, nothing is changed. Unset ones are asked (batch
# mode: their built-in default, in brackets below):
#   DEFAULT_SETUP_FIREWALL   Y|N  set up the firewall when ufw is not active (Y)
#   DEFAULT_IGNORE_OTHER_FW  Y|N  set up ufw although firewalld/nftables runs (N)
#   DEFAULT_OPEN_WEB         Y|N  open 80/443 (Y when something listens there)
#   DEFAULT_ALLOW_LISTENERS  listening services to allow publicly, as a
#                            space-separated port/proto list, e.g.
#                            "25/tcp 51820/udp" ('-' = none)
#   DEFAULT_APP_PORTS        further public ports, e.g. "8443/tcp 6000:6010/tcp"
#                            ('-' = none)
#   DEFAULT_OPEN_TS_PORT     Y|N  open 41641/udp when Tailscale is installed
#                            (batch: Y, interactive: N)
# Batch mode: BATCH=1 - no questions, every question takes its default and
# prints what it took (base-setup.sh uses it with --setup).
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# yn_value VALUE - a yes/no value (Y, N, yes, no, j, ja, 1, 0, true, false)
# as Y or N; fails on anything else
yn_value() {
    case "${1,,}" in
        y|yes|j|ja|1|true)   echo Y ;;
        n|no|nein|0|false)   echo N ;;
        *)                   return 1 ;;
    esac
}
# yn VALUE [FALLBACK] - like yn_value, FALLBACK (N) for an empty/unknown value
yn() { yn_value "${1:-}" || echo "${2:-N}"; }

# preset NAME - 0 when the caller set the variable NAME (non-empty). Its
# question is then not asked, neither interactively nor in batch mode.
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }

# confirm "Question" [default Y|N] [DEFAULT_NAME]
# A preset DEFAULT_NAME answers the question without asking it.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# takes its default - DEFAULT_* from the caller or the built-in one - and
# prints what it took. A required value without a default is an error.
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (${pre})" >&2; exit 1; }
        echo "$q -> $( [[ "$def" == Y ]] && echo yes || echo no) (preset)"
        [[ "$def" == Y ]]; return
    fi
    if [[ -n "${BATCH:-}" ]]; then
        echo "$q -> $( [[ "$def" =~ ^[YyJj]$ ]] && echo yes || echo no)"
        [[ "$def" =~ ^[YyJj]$ ]]; return
    fi
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

# ask VAR "Question" [default] [required] [DEFAULT_NAME] - the answer lands in
# VAR; a preset DEFAULT_NAME is taken without asking
ask() {
    local __v=$1 __q=$2 __d=${3:-} __r=${4:-} __p=${5:-} __a
    if preset "$__p"; then
        printf -v "$__v" '%s' "${!__p}"; echo "${__q}: ${!__p} (preset)"; return 0
    fi
    if [[ -n "${BATCH:-}" ]]; then
        if [[ -z "$__d" && -n "$__r" ]]; then echo "!!! ${__q}: no value given (batch mode)" >&2; return 1; fi
        printf -v "$__v" '%s' "$__d"; echo "${__q}: ${__d:--}"; return 0
    fi
    while true; do
        read -rp "${__q}${__d:+ [${__d}]}: " __a || return 1
        __a=${__a:-$__d}
        [[ -n "$__a" || -z "$__r" ]] && break
        echo "  -> required"
    done
    printf -v "$__v" '%s' "$__a"
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
# Basics
# ---------------------------------------------------------------------------
ensure_ufw() {
    command -v ufw &>/dev/null && return 0
    echo "ufw is not installed."
    confirm "Install it now?" Y || return 1
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q </dev/null ufw >/dev/null
    command -v ufw &>/dev/null
}

# Read ufw's output in one go. Important because of "set -o pipefail": a reader
# that leaves early (head, grep -q, awk exit) sends SIGPIPE to the writer; the
# pipeline then reports 141, and depending on where that happens the script
# aborts or a check silently returns the wrong result.
ufw_status() { ufw status 2>/dev/null || true; }

is_active() { [[ "$(ufw_status | awk 'NR==1 {print $2}')" == "active" ]]; }

# The port the current session runs over - that one must never be walled off.
ssh_port() {
    local p=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    fi
    if [[ -z "$p" ]] && command -v sshd &>/dev/null; then
        p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}' || true)
    fi
    echo "${p:-22}"
}

on_ssh() { [[ -n "${SSH_CONNECTION:-}" ]]; }

ssh_rule_exists() {
    local p=$1 st
    st=$(ufw_status)
    grep -Eq "(^|[^0-9])${p}(/tcp)?[[:space:]]+(ALLOW|LIMIT)" <<<"$st" && return 0
    # The application profile covers SSH as well, but does not name a port.
    grep -Eq "^OpenSSH[[:space:]]+(ALLOW|LIMIT)" <<<"$st"
}

list_rules() {
    if ! is_active; then
        echo "(ufw is not active)"
        echo
    fi
    ufw status numbered 2>/dev/null || echo "(no output from ufw)"
}

# Text of a numbered rule, e.g. rule_text 3 -> "22/tcp   ALLOW IN  Anywhere"
rule_text() {
    ufw status numbered 2>/dev/null \
        | sed -n "s/^\[[[:space:]]*$1\][[:space:]]*//p" \
        | awk 'NR==1' || true
}

rule_count() {
    ufw status numbered 2>/dev/null | grep -c '^\[' || true
}

# ---------------------------------------------------------------------------
# Show all rules, enforced or not
# ---------------------------------------------------------------------------
# 'ufw status' is silent while ufw is off - the stored rules only show through
# 'ufw show added'. This view puts both side by side: what is stored, and
# whether any of it is currently enforced.
show_all_rules() {
    echo "==========================================="
    if is_active; then
        echo " Firewall: ACTIVE - the stored rules below are enforced."
    else
        echo " Firewall: NOT ACTIVE - the rules below are stored, but NONE of"
        echo " them is enforced. Every listening service is openly reachable."
    fi
    echo "==========================================="
    echo
    echo "--- Stored rules (ufw show added) ---"
    local added
    added=$(ufw show added 2>/dev/null | sed '1d') || true
    if [[ -n "$added" ]]; then echo "$added"; else echo "(none)"; fi
    echo
    if is_active; then
        echo "--- As enforced right now (ufw status verbose) ---"
        ufw status verbose 2>/dev/null || true
    else
        echo "('ufw status' shows nothing while the firewall is off - the list"
        echo " above therefore comes from 'ufw show added'. Menu item 7 turns"
        echo " the firewall on.)"
    fi
    echo
    pause
}

# ---------------------------------------------------------------------------
# Create a rule
# ---------------------------------------------------------------------------
# Assembles the ufw command and returns it through the global variable
# RULE_CMD. It is executed only after being shown and confirmed.
declare -a RULE_CMD=()

build_rule() {
    RULE_CMD=()

    echo "Action:"
    echo "  1) allow   permit"
    echo "  2) deny    drop (silently)"
    echo "  3) reject  refuse (with an error back to the sender)"
    echo "  4) limit   permit, but slow down brute force (max. 6 connections/30s)"
    local A ACTION
    read -rp "Choice [1]: " A
    case "${A:-1}" in
        2) ACTION=deny ;;
        3) ACTION=reject ;;
        4) ACTION=limit ;;
        *) ACTION=allow ;;
    esac

    echo
    echo "Direction:"
    echo "  1) incoming (in)"
    echo "  2) outgoing (out)"
    local D DIR
    read -rp "Choice [1]: " D
    [[ "${D:-1}" == "2" ]] && DIR=out || DIR=in

    echo
    echo "Interfaces: $(ip -br link show 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    local IFACE
    read -rp "Only on one interface (e.g. wg0, empty = all): " IFACE

    echo
    echo "Rule target:"
    echo "  1) port or port range"
    echo "  2) application profile (ufw app list)"
    echo "  3) everything (any port)"
    local T
    read -rp "Choice [1]: " T; T=${T:-1}

    local PORT="" PROTO="" APP=""
    case "$T" in
        2)
            echo
            ufw app list 2>/dev/null || true
            echo
            read -rp "Profile name (exactly as above, e.g. 'OpenSSH'): " APP
            while [[ -z "$APP" ]]; do read -rp "  -> required: " APP; done
            ;;
        3) ;;
        *)
            read -rp "Port or range (e.g. 443 or 6000:6010): " PORT
            while [[ ! "$PORT" =~ ^[0-9]+(:[0-9]+)?$ ]]; do
                read -rp "  -> port or from:to: " PORT
            done
            echo "  1) tcp   2) udp   3) both"
            local P
            read -rp "Protocol [1]: " P
            case "${P:-1}" in
                2) PROTO=udp ;;
                3) PROTO="" ;;
                *) PROTO=tcp ;;
            esac
            # ufw always wants a protocol with port ranges.
            if [[ "$PORT" == *:* && -z "$PROTO" ]]; then
                echo "  (a port range needs a protocol - tcp is used)"
                PROTO=tcp
            fi
            ;;
    esac

    echo
    local SRC DST CMT
    read -rp "Source (IP or CIDR, empty = from anywhere): " SRC
    read -rp "Destination IP on this host (empty = all addresses): " DST
    read -rp "Comment (optional, shows up in 'ufw status'): " CMT

    # --- assemble the command
    RULE_CMD=(ufw "$ACTION")

    if [[ -n "$IFACE" ]]; then
        # With an interface, ufw only understands the long form.
        RULE_CMD+=("$DIR" on "$IFACE")
        if [[ -n "$APP" ]]; then
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" app "$APP")
        elif [[ -z "$PORT" ]]; then
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}")
        else
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" port "$PORT")
            [[ -n "$PROTO" ]] && RULE_CMD+=(proto "$PROTO")
        fi
        [[ -n "$CMT" ]] && RULE_CMD+=(comment "$CMT")
        return 0
    fi

    [[ "$DIR" == "out" ]] && RULE_CMD+=(out)

    if [[ -n "$APP" ]]; then
        if [[ -n "$SRC" ]]; then
            RULE_CMD+=(from "$SRC" to "${DST:-any}" app "$APP")
        else
            RULE_CMD+=("$APP")
        fi
    elif [[ -z "$PORT" ]]; then
        RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}")
    elif [[ -z "$SRC" && -z "$DST" ]]; then
        # Short form, the way you would write it by hand
        if [[ -n "$PROTO" ]]; then RULE_CMD+=("${PORT}/${PROTO}"); else RULE_CMD+=("$PORT"); fi
    else
        RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" port "$PORT")
        [[ -n "$PROTO" ]] && RULE_CMD+=(proto "$PROTO")
    fi

    [[ -n "$CMT" ]] && RULE_CMD+=(comment "$CMT")
    return 0
}

add_rule() {
    echo "--- Existing rules ---"; list_rules; echo
    build_rule

    echo
    echo "The following command will be run:"
    printf '    %q ' "${RULE_CMD[@]}"; echo
    echo
    confirm "Run it?" Y || { echo "Cancelled."; pause; return; }

    if "${RULE_CMD[@]}"; then
        echo "Created."
    else
        echo "!!! ufw rejected the rule."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Delete a rule
# ---------------------------------------------------------------------------
delete_rule() {
    echo "--- Rules ---"; list_rules; echo
    (( $(rule_count) > 0 )) || { echo "There are no rules."; pause; return; }

    local N
    read -rp "Number of the rule to delete (empty = cancel): " N
    [[ -n "$N" ]] || return
    while [[ ! "$N" =~ ^[0-9]+$ ]]; do read -rp "  -> a number is expected: " N; done

    local txt; txt=$(rule_text "$N")
    [[ -n "$txt" ]] || { echo "There is no rule with number $N."; pause; return; }

    echo
    echo "Rule [$N]: $txt"

    local sp; sp=$(ssh_port)
    if on_ssh && grep -qE "(^|[^0-9])${sp}(/tcp)?[[:space:]]" <<<"$txt"; then
        echo
        echo "!!! This rule covers port ${sp} - your current SSH session runs over"
        echo "!!! it. Deleting it locks you out on the next connection attempt."
    fi
    echo

    confirm "Really delete?" || { echo "Cancelled."; pause; return; }

    # Between showing and deleting, the numbering may have changed (a parallel
    # window, v6 entries). So check again before deleting.
    if [[ "$(rule_text "$N")" != "$txt" ]]; then
        echo "!!! The numbering has changed - nothing deleted. Please look again."
        pause; return
    fi

    ufw --force delete "$N" || echo "!!! Deleting failed."
    pause
}

# ---------------------------------------------------------------------------
# Edit a rule = create the new one, then delete the old one
# ---------------------------------------------------------------------------
edit_rule() {
    echo "--- Rules ---"; list_rules; echo
    (( $(rule_count) > 0 )) || { echo "There are no rules."; pause; return; }

    echo "ufw cannot change rules. Editing therefore means: create the new rule,"
    echo "then delete the old one - in that order, so that no gap ever opens up."
    echo
    local N
    read -rp "Number of the rule to replace (empty = cancel): " N
    [[ -n "$N" ]] || return
    while [[ ! "$N" =~ ^[0-9]+$ ]]; do read -rp "  -> a number is expected: " N; done

    local txt; txt=$(rule_text "$N")
    [[ -n "$txt" ]] || { echo "There is no rule with number $N."; pause; return; }

    echo
    echo "Will be replaced: [$N] $txt"
    echo
    build_rule

    echo
    echo "New rule:"
    printf '    %q ' "${RULE_CMD[@]}"; echo
    echo "Deleted afterwards: $txt"
    echo
    confirm "Run it?" Y || { echo "Cancelled."; pause; return; }

    if ! "${RULE_CMD[@]}"; then
        echo "!!! New rule rejected - the old one stays unchanged."
        pause; return
    fi

    # Resolve the number again: the new rule may have shifted it.
    local i newnum=""
    for (( i=1; i<=$(rule_count); i++ )); do
        if [[ "$(rule_text "$i")" == "$txt" ]]; then newnum=$i; break; fi
    done

    if [[ -z "$newnum" ]]; then
        echo "!!! The old rule cannot be found any more (identical to the new one?)."
        echo "    Nothing was deleted - please check the list."
    else
        ufw --force delete "$newnum" || echo "!!! Deleting the old rule failed."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Recipe: SSH only through the VPN tunnel (WireGuard or Tailscale)
# ---------------------------------------------------------------------------
# Two stages, like the port change in ssh-setup: first add the narrow rule,
# test, and only then remove the open one. A single rule would be quickly
# written - the order is what keeps you from being locked out.
wg_listen_port() {
    local f
    for f in /etc/wireguard/wg0-interface.conf /etc/wireguard/wg0.conf; do
        [[ -f "$f" ]] || continue
        awk -F'= *' '/^ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "$f"
        return 0
    done
}

tunnel_rule_text() {
    local sp=$1 iface=$2
    ufw_status | grep -E "on ${iface}" | grep -E "(^|[^0-9])${sp}(/tcp)?[[:space:]]" | awk 'NR==1' || true
}

# WireGuard checks before the narrow rule goes in. The UDP port is mandatory:
# without it the tunnel never comes up - and then you cannot get in over it
# either. That is the classic mistake. Returns 1 when the recipe must abort.
check_wireguard() {
    local iface=$1 wgport
    wgport=$(wg_listen_port)
    echo "WireGuard port: ${wgport:-unknown}"
    echo

    if [[ -n "${wgport:-}" ]]; then
        if grep -qE "(^|[^0-9])${wgport}/udp[[:space:]]+(ALLOW|LIMIT)" <<<"$(ufw_status)"; then
            echo "  [x] ${wgport}/udp is open - the tunnel can be established."
        else
            echo "  [ ] !!! There is no rule for ${wgport}/udp. Without it the tunnel"
            echo "          never comes up, and with it nothing else does."
            if confirm "      Create the rule 'ufw allow ${wgport}/udp' now?" Y; then
                ufw allow "${wgport}/udp" comment 'WireGuard' || true
            else
                echo "      Cancelled - without an open WireGuard port this would be reckless."
                return 1
            fi
        fi
    else
        echo "  [ ] WireGuard port cannot be determined - please check yourself that it is open."
    fi

    if command -v wg &>/dev/null && [[ -n "$(wg show "$iface" peers 2>/dev/null)" ]]; then
        echo "  [x] The tunnel has configured peers."
    else
        echo "  [ ] No peer on ${iface} - so nobody could get in through the tunnel."
    fi
    return 0
}

# Tailscale checks. Unlike WireGuard, no inbound rule is required at all:
# connections are established from the inside, and where no direct path exists
# they fall back to Tailscale's relays (DERP) - reachable, just slower. The
# UDP port is therefore an OPTION for speed, never a requirement.
check_tailscale() {
    local iface=$1 tsport

    if systemctl is-active tailscaled &>/dev/null; then
        echo "  [x] tailscaled is running."
    else
        echo "  [ ] tailscaled is not running - nobody could get in through the tunnel."
    fi

    # First line of 'tailscale status' is this node itself; anything after it
    # is a peer.
    if command -v tailscale &>/dev/null \
        && [[ -n "$(tailscale status 2>/dev/null | awk 'NR>1' | grep . || true)" ]]; then
        echo "  [x] The tailnet has other devices."
    else
        echo "  [ ] No other device in the tailnet - so nobody could get in through it."
    fi

    echo
    echo "Tailscale needs NO open inbound port - the tunnel works behind a"
    echo "closed firewall, falling back to relays (DERP) when no direct path"
    echo "exists. Optionally its UDP port can be opened so that peers connect"
    echo "DIRECTLY instead of via relay - noticeably faster."
    echo
    echo "Opening it is OK: the port speaks exclusively WireGuard, and packets"
    echo "that are not authenticated with a key of your tailnet are discarded."
    echo
    if confirm "Open the Tailscale UDP port for direct (fast) connections?" Y; then
        read -rp "Tailscale UDP port [41641]: " tsport; tsport=${tsport:-41641}
        while [[ ! "$tsport" =~ ^[0-9]+$ ]]; do read -rp "  -> a port number is expected: " tsport; done
        if grep -qE "(^|[^0-9])${tsport}/udp[[:space:]]+(ALLOW|LIMIT)" <<<"$(ufw_status)"; then
            echo "  [x] ${tsport}/udp is already open."
        else
            ufw allow "${tsport}/udp" comment 'Tailscale direct' || true
        fi
    else
        echo "  Fine - SSH over the tunnel works anyway, at relay speed where"
        echo "  no direct path exists."
    fi
    return 0
}

ssh_via_tunnel() {
    local sp iface tun choice ans
    sp=$(ssh_port)

    echo "Which tunnel should carry SSH?"
    echo "  1) WireGuard (interface wg0)"
    echo "  2) Tailscale (interface tailscale0)"
    read -rp "Choice [1]: " choice
    if [[ "${choice:-1}" == "2" ]]; then
        tun="Tailscale"; iface="tailscale0"
    else
        tun="WireGuard"; iface="wg0"
    fi
    read -rp "${tun} interface [${iface}]: " ans; iface=${ans:-$iface}
    echo

    if ! ip link show "$iface" &>/dev/null; then
        echo "!!! There is no interface '$iface'. Set up ${tun} first."
        pause; return
    fi

    # --- stage 2: the narrow rule is already there, now the open one can go
    if [[ -n "$(tunnel_rule_text "$sp" "$iface")" ]]; then
        echo "The rule for SSH over ${iface} already exists:"
        echo "    $(tunnel_rule_text "$sp" "$iface")"
        echo
        echo "Second step: remove the open SSH rule, so that port ${sp} is closed"
        echo "from the outside."
        echo
        echo "!!! Only do this once logging in THROUGH THE TUNNEL has demonstrably"
        echo "!!! worked. After that SSH is no longer reachable without the tunnel."
        echo
        list_rules
        echo
        confirm "Find and delete the open SSH rule now?" \
            || { echo "Cancelled."; pause; return; }
        echo
        echo "Pick the number of the rule that allows port ${sp} from 'Anywhere'"
        echo "(NOT the one with '${iface}'):"
        delete_rule
        return
    fi

    # --- stage 1: create the narrow rule, leave the open one alone
    echo "SSH port: ${sp}   interface: ${iface}"
    if [[ "$tun" == "WireGuard" ]]; then
        check_wireguard "$iface" || { pause; return; }
    else
        check_tailscale "$iface"
    fi

    echo
    echo "This will be created:"
    echo "    ufw allow in on ${iface} to any port ${sp} proto tcp comment 'SSH via ${tun}'"
    echo
    echo "The existing open SSH rule is kept for now. Test first, then call this"
    echo "menu item again - it will then offer the cleanup."
    echo

    confirm "Create it?" Y || { echo "Cancelled."; pause; return; }

    if ufw allow in on "$iface" to any port "$sp" proto tcp comment "SSH via ${tun}"; then
        echo
        echo "Created. Now bring the tunnel up and test:"
        echo "    ssh -p ${sp} <user>@<tunnel-ip-of-this-server>"
    else
        echo "!!! ufw rejected the rule."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Firewall on/off, defaults, logging
# ---------------------------------------------------------------------------
toggle_ufw() {
    if is_active; then
        echo "ufw is active."
        echo
        echo "!!! Without a firewall every listening service is reachable from the network."
        confirm "Really deactivate?" || { echo "Cancelled."; pause; return; }
        ufw disable
        pause
        return
    fi

    echo "ufw is not active."
    local sp; sp=$(ssh_port)

    if ! ssh_rule_exists "$sp"; then
        echo
        echo "!!! There is no ALLOW rule for port ${sp} (SSH). With the default"
        echo "!!! policy 'deny incoming' you are locked out once it is switched on."
        echo
        if confirm "Create the rule 'ufw limit ${sp}/tcp' first?" Y; then
            ufw limit "${sp}/tcp" comment 'SSH' || true
        elif on_ssh; then
            echo
            echo "You are connected over SSH and there is no matching rule."
            confirm "Switch on anyway and lock yourself out?" \
                || { echo "Cancelled."; pause; return; }
        fi
    fi

    ufw --force enable
    pause
}

set_defaults() {
    echo "--- Current defaults ---"
    grep -E '^DEFAULT_(INPUT|OUTPUT|FORWARD)_POLICY' /etc/default/ufw 2>/dev/null || true
    echo
    echo "Incoming:"
    echo "  1) deny   (standard and recommended)"
    echo "  2) reject"
    echo "  3) allow  (everything open - only with a good reason)"
    local I
    read -rp "Choice [1]: " I
    case "${I:-1}" in
        2) ufw default reject incoming ;;
        3) confirm "Really allow EVERYTHING incoming?" && ufw default allow incoming || true ;;
        *) ufw default deny incoming ;;
    esac

    echo
    echo "Outgoing:"
    echo "  1) allow  (standard)"
    echo "  2) deny"
    local O
    read -rp "Choice [1]: " O
    case "${O:-1}" in
        2) ufw default deny outgoing ;;
        *) ufw default allow outgoing ;;
    esac
    pause
}

set_logging() {
    echo "Logging:"
    echo "  1) off      2) low (standard)   3) medium   4) high"
    local L
    read -rp "Choice [2]: " L
    case "${L:-2}" in
        1) ufw logging off ;;
        3) ufw logging medium ;;
        4) ufw logging high ;;
        *) ufw logging low ;;
    esac
    echo "The entries end up in /var/log/ufw.log."
    pause
}

show_apps() {
    echo "--- Application profiles ---"
    ufw app list 2>/dev/null || true
    echo
    read -rp "Profile for details (empty = back): " A
    [[ -n "$A" ]] || return
    ufw app info "$A" 2>/dev/null || echo "Unknown profile."
    pause
}

# ---------------------------------------------------------------------------
# Baseline setup (--setup)
# ---------------------------------------------------------------------------
# Services listening on something other than loopback: "proto port process"
listeners() {
    ss -H -tulpn 2>/dev/null | awk '{
        n = split($5, a, ":"); port = a[n]; addr = substr($5, 1, length($5) - length(port) - 1)
        if (addr ~ /^(127\.|\[::1\]|::1|\[::ffff:127\.)/) next
        proc = $7; sub(/^users:\(\("/, "", proc); sub(/".*/, "", proc)
        print $1, port, (proc == "" ? "-" : proc)
    }' | sort -u -k1,1 -k2,2n || true
}

other_firewall() {
    local s
    for s in firewalld nftables; do
        systemctl is-active --quiet "$s" 2>/dev/null && echo "$s"
    done
    return 0
}

# Any rule that lets the SSH port in - public, on an interface (tailnet-only),
# or the OpenSSH profile. Then the baseline leaves SSH alone.
ssh_any_rule() {
    local p=$1
    grep -Eq "^(${p}(/tcp)?( on [^[:space:]]+)?|OpenSSH)[[:space:]]+(ALLOW|LIMIT)" <<<"$(ufw_status)"
}

# port_allowed <port> <proto>: already let in from anywhere?
port_allowed() {
    grep -Eq "^${1}(/${2})?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+(IN[[:space:]]+)?Anywhere" <<<"$(ufw_status)"
}

# The presets are checked before anything is changed: an invalid one is an
# error, and nothing is written.
check_presets() {
    local v w bad=0
    for v in DEFAULT_SETUP_FIREWALL DEFAULT_IGNORE_OTHER_FW DEFAULT_OPEN_WEB DEFAULT_OPEN_TS_PORT; do
        preset "$v" || continue
        yn_value "${!v}" >/dev/null || { echo "!!! ${v}='${!v}': yes or no expected." >&2; bad=1; }
    done
    if preset DEFAULT_ALLOW_LISTENERS && [[ "$DEFAULT_ALLOW_LISTENERS" != "-" ]]; then
        for w in $DEFAULT_ALLOW_LISTENERS; do
            [[ "$w" =~ ^[0-9]+/(tcp|udp)$ ]] \
                || { echo "!!! DEFAULT_ALLOW_LISTENERS: '${w}' is not port/proto (e.g. 25/tcp)." >&2; bad=1; }
        done
    fi
    if preset DEFAULT_APP_PORTS && [[ "$DEFAULT_APP_PORTS" != "-" ]]; then
        for w in $DEFAULT_APP_PORTS; do
            [[ "$w" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] \
                || { echo "!!! DEFAULT_APP_PORTS: '${w}' is not a port (e.g. 8443/tcp, 6000:6010/tcp)." >&2; bad=1; }
        done
    fi
    return "$bad"
}

setup_baseline() {
    echo ">>> Firewall baseline (ufw)"
    echo "Default: everything incoming is blocked, except what is allowed below;"
    echo "outgoing is allowed. The SSH port of this session stays reachable."
    echo
    check_presets || { echo "Invalid preset - nothing changed." >&2; return 1; }
    if ! { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }; then
        confirm "Set up the firewall now? (No: leave it as it is)" "$(yn "${DEFAULT_SETUP_FIREWALL:-}" Y)" DEFAULT_SETUP_FIREWALL \
            || { echo "Left as it is, nothing changed."; return 2; }
    fi
    ensure_ufw || { echo "Nothing works here without ufw."; return 1; }

    local other; other=$(other_firewall | tr '\n' ' ')
    if [[ -n "${other// }" ]]; then
        echo "!!! Another firewall is active: ${other}"
        echo "!!! ufw on top of it gives two rule sets that contradict each other."
        confirm "Set up ufw anyway?" "$(yn "${DEFAULT_IGNORE_OTHER_FW:-}" N)" DEFAULT_IGNORE_OTHER_FW || return 1
    fi
    if command -v docker &>/dev/null; then
        echo "!!! Docker is installed: published container ports (-p) bypass ufw."
        echo "!!! Bind them to 127.0.0.1 unless they must be public."
        echo
    fi

    local sp; sp=$(ssh_port)
    echo "--- Services listening on the network (not only locally) ---"
    local -a lst=()
    mapfile -t lst < <(listeners)
    if (( ${#lst[@]} == 0 )); then
        echo "  (none)"
    else
        local i=0 l
        for l in "${lst[@]}"; do
            i=$((i + 1)); read -r pr po pc <<<"$l"
            printf '  %2d) %-4s %-6s %s%s\n' "$i" "$pr" "$po" "$pc" \
                "$( [[ "$po" == "$sp" && "$pr" == tcp* ]] && echo "   (SSH - handled separately)")"
        done
    fi
    echo

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    # SSH first, before anything is enabled.
    if ssh_any_rule "$sp"; then
        echo "SSH ${sp}/tcp: a rule exists already - left as it is."
    else
        ufw limit "${sp}/tcp" comment 'SSH (rate-limited)' >/dev/null
        echo "SSH ${sp}/tcp: allowed, rate-limited (6 connections / 30 s per address)."
    fi

    # Web server ports - offered always, default yes where something listens.
    echo
    local wdef=N
    printf '%s\n' "${lst[@]}" | grep -Eq '^tcp6? (80|443) ' && wdef=Y
    [[ -n "${DEFAULT_OPEN_WEB:-}" ]] && wdef=$(yn "$DEFAULT_OPEN_WEB" "$wdef")
    if confirm "Open 80/tcp and 443/tcp (web server, HTTPS certificates)?" "$wdef" DEFAULT_OPEN_WEB; then
        ufw allow 80/tcp comment 'HTTP' >/dev/null
        ufw allow 443/tcp comment 'HTTPS' >/dev/null
        echo "  allowed 80/tcp, 443/tcp"
    fi

    # Which of the listening services must be reachable from the internet?
    local -a cand=() l2
    for l2 in "${lst[@]}"; do
        read -r pr po pc <<<"$l2"
        pr=${pr%6}
        [[ "$po" == "$sp" && "$pr" == tcp ]] && continue
        [[ "$po" == 80 || "$po" == 443 ]] && [[ "$pr" == tcp ]] && continue
        port_allowed "$po" "$pr" && continue
        cand+=("$pr $po $pc")
    done
    if (( ${#cand[@]} > 0 )); then
        echo
        echo "These listen on the network but are not allowed (yet). Only what"
        echo "has to be reachable from the WHOLE internet belongs here - admin"
        echo "and monitoring ports go over the VPN/tailnet."
        local j=0 c
        for c in "${cand[@]}"; do j=$((j + 1)); printf '  %2d) %s\n' "$j" "$c"; done
        # DEFAULT_ALLOW_LISTENERS ("25/tcp 51820/udp") -> the matching numbers
        local sdef="" w
        for w in ${DEFAULT_ALLOW_LISTENERS:-}; do
            j=0
            for c in "${cand[@]}"; do
                j=$((j + 1)); read -r pr po pc <<<"$c"
                [[ "$w" == "${po}/${pr}" ]] && sdef+="${sdef:+ }$j"
            done
        done
        local sel
        # A preset (or "-" = none) is taken without asking.
        preset DEFAULT_ALLOW_LISTENERS && echo "Allow which publicly?: ${DEFAULT_ALLOW_LISTENERS} (preset)"
        if preset DEFAULT_ALLOW_LISTENERS || [[ -n "${BATCH:-}" ]]; then
            for w in ${DEFAULT_ALLOW_LISTENERS:-}; do
                [[ "$w" == "-" ]] && continue
                printf '%s\n' "${cand[@]}" | awk -v w="$w" '$2 "/" $1 == w {f=1} END {exit !f}' \
                    || echo "  '${w}' from DEFAULT_ALLOW_LISTENERS: not listening or already allowed - skipped"
            done
        fi
        if preset DEFAULT_ALLOW_LISTENERS; then
            sel=$sdef
        elif [[ -n "${BATCH:-}" ]]; then
            ask sel "Allow which publicly? (numbers)" "$sdef"
        else
            read -rp "Allow which publicly? (numbers, space-separated, empty = none): " sel
        fi
        local n
        for n in $sel; do
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#cand[@]} )) || { echo "  skipped '$n'"; continue; }
            read -r pr po pc <<<"${cand[$((n - 1))]}"
            ufw allow "${po}/${pr}" comment "$pc" >/dev/null && echo "  allowed ${po}/${pr} (${pc})"
        done
    fi

    echo
    echo "Further public ports (not listening yet, e.g. for a service set up"
    echo "later). Format: 8443/tcp 51820/udp 6000:6010/tcp; empty = none."
    local more
    if preset DEFAULT_APP_PORTS; then
        more=$DEFAULT_APP_PORTS; echo "Further ports: ${more} (preset)"
        [[ "$more" == "-" ]] && more=""
    elif [[ -n "${BATCH:-}" ]]; then
        ask more "Further ports" "${DEFAULT_APP_PORTS:-}"
    else
        read -rp "Further ports [${DEFAULT_APP_PORTS:-}]: " more
        more=${more:-${DEFAULT_APP_PORTS:-}}
    fi
    local p
    for p in $more; do
        [[ "$p" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || { echo "  skipped invalid '$p'"; continue; }
        ufw allow "$p" >/dev/null && echo "  allowed ${p}"
    done

    if ip link show tailscale0 &>/dev/null; then
        echo
        echo "Tailscale works without any open port (relayed). 41641/udp allows"
        echo "direct connections - faster, but one more open port."
        local tsdef=N; [[ -n "${BATCH:-}" ]] && tsdef=Y
        if confirm "Open 41641/udp for direct tailnet connections?" "$(yn "${DEFAULT_OPEN_TS_PORT:-}" "$tsdef")" DEFAULT_OPEN_TS_PORT; then
            ufw allow 41641/udp comment 'Tailscale direct' >/dev/null
        fi
    fi

    if ! is_active; then
        echo
        echo "Enabling ufw - the SSH rule is in place, this session survives."
        ufw --force enable >/dev/null
    else
        ufw reload >/dev/null || true
    fi
    echo
    ufw status verbose || true
    echo
    echo "Changes later: $(basename "$0") (menu). A scan from THIS machine proves"
    echo "nothing - check from outside: nmap -Pn -p- <public-ip>"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall firewall management"
    echo
    if ! command -v ufw &>/dev/null; then
        echo "ufw is not installed at all - nothing to do."
        pause; return
    fi
    echo "This tool creates nothing of its own - it manages ufw. So the only thing"
    echo "to remove is the state of ufw itself:"
    echo
    echo "  - reset all rules (ufw reset)                           [asked]"
    echo "  - deactivate ufw                                        [asked]"
    echo
    echo "The ufw package stays installed. Manually: apt purge ufw"
    echo
    echo "!!! Without a firewall every listening service is openly reachable. If"
    echo "!!! only single rules should go, menu item 3 is the right way."
    echo

    confirm "Continue?" || { echo "Cancelled."; pause; return; }

    make_backup ufw /etc/ufw /etc/default/ufw || { pause; return; }

    if confirm "Reset all rules?"; then
        # 'ufw reset' switches ufw off itself and additionally leaves dated
        # copies of the previous rules in /etc/ufw.
        ufw --force reset
        echo "Rules reset."
    fi

    if is_active && confirm "Deactivate ufw?"; then
        ufw disable
    fi

    echo
    echo "Done. Current state:"
    ufw status verbose 2>/dev/null | head -5 || true
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Firewall (ufw)"
        echo "==========================================="
        if is_active; then
            echo "Status: active   |   rules: $(rule_count)   |   SSH port: $(ssh_port)"
        else
            echo "Status: NOT active   |   SSH port: $(ssh_port)"
        fi
        echo
        list_rules
        echo
        echo " 0) Baseline setup (default deny, SSH, web, listening services)"
        echo " 1) Create a rule"
        echo " 2) Edit a rule (replace)"
        echo " 3) Delete a rule"
        echo " 4) Make SSH reachable only over the VPN (WireGuard/Tailscale)"
        echo " 5) Show all rules (stored, and whether they are enforced)"
        echo " 6) Show application profiles"
        echo " 7) $(is_active && echo "Deactivate" || echo "Activate") the firewall"
        echo " 8) Defaults (default incoming/outgoing)"
        echo " 9) Logging"
        echo "10) Uninstall"
        echo "11) Quit"
        read -rp "Choice: " CH || exit 0
        case "$CH" in
            0)  setup_baseline || true; pause ;;
            1)  add_rule ;;
            2)  edit_rule ;;
            3)  delete_rule ;;
            4)  ssh_via_tunnel ;;
            5)  show_all_rules ;;
            6)  show_apps ;;
            7)  toggle_ufw ;;
            8)  set_defaults ;;
            9)  set_logging ;;
            10) uninstall ;;
            11) exit 0 ;;
            *)  sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --setup)     setup_baseline ;;
    --status)    command -v ufw &>/dev/null && ufw status verbose || echo "ufw is not installed." ;;
    --uninstall) uninstall ;;
    "")          ensure_ufw || { echo "Nothing works here without ufw."; exit 1; }
                 main_menu ;;
    *)           echo "Usage: $0 [--setup|--status|--uninstall|--version]"; exit 1 ;;
esac
