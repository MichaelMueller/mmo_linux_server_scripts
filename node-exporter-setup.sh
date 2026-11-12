#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# node-exporter-setup.sh - Prometheus node exporter, reachable only in the tailnet
#
# Installs prometheus-node-exporter (+ the textfile collectors, e.g. pending
# apt updates), binds it to the tailnet IP instead of all interfaces, starts it
# after tailscaled and opens the port in ufw on tailscale0 only. The metrics
# (CPU, RAM, disks, network, systemd units, apt) are scraped by the central
# Prometheus over the tailnet; alerting happens there, not on this machine.
#
# Modes: (no argument) = interactive menu
#        --setup       = run the setup dialogue once, without the menu
#        --status      = current state on stdout
#        --test        = fetch the metrics over the tailnet IP
#        --uninstall   = uninstall
#
# Presets: a DEFAULT_* that is set is taken without a question (and wins over
# the stored value); unset ones are asked - in batch mode, BATCH=1, nothing is
# asked and every question takes its default:
#   DEFAULT_SCRAPE_FROM   tailnet IP of the Prometheus server, '-' = the
#                         whole tailnet (unset: the stored one, else the whole tailnet)
#   DEFAULT_ALT_PORT      port to use when 9100 is taken by another process (9101)
set -uo pipefail

# --version must come before the root check so it answers without sudo.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Started from a version directory (<base>/<version>/, see build-bundle.sh):
# paths written into cron and systemd go through <base>/current, so an update
# or a rollback switches them along.
if [[ -L "$DIR/../current" && "$(readlink -f "$DIR/../current")" == "$(readlink -f "$DIR")" ]]; then
    DIR="$(cd "$DIR/../current" && pwd)"
fi
CONF="$DIR/node-exporter-setup.conf"

PKG=prometheus-node-exporter
PKG_COLLECTORS=prometheus-node-exporter-collectors
SERVICE=prometheus-node-exporter
DEFAULTS=/etc/default/prometheus-node-exporter
DROPIN_DIR=/etc/systemd/system/prometheus-node-exporter.service.d
DROPIN="$DROPIN_DIR/tailnet.conf"
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
UFW_COMMENT="node_exporter Monitoring"

# ---------------------------------------------------------------------------
# Configuration / defaults
# ---------------------------------------------------------------------------
PORT=9100
SCRAPE_FROM=""      # tailnet IP of the Prometheus server; empty = whole tailnet
EXTRA_ARGS=""       # further node exporter flags, e.g. --collector.processes

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
# A preset wins over the stored value.
if [[ -n "${DEFAULT_SCRAPE_FROM:-}" ]]; then
    SCRAPE_FROM=$DEFAULT_SCRAPE_FROM
    [[ "$SCRAPE_FROM" == "-" ]] && SCRAPE_FROM=""
fi

save_conf() {
    cat > "$CONF" <<EOF
# node-exporter-setup configuration
PORT=${PORT}
SCRAPE_FROM="${SCRAPE_FROM}"
EXTRA_ARGS="${EXTRA_ARGS}"
EOF
    chmod 644 "$CONF"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# Presets: a DEFAULT_* variable that is set (not empty) is a fixed value - its
# question is not asked, neither interactively nor in batch mode; the tool
# prints "<question>: <value> (preset)" instead. An invalid preset is an error.
# Unset ones are asked; in batch mode (BATCH=1, set by base-setup.sh) every
# such question takes its default - the built-in or stored one - and prints
# what it took. A required value without a default is an error.
# preset NAME -> 0 when the caller set that DEFAULT_* variable (non-empty)
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# preset_tag NAME -> " (preset)" when NAME is a preset, else nothing
preset_tag() { if preset "${1:-}"; then echo " (preset)"; fi; }
# yn_value VALUE -> Y or N; fails for anything that is not yes/no
yn_value() {
    case "${1:-}" in
        Y|y|[Yy]es|YES|J|j|[Jj]a|1|[Tt]rue) echo Y ;;
        N|n|[Nn]o|NO|[Nn]ein|0|[Ff]alse)    echo N ;;
        *) return 1 ;;
    esac
}
# confirm "Question" [default Y|N] [DEFAULT_NAME]
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (preset ${pre})" >&2; exit 1; }
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
# ask VAR "Question" [default] [required] [DEFAULT_NAME]  - the answer lands in VAR
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
# batch_bad "what" "value" "allowed" [DEFAULT_NAME]  - an unusable preset or
# batch-mode default
batch_bad() {
    if preset "${4:-}"; then echo "!!! ${1}: '${2}' is not ${3} (preset ${4})" >&2
    else echo "!!! ${1}: '${2}' is not ${3} (batch mode)" >&2; fi
    return 1
}

tailnet_ip() { command -v tailscale &>/dev/null && tailscale ip -4 2>/dev/null | head -1; }
ufw_active() { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }
installed()  { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
listener()   { ss -H -ltnp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {print $4, $6}'; }

# The address the exporter is configured to listen on (from ARGS).
configured_addr() {
    [[ -f "$DEFAULTS" ]] || return 0
    grep -oE -- '--web.listen-address=[^ "]+' "$DEFAULTS" 2>/dev/null | head -1 | cut -d= -f2
}

is_setup() { installed "$PKG" && [[ -f "$DROPIN" ]]; }

ufw_rule_numbers() {
    ufw status numbered 2>/dev/null | grep -F "$UFW_COMMENT" \
        | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    local tip addr
    tip=$(tailnet_ip); addr=$(configured_addr)
    echo "Tailnet:     ${tip:-not connected} (tailscaled $(systemctl is-active tailscaled 2>/dev/null || true))"
    echo "Package:     $(installed "$PKG" && dpkg-query -W -f='${Version}' "$PKG" || echo "not installed")$(installed "$PKG_COLLECTORS" && echo " + collectors")"
    echo "Service:     $(systemctl is-active "$SERVICE" 2>/dev/null || true), $(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
    echo "Configured:  ${addr:-(package default: all interfaces)}"
    echo "Listening:   $(listener | head -1 || true)"
    if [[ -n "$addr" && -n "$tip" && "${addr%:*}" != "$tip" ]]; then
        echo "!!! Bound to ${addr%:*}, but the tailnet IP is ${tip} - run the setup again."
    fi
    if [[ "${addr%:*}" == "0.0.0.0" || ( -z "$addr" ) ]] && installed "$PKG"; then
        echo "!!! Listens on all interfaces - port ${PORT} may be reachable publicly."
    fi
    if ufw_active; then
        local r; r=$(ufw status 2>/dev/null | grep -F "$UFW_COMMENT" | grep -v '(v6)' || true)
        echo "ufw:         ${r:-no rule for port ${PORT}}"
    else
        echo "ufw:         not active"
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo
    echo "--- Current state ---"
    show_status
    echo

    local tip; tip=$(tailnet_ip)
    if [[ -z "$tip" ]]; then
        echo "!!! No tailnet IP. The exporter is bound to the tailnet IP, so the"
        echo "!!! server has to be in the tailnet first (tailscale-setup.sh)."
        return 1
    fi

    local other
    other=$(ss -H -ltnp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$"' | grep -vE 'prometheus-node|node_exporter' || true)
    if [[ -n "$other" ]]; then
        echo "!!! Port ${PORT} is used by another process:"
        echo "$other" | sed 's/^/!!!   /'
        local p=${DEFAULT_ALT_PORT:-9101}
        ask p "Other port for the exporter" "${DEFAULT_ALT_PORT:-9101}" "" DEFAULT_ALT_PORT
        PORT=${p:-9101}
        if [[ -n "${BATCH:-}" ]] || preset DEFAULT_ALT_PORT; then
            if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
                batch_bad "Other port for the exporter" "$PORT" "a port number" DEFAULT_ALT_PORT
                return 1
            fi
        fi
    fi

    local r=$SCRAPE_FROM
    echo "Prometheus scrapes this exporter over the tailnet. The firewall rule"
    echo "can allow the whole tailnet or only the Prometheus server."
    ask r "Tailnet IP of the Prometheus server (empty = whole tailnet)" "$SCRAPE_FROM" "" DEFAULT_SCRAPE_FROM
    [[ "$r" == "-" ]] && SCRAPE_FROM="" || SCRAPE_FROM=$r
    if [[ -n "$SCRAPE_FROM" && ! "$SCRAPE_FROM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ -n "${BATCH:-}" ]] || preset DEFAULT_SCRAPE_FROM; then
            batch_bad "Prometheus server" "$SCRAPE_FROM" "an IPv4 address" DEFAULT_SCRAPE_FROM
            return 1
        fi
        echo "Not an IPv4 address - allowing the whole tailnet."
        SCRAPE_FROM=""
    fi
    save_conf

    # 1. Packages
    if ! installed "$PKG" || ! installed "$PKG_COLLECTORS"; then
        echo ">>> Installing ${PKG} ${PKG_COLLECTORS}..."
        apt-get update -qq || echo "!!! apt-get update failed - trying the install anyway."
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" "$PKG_COLLECTORS" \
            || { echo "!!! Installation failed."; return 1; }
    else
        echo "Packages already installed."
    fi

    # 2. Bind to the tailnet IP - the package default is every interface.
    [[ -f "$DEFAULTS" && ! -f "${DEFAULTS}.orig" ]] && cp -p "$DEFAULTS" "${DEFAULTS}.orig"
    mkdir -p "$TEXTFILE_DIR"
    cat > "$DEFAULTS" <<EOF
# Written by node-exporter-setup.sh - the original is ${DEFAULTS}.orig
# Bound to the tailnet IP only; run node-exporter-setup.sh again if it changes.
ARGS="--web.listen-address=${tip}:${PORT} --collector.systemd --collector.textfile.directory=${TEXTFILE_DIR}${EXTRA_ARGS:+ ${EXTRA_ARGS}}"
EOF
    echo "Bound to ${tip}:${PORT}."

    # 3. Start after tailscaled. Until the tailnet IP exists the bind fails -
    # Restart= retries until it is there.
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<'EOF'
# Written by node-exporter-setup.sh: listens on the tailnet IP, so it has to
# wait for tailscaled - and retry until the IP is up.
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=always
RestartSec=15
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE" || echo "!!! Restart failed - see: journalctl -u ${SERVICE}"
    # The apt metrics come from a timer of the collectors package - start it
    # and run it once, so they are there right away and not only at its next run.
    if systemctl list-unit-files prometheus-node-exporter-apt.timer &>/dev/null; then
        systemctl enable --now prometheus-node-exporter-apt.timer >/dev/null 2>&1 || true
        systemctl start prometheus-node-exporter-apt.service >/dev/null 2>&1 || true
    fi

    # 4. Firewall: only on tailscale0. Old rules of this tool are replaced.
    if ufw_active; then
        local n
        for n in $(ufw_rule_numbers); do ufw --force delete "$n" >/dev/null; done
        if [[ -n "$SCRAPE_FROM" ]]; then
            ufw allow in on tailscale0 from "$SCRAPE_FROM" to any port "$PORT" proto tcp comment "$UFW_COMMENT" >/dev/null
            echo "ufw: port ${PORT}/tcp allowed on tailscale0 from ${SCRAPE_FROM}."
        else
            ufw allow in on tailscale0 to any port "$PORT" proto tcp comment "$UFW_COMMENT" >/dev/null
            echo "ufw: port ${PORT}/tcp allowed on tailscale0."
        fi
    else
        echo "ufw is not active - the bind to the tailnet IP keeps the port off the"
        echo "public interface anyway. The rule is added when you run this again"
        echo "after enabling ufw."
    fi

    echo
    sleep 2
    run_test
}

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
run_test() {
    local tip url m rc=0
    tip=$(tailnet_ip)
    [[ -n "$tip" ]] || { echo "!!! No tailnet IP."; return 1; }
    url="http://${tip}:${PORT}/metrics"
    echo ">>> ${url}"
    if ! m=$(curl -fsS --max-time 5 "$url" 2>&1); then
        echo "!!! Not reachable: ${m}"
        echo "!!! Check: systemctl status ${SERVICE}; journalctl -u ${SERVICE}"
        return 1
    fi
    printf '  node_* metrics:     %s\n' "$(grep -c '^node_' <<<"$m")"
    if grep -q '^node_systemd_unit_state' <<<"$m"; then
        echo "  systemd collector:  ok"
    else
        echo "  systemd collector:  !!! no node_systemd_unit_state"; rc=1
    fi
    if grep -q '^apt_' <<<"$m"; then
        echo "  apt (textfile):     ok"
    else
        echo "  apt (textfile):     not yet - the collector timer writes it within"
        echo "                      a few minutes (systemctl list-timers 'prometheus-*')"
    fi
    echo
    echo "In Prometheus, scrape target: ${tip}:${PORT}  (or $(hostname -s):${PORT} via MagicDNS)"
    return $rc
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo "Removes the tailnet binding, the start order and the ufw rule."
    confirm "Uninstall the node exporter setup?" || return 0
    if ufw_active; then
        local n
        for n in $(ufw_rule_numbers); do ufw --force delete "$n" >/dev/null; done
        echo "ufw rule removed."
    fi
    rm -f "$DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null || true
    [[ -f "${DEFAULTS}.orig" ]] && mv -f "${DEFAULTS}.orig" "$DEFAULTS"
    systemctl daemon-reload
    if confirm "Also remove the packages ${PKG} ${PKG_COLLECTORS}?"; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PKG" "$PKG_COLLECTORS" || true
    elif installed "$PKG"; then
        echo "Packages kept - the exporter now listens with the package default"
        echo "(all interfaces); stopping it."
        systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    fi
    rm -f "$CONF"
    echo "Uninstalled."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Prometheus node exporter (tailnet only)"
        echo "==========================================="
        show_status
        echo
        echo "1) Set up / edit settings"
        echo "2) Test the metrics endpoint"
        echo "3) Uninstall"
        echo "4) Quit"
        local ch; read -rp "Choice: " ch
        case "$ch" in
            1) configure; pause ;;
            2) run_test; pause ;;
            3) uninstall; pause ;;
            4|q) exit 0 ;;
        esac
    done
}

case "${1:-}" in
    --setup)     configure ;;
    --status)    show_status ;;
    --test)      run_test ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--setup|--status|--test|--uninstall|--version]"; exit 1 ;;
esac
