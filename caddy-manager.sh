#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# caddy-manager.sh - Caddy vhost management (TLS termination on this server)
# Host types: static files, redirect, reverse proxy
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.3.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/caddy-manager.conf"
CRON_FILE=/etc/cron.d/caddy-manager

# Overridable so the generators can be exercised outside /etc.
CADDY_DIR=${CADDY_DIR:-/etc/caddy}
SITES_DIR="$CADDY_DIR/sites.d"
CADDYFILE="$CADDY_DIR/Caddyfile"
META_DIR="$CADDY_DIR/sites-meta.d"

# ---------------------------------------------------------------------------
# Settings / defaults
# ---------------------------------------------------------------------------
ACME_MAIL=""
DESEC_ENABLED=0                       # 1 = the deSEC DNS challenge is set up
DESEC_ENV_FILE="$CADDY_DIR/desec.env"
DEFAULT_ALLOW_CIDRS="100.64.0.0/10"
LOG_FILE="$DIR/var/caddy-manager.log"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

# Same rule as in the other tools: a relative path belongs to the script, not
# to wherever the caller happens to stand - cron stands somewhere else.
case "$LOG_FILE" in
    /*) ;;
    "") LOG_FILE="$DIR/var/caddy-manager.log" ;;
    *)  LOG_FILE="$DIR/${LOG_FILE#./}" ;;
esac

DESEC_MODULE=github.com/caddy-dns/desec
DESEC_MODULE_ID=dns.providers.desec
DROPIN_DIR=/etc/systemd/system/caddy.service.d
DESEC_DROPIN="$DROPIN_DIR/desec-env.conf"
# Tailscale hands out addresses from the CGNAT range, which Caddy's
# 'private_ranges' shortcut does NOT cover - hence its own constant.
TAILNET_CIDR="100.64.0.0/10"

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

CADDY_LOG_DIR=/var/log/caddy

save_conf() {
    cat > "$CONF" <<EOF
# caddy-manager configuration
ACME_MAIL="${ACME_MAIL}"
DESEC_ENABLED=${DESEC_ENABLED}
DESEC_ENV_FILE="${DESEC_ENV_FILE}"
DEFAULT_ALLOW_CIDRS="${DEFAULT_ALLOW_CIDRS}"
LOG_FILE="${LOG_FILE}"
EOF
    chmod 644 "$CONF"
}

# A wildcard host ("*.example.com") would otherwise put a literal asterisk
# into the log file name.
log_name() { printf '%s' "${1//\*/wildcard}"; }

log_line() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s
' "$(date '+%F %T')" "$1" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# deSEC DNS challenge
# ---------------------------------------------------------------------------
# Why this is more than "write two lines into the Caddyfile": the caddy package
# from the apt repo carries the standard modules only, so the binary has to be
# swapped for one that includes the provider - and an 'apt upgrade' of that
# package puts the standard build back and takes the module with it. Nothing
# breaks on that day: the certificates are still valid, and only the renewal
# weeks later fails. That is the worst way for a problem to surface, so there is
# a daily check that repairs it and writes down that it had to.
has_dns_module() { caddy list-modules 2>/dev/null | grep -qx "$DESEC_MODULE_ID"; }

# The token is checked against the API before it is stored: a wrong token is
# otherwise only noticed by Let's Encrypt, and that costs rate limit budget.
desec_token_works() {
    curl -fsS -m 15 -o /dev/null         -H "Authorization: Token $1" https://desec.io/api/v1/domains/ 2>/dev/null
}

ensure_dns_module() {
    if has_dns_module; then
        echo "Module ${DESEC_MODULE_ID}: present."
        return 0
    fi
    echo ">>> Adding ${DESEC_MODULE} to the caddy binary..."
    if caddy add-package "$DESEC_MODULE"; then
        systemctl restart caddy >/dev/null 2>&1 || true
        if has_dns_module; then
            echo ">>> Module installed."
            return 0
        fi
    fi
    echo "!!! The module could not be added."
    echo "!!! The apt build carries the standard modules only. Alternative:"
    echo "!!!     xcaddy build --with ${DESEC_MODULE}"
    echo "!!! and point the service at that binary."
    return 1
}

# Runs from cron. Deliberately quiet while everything is in order - the log is
# there for the day it was not.
check_plugin() {
    (( DESEC_ENABLED == 1 )) || return 0
    has_dns_module && return 0

    log_line "module ${DESEC_MODULE_ID} is gone (apt upgrade?) - reinstalling"
    if caddy add-package "$DESEC_MODULE" >>"$LOG_FILE" 2>&1; then
        systemctl restart caddy >/dev/null 2>&1 || true
        if has_dns_module; then
            log_line "module reinstalled, caddy restarted"
            return 0
        fi
    fi
    log_line "!!! reinstalling failed - certificates will not renew until this is fixed"
    return 1
}

write_cron() {
    cat > "$CRON_FILE" <<EOF
# caddy-manager - checks daily that the deSEC module survived an apt upgrade
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root ${SELF} --check-plugin >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

desec_setup() {
    is_setup || setup_caddy

    echo ">>> deSEC DNS challenge"
    echo
    echo "Needed: an API token from https://desec.io -> Token management. A token"
    echo "restricted to the zone is enough. It is stored in ${DESEC_ENV_FILE}"
    echo "(0640, readable by caddy only) and reaches Caddy as an environment"
    echo "variable - the Caddyfile is world-readable and no place for a token."
    echo
    local tok
    read -rsp "deSEC API token: " tok; echo
    tok=$(trim "$tok")
    [[ -z "$tok" ]] && { echo "Nothing entered - cancelled."; pause; return; }

    if command -v curl &>/dev/null; then
        if desec_token_works "$tok"; then
            echo "The deSEC API accepts the token."
        else
            echo "!!! The deSEC API rejected the token."
            confirm "Store it anyway?" || { pause; return; }
        fi
    else
        echo "(curl is missing here - the token cannot be tested)"
    fi

    ( umask 077; printf 'DESEC_TOKEN=%s
' "$tok" > "$DESEC_ENV_FILE" )
    chown root:caddy "$DESEC_ENV_FILE" 2>/dev/null || true
    chmod 640 "$DESEC_ENV_FILE"

    mkdir -p "$DROPIN_DIR"
    cat > "$DESEC_DROPIN" <<EOF
[Service]
EnvironmentFile=${DESEC_ENV_FILE}
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true

    ensure_dns_module || { pause; return; }

    DESEC_ENABLED=1
    save_conf
    write_cron
    systemctl restart caddy >/dev/null 2>&1 || true

    echo
    echo ">>> Ready. A host can now be given the DNS challenge instead of the"
    echo ">>> HTTP one, and wildcard hosts (*.example.com) become possible."
    echo ">>> A daily cron check guards the module against apt upgrades."
    pause
}

desec_remove() {
    local users=0
    users=$(grep -l '^ACME=dns' "$META_DIR"/*.meta 2>/dev/null | wc -l) || users=0
    echo
    echo "Removed are the token, the systemd drop-in and the cron check."
    if (( users > 0 )); then
        echo "!!! ${users} host(s) fetch their certificate over DNS. Their config"
        echo "!!! keeps 'tls { dns desec ... }' and will fail to renew until they"
        echo "!!! are reconfigured to the HTTP challenge."
    fi
    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    rm -f "$DESEC_ENV_FILE" "$DESEC_DROPIN" "$CRON_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    DESEC_ENABLED=0
    save_conf
    reload_caddy || true
    echo "Removed. The module stays in the binary - it does no harm unused."
    pause
}

desec_menu() {
    while true; do
        clear
        echo "=== TLS / DNS challenge (deSEC) ==="
        echo "Set up: $( (( DESEC_ENABLED == 1 )) && echo yes || echo no)"
        echo "Module: $(has_dns_module && echo present || echo MISSING)"
        echo "Token:  $([[ -s "$DESEC_ENV_FILE" ]] && echo "$DESEC_ENV_FILE" || echo '(none)')"
        echo "Cron:   $([[ -f "$CRON_FILE" ]] && echo "daily" || echo '(none)')"
        echo
        echo "1) Set up (or replace the token)"
        echo "2) Test the token against the deSEC API"
        echo "3) Check the module, reinstall it if it is missing"
        echo "4) Remove the DNS challenge"
        echo "5) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1) desec_setup ;;
            2)  if [[ ! -s "$DESEC_ENV_FILE" ]]; then
                    echo "No token stored."
                elif ! command -v curl &>/dev/null; then
                    echo "curl is missing - cannot test."
                else
                    local t; t=$(sed -n 's/^DESEC_TOKEN=//p' "$DESEC_ENV_FILE" | head -1)
                    if desec_token_works "$t"; then
                        echo "The deSEC API accepts the token."
                    else
                        echo "!!! The deSEC API rejected the token - renewals will fail."
                    fi
                fi
                pause ;;
            3)  ensure_dns_module || true; pause ;;
            4)  desec_remove ;;
            5)  return ;;
            *)  sleep 1 ;;
        esac
    done
}


# A site address that is only a port (Debian ships ':80') matches every host
# without a vhost of its own and collides with what Caddy sets up on :80 for
# the real domains.
has_catchall() { grep -Eq '^[[:space:]]*:[0-9]+[[:space:]]*\{' "$CADDYFILE" 2>/dev/null; }

is_setup() {
    command -v caddy &>/dev/null \
        && [[ -d "$SITES_DIR" && -d "$META_DIR" ]] \
        && grep -q "import ${SITES_DIR}/\*.caddy" "$CADDYFILE" 2>/dev/null \
        && ! has_catchall
}

setup_caddy() {
    echo ">>> First-time setup of Caddy"

    if ! command -v caddy &>/dev/null; then
        echo ">>> Installing Caddy from the official repo..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y caddy >/dev/null
    fi

    ensure_dirs

    # The address comes from our own configuration now; the sed over the
    # Caddyfile only picks it up once from an installation predating that.
    local cur_mail=$ACME_MAIL m
    [[ -z "$cur_mail" && -f "$CADDYFILE" ]]         && cur_mail=$(sed -n 's/^[[:space:]]*email[[:space:]]\+//p' "$CADDYFILE" | head -1)
    read -rp "Mail address for Let's Encrypt (optional, recommended)${cur_mail:+ [$cur_mail]}: " m
    ACME_MAIL=${m:-$cur_mail}

    # Back up unconditionally: what follows replaces the whole file, including
    # anything hand-written and Debian's stock ':80' block.
    if [[ -f "$CADDYFILE" ]]; then
        local bak="$CADDYFILE.orig.$(date +%s)"
        cp "$CADDYFILE" "$bak"
        echo "Previous $CADDYFILE saved as $bak"
        has_catchall && echo "    (its ':80' catch-all block is dropped - it would answer for every host)"
    fi

    {
        if [[ -n "$ACME_MAIL" ]]; then
            echo "{"
            echo "    email ${ACME_MAIL}"
            echo "}"
            echo
        fi
        echo "import ${SITES_DIR}/*.caddy"
    } > "$CADDYFILE"

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi

    save_conf

    systemctl enable caddy >/dev/null 2>&1 || true
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || true
    systemctl restart caddy
    echo ">>> Setup complete."
}

reload_caddy() {
    ensure_dirs
    if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        return 0
    else
        echo "!!! The Caddyfile is broken:"
        caddy validate --config "$CADDYFILE" --adapter caddyfile || true
        return 1
    fi
}

# printf instead of echo: echo's newline would be turned into a '_' by tr and
# end up in the file name.
site_file() { printf '%s/%s.caddy\n' "$SITES_DIR" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9.-' '_')"; }
meta_file() { printf '%s/%s.meta\n'  "$META_DIR"  "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9.-' '_')"; }

# The meta directory arrived after the first releases: installations set up
# before that pass is_setup() and would never see the mkdir in setup_caddy().
# The log directory belongs here too: caddy runs as the 'caddy' user, and a
# vhost whose "output file" it cannot open takes down the whole service, not
# just that one site.
ensure_dirs() {
    mkdir -p "$SITES_DIR" "$META_DIR" "$CADDY_LOG_DIR"
    # -R on purpose: a log file left behind by root is enough to stop the
    # service, the directory alone being writable does not help.
    chown -R caddy:caddy "$CADDY_LOG_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_LOG_DIR" 2>/dev/null || true
}

# Older versions appended a '_' to every file name (see site_file above).
# Rename those once so show/edit/delete find their hosts again.
migrate_legacy_names() {
    local f n
    shopt -s nullglob
    for f in "$SITES_DIR"/*_.caddy "$META_DIR"/*_.meta; do
        n="${f%_.*}.${f##*.}"
        [[ -e "$n" ]] || mv "$f" "$n"
    done
    shopt -u nullglob
}

# strip leading/trailing whitespace
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# hostname, optionally with a leading wildcard label (*.example.com)
valid_domain() {
    [[ "$1" =~ ^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# ask_domain <prompt>  -> trimmed domain on stdout (loops until it is valid)
ask_domain() {
    local prompt=$1 d
    while true; do
        read -rp "$prompt" d
        d=$(trim "$d")
        if [[ -z "$d" ]]; then
            echo "  -> required." >&2
        elif ! valid_domain "$d"; then
            echo "  -> '$d' is not a valid domain (no spaces, letters/digits/./- only)." >&2
        else
            printf '%s' "$d"
            return 0
        fi
    done
}

list_hosts() {
    if [[ ! -d "$SITES_DIR" ]] || ! ls "$SITES_DIR"/*.caddy &>/dev/null; then
        echo "(no hosts created)"
        return
    fi
    printf "%-32s %-9s %-4s %-8s %s\n" "DOMAIN" "TYPE" "TLS" "ACCESS" "TARGET"
    printf "%-32s %-9s %-4s %-8s %s\n" "--------------------------------" "---------" "----" "--------" "--------------------"
    for f in "$SITES_DIR"/*.caddy; do
        local d m acc
        # first non-comment line that opens a site block; a site can carry
        # several addresses, so keep them all
        d=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
                 /\{[[:space:]]*$/ {sub(/[[:space:]]*\{[[:space:]]*$/, "");
                                    gsub(/[[:space:]]*,[[:space:]]*|[[:space:]]+/, ","); print; exit}' "$f")
        [[ -n "$d" ]] || d="(unparsed: $(basename "$f"))"
        m=$(meta_file "${d%%,*}")
        if [[ -f "$m" ]]; then
            # load_meta rather than 'grep | cut': under pipefail a meta without
            # the key would fail the pipeline and, with set -e, the script.
            load_meta "${d%%,*}"
            if [[ -n "$M_ALLOW" ]]; then
                acc="limited"
            elif [[ -n "$M_PPATHS" ]]; then
                acc="paths"
            else
                acc="public"
            fi
            printf "%-32s %-9s %-4s %-8s %s\n" "$d" "${M_TYPE:-?}" "${M_ACME:-http}" "$acc" "$M_TARGET"
        else
            printf "%-32s %-9s %-4s %-8s %s\n" "$d" "?" "?" "?" "?"
        fi
    done
}

# ---------------------------------------------------------------------------
# Metadata of a host
# ---------------------------------------------------------------------------
# The overview reads it, and the wizard uses it as the defaults of a
# reconfiguration - without that, "Edit -> Reconfigure" silently throws away
# every answer given the first time round.
#
# Entries written by older versions carry TYPE and TARGET only; the remaining
# keys then stay empty, which is exactly the behaviour of a host without
# restrictions.
load_meta() {
    local m k v
    m=$(meta_file "$1")
    M_TYPE=""; M_TARGET=""; M_ACME="http"; M_ALLOW=""; M_PPATHS=""; M_PCIDRS=""
    [[ -f "$m" ]] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            TYPE)          M_TYPE=$v ;;
            TARGET)        M_TARGET=$v ;;
            ACME)          M_ACME=$v ;;
            ALLOW_CIDRS)   M_ALLOW=$v ;;
            PROTECT_PATHS) M_PPATHS=$v ;;
            PROTECT_CIDRS) M_PCIDRS=$v ;;
        esac
    done < "$m"
    return 0
}

# save_meta <domain> <type> <target> - the rest comes from the globals the ask_*
# functions have just set.
save_meta() {
    {
        printf 'TYPE=%s\n'          "$2"
        printf 'TARGET=%s\n'        "$3"
        printf 'ACME=%s\n'          "$ACME_MODE"
        printf 'ALLOW_CIDRS=%s\n'   "$ACCESS_CIDRS"
        printf 'PROTECT_PATHS=%s\n' "$PROTECT_PATHS"
        printf 'PROTECT_CIDRS=%s\n' "$PROTECT_CIDRS"
    } > "$(meta_file "$1")"
}

# ---------------------------------------------------------------------------
# Certificate: HTTP or DNS challenge
# ---------------------------------------------------------------------------
# Sets ACME_MODE. A wildcard has no choice: the HTTP challenge proves ownership
# of one name, never of '*.example.com' - only a DNS record can do that.
ask_acme() {
    local domain=$1 def=${2:-http}
    ACME_MODE=http
    if [[ "$domain" == \*.* ]]; then
        ACME_MODE=dns
        echo "Wildcard host -> certificate over the deSEC DNS challenge (the only way)."
        return 0
    fi
    (( DESEC_ENABLED == 1 )) || return 0
    echo
    echo "The DNS challenge needs no reachable port 80 - which is what a host"
    echo "that is not open to the internet depends on."
    confirm "Fetch the certificate over the deSEC DNS challenge?" \
        "$([[ "$def" == dns ]] && echo Y || echo N)" && ACME_MODE=dns
    return 0
}

emit_tls() {
    [[ "$ACME_MODE" == dns ]] || return 0
    echo "    tls {"
    echo "        dns desec {"
    echo "            token {env.DESEC_TOKEN}"
    echo "        }"
    echo "    }"
}

# ---------------------------------------------------------------------------
# Access: the whole host, or single paths
# ---------------------------------------------------------------------------
# IPv4 or IPv6, prefix length optional. Not a full validator - it is here to
# keep a typo out of the Caddyfile, where it would surface as a broken config
# instead of as a wrong answer.
valid_cidr() {
    local c=$1 ip=${1%%/*} len="" o
    [[ "$c" == */* ]] && len=${c#*/}
    [[ -n "$len" && ! "$len" =~ ^[0-9]{1,3}$ ]] && return 1
    if [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        for o in ${ip//./ }; do (( o <= 255 )) || return 1; done
        [[ -z "$len" ]] || (( len <= 32 )) || return 1
        return 0
    fi
    if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        [[ -z "$len" ]] || (( len <= 128 )) || return 1
        return 0
    fi
    return 1
}

# Echoes the result on stdout - prompts and complaints go to stderr, so these
# two can be used in a command substitution ('read -rp' prompts on stderr).
ask_cidrs() {
    local def=$1 in_ ok c
    echo "  CIDR notation, space-separated. 'private_ranges' may be mixed in," >&2
    echo "  e.g.: private_ranges 192.168.30.0/24" >&2
    while true; do
        read -rp "  Networks${def:+ [$def]}: " in_
        in_=$(trim "${in_:-$def}")
        [[ -z "$in_" ]] && return 0
        ok=1
        for c in $in_; do
            [[ "$c" == private_ranges ]] && continue
            valid_cidr "$c" || { echo "  -> '$c' is not a valid network." >&2; ok=0; }
        done
        (( ok )) && { printf '%s' "$in_"; return 0; }
    done
}

ask_paths() {
    local def=$1 in_ p out=""
    read -rp "  Paths, space-separated (e.g. /admin /metrics)${def:+ [$def]}: " in_
    in_=$(trim "${in_:-$def}")
    for p in $in_; do
        [[ "$p" == /* ]] || p="/$p"
        p=${p%\*}
        out+="${out:+ }$p"
    done
    printf '%s' "$out"
}

# Sets ACCESS_CIDRS, PROTECT_PATHS, PROTECT_CIDRS. Shared by all three host
# types, which is why it lives here and not three times over.
ask_access() {
    local def_cidrs=$1 def_paths=$2 def_pcidrs=$3
    ACCESS_CIDRS=""; PROTECT_PATHS=""; PROTECT_CIDRS=""

    echo
    echo "--- Access ---"
    echo "Who may reach this host?"
    echo "  1) Everyone"
    echo "  2) Only the tailnet (${TAILNET_CIDR})"
    echo "  3) Only private networks (private_ranges)"
    echo "  4) Tailnet and private networks"
    echo "  5) Own list of networks${DEFAULT_ALLOW_CIDRS:+ (default: ${DEFAULT_ALLOW_CIDRS})}"

    local d=1
    [[ -n "$def_cidrs" ]] && d=5
    [[ "$def_cidrs" == "$TAILNET_CIDR" ]] && d=2
    [[ "$def_cidrs" == "private_ranges" ]] && d=3
    [[ "$def_cidrs" == "$TAILNET_CIDR private_ranges" ]] && d=4

    local c
    read -rp "Choice [$d]: " c; c=${c:-$d}
    case "$c" in
        2) ACCESS_CIDRS="$TAILNET_CIDR" ;;
        3) ACCESS_CIDRS="private_ranges" ;;
        4) ACCESS_CIDRS="$TAILNET_CIDR private_ranges" ;;
        5) ACCESS_CIDRS=$(ask_cidrs "${def_cidrs:-$DEFAULT_ALLOW_CIDRS}") ;;
        *) ACCESS_CIDRS="" ;;
    esac

    if [[ -n "$ACCESS_CIDRS" ]]; then
        echo "  -> everything from anywhere else gets a 403."
        echo "     The ACME HTTP challenge is not affected: Caddy answers that"
        echo "     ahead of the site. A firewall in front of it would be."
        return 0
    fi

    # Only worth asking while the host as a whole is open - otherwise the
    # narrower rule could never match anything the wider one let through.
    echo
    if confirm "Restrict single paths to certain networks?" \
        "$([[ -n "$def_paths" ]] && echo Y || echo N)"; then
        PROTECT_PATHS=$(ask_paths "$def_paths")
        if [[ -n "$PROTECT_PATHS" ]]; then
            echo "Networks that may reach those paths:"
            PROTECT_CIDRS=$(ask_cidrs "${def_pcidrs:-$DEFAULT_ALLOW_CIDRS}")
            if [[ -z "$PROTECT_CIDRS" ]]; then
                PROTECT_PATHS=""
                echo "  (no network given - the path restriction is dropped)"
            fi
        fi
    fi
    return 0
}

# The conditions inside a named matcher are ANDed: these paths AND coming from
# outside. 'respond' sorts ahead of reverse_proxy and file_server in Caddy's
# default directive order, so it answers before the handler ever runs.
emit_access() {
    if [[ -n "$ACCESS_CIDRS" ]]; then
        echo "    @denied not remote_ip ${ACCESS_CIDRS}"
        echo "    respond @denied 403"
    elif [[ -n "$PROTECT_PATHS" && -n "$PROTECT_CIDRS" ]]; then
        local p globs=""
        for p in $PROTECT_PATHS; do globs+="${globs:+ }${p}*"; done
        echo "    @protected {"
        echo "        path ${globs}"
        echo "        not remote_ip ${PROTECT_CIDRS}"
        echo "    }"
        echo "    respond @protected 403"
    fi
}

# --- Type 1: static files -----------------------------------------------------
build_static() {
    local domain=$1
    load_meta "$domain"
    local def_root=${M_TARGET:-/var/www/${domain}}
    read -rp "Directory (root) [${def_root}]: " ROOT
    ROOT=${ROOT:-$def_root}

    if [[ ! -d "$ROOT" ]]; then
        read -rp "The directory does not exist. Create it? [Y/n]: " C
        C=${C:-Y}
        if [[ "$C" =~ ^[YyJj]$ ]]; then
            mkdir -p "$ROOT"
            echo "<h1>${domain}</h1>" > "$ROOT/index.html"
            chown -R caddy:caddy "$ROOT" 2>/dev/null || true
        fi
    fi

    read -rp "Enable directory listing (browse)? [y/N]: " BROWSE
    read -rp "Set up basic auth? [y/N]: " BAUTH

    local authblock=""
    if [[ "$BAUTH" =~ ^[YyJj]$ ]]; then
        read -rp "  Username: " BUSER
        read -rsp "  Password: " BPASS; echo
        local HASH
        HASH=$(caddy hash-password --plaintext "$BPASS")
        authblock=$(printf '    basic_auth {\n        %s %s\n    }\n' "$BUSER" "$HASH")
    fi

    ask_acme "$domain" "$M_ACME"
    ask_access "$M_ALLOW" "$M_PPATHS" "$M_PCIDRS"

    {
        echo "${domain} {"
        emit_tls
        emit_access
        echo "    root * ${ROOT}"
        [[ -n "$authblock" ]] && echo "$authblock"
        echo "    encode zstd gzip"
        echo "    file_server$([[ "$BROWSE" =~ ^[YyJj]$ ]] && echo " browse")"
        echo "    log {"
        echo "        output file \"${CADDY_LOG_DIR}/$(log_name "$domain").log\""
        echo "    }"
        echo "}"
    } > "$(site_file "$domain")"

    save_meta "$domain" static "$ROOT"
}

# --- Type 2: redirect ---------------------------------------------------------
build_redirect() {
    local domain=$1
    load_meta "$domain"
    read -rp "Target URL (e.g. https://example.com)${M_TARGET:+ [$M_TARGET]}: " TARGET
    TARGET=${TARGET:-$M_TARGET}
    while [[ -z "$TARGET" ]]; do read -rp "  -> required: " TARGET; done

    echo "  1) 301 permanent"
    echo "  2) 302 temporary"
    read -rp "Kind [1]: " RC; RC=${RC:-1}
    local CODE="permanent"
    [[ "$RC" == "2" ]] && CODE="temporary"

    read -rp "Carry path + query over as well (e.g. /foo?bar)? [Y/n]: " KEEP
    KEEP=${KEEP:-Y}
    local SUFFIX=""
    [[ "$KEEP" =~ ^[YyJj]$ ]] && SUFFIX='{uri}'

    ask_acme "$domain" "$M_ACME"
    ask_access "$M_ALLOW" "$M_PPATHS" "$M_PCIDRS"

    {
        echo "${domain} {"
        emit_tls
        emit_access
        echo "    redir ${TARGET}${SUFFIX} ${CODE}"
        echo "}"
    } > "$(site_file "$domain")"

    save_meta "$domain" redirect "$TARGET"
}

# --- Type 3: reverse proxy ----------------------------------------------------
build_proxy() {
    local domain=$1
    load_meta "$domain"
    read -rp "Backend (e.g. 10.10.0.2:32000, several space-separated)${M_TARGET:+ [$M_TARGET]}: " BACKENDS
    BACKENDS=${BACKENDS:-$M_TARGET}
    while [[ -z "$BACKENDS" ]]; do read -rp "  -> required: " BACKENDS; done

    read -rp "Does the backend speak HTTPS? [y/N]: " ISTLS
    read -rp "Limit to a path prefix (empty = everything, e.g. /api): " PATHMATCH

    local opts=()

    if [[ "$ISTLS" =~ ^[YyJj]$ ]]; then
        opts+=("        transport http {")
        opts+=("            tls")
        read -rp "  Skip verification of the backend certificate (self-signed)? [y/N]: " NOVERIFY
        [[ "$NOVERIFY" =~ ^[YyJj]$ ]] && opts+=("            tls_insecure_skip_verify")
        opts+=("        }")
    fi

    read -rp "WebSocket/streaming mode (buffering off, long timeouts)? [y/N]: " WS
    if [[ "$WS" =~ ^[YyJj]$ ]]; then
        opts+=("        flush_interval -1")
    fi

    # Caddy forwards the original Host by default; {upstream_hostport} is what
    # replaces it with the backend's address.
    read -rp "Pass the original Host header to the backend? [Y/n]: " KEEPHOST
    KEEPHOST=${KEEPHOST:-Y}
    if [[ ! "$KEEPHOST" =~ ^[YyJj]$ ]]; then
        opts+=("        header_up Host {upstream_hostport}")
    fi
    opts+=("        header_up X-Real-IP {remote_host}")

    read -rp "Enable a health check? [y/N]: " HC
    if [[ "$HC" =~ ^[YyJj]$ ]]; then
        read -rp "  Health path [/]: " HCPATH; HCPATH=${HCPATH:-/}
        opts+=("        health_uri ${HCPATH}")
        opts+=("        health_interval 30s")
    fi

    local backend_count
    backend_count=$(echo "$BACKENDS" | wc -w)
    if (( backend_count > 1 )); then
        echo "  Load balancing policy: 1) round_robin  2) least_conn  3) ip_hash"
        read -rp "  Choice [1]: " LB; LB=${LB:-1}
        case "$LB" in
            2) opts+=("        lb_policy least_conn") ;;
            3) opts+=("        lb_policy ip_hash") ;;
            *) opts+=("        lb_policy round_robin") ;;
        esac
    fi

    read -rp "Put basic auth in front? [y/N]: " BAUTH
    local authblock=""
    if [[ "$BAUTH" =~ ^[YyJj]$ ]]; then
        read -rp "  Username: " BUSER
        read -rsp "  Password: " BPASS; echo
        local HASH; HASH=$(caddy hash-password --plaintext "$BPASS")
        authblock=$(printf '    basic_auth {\n        %s %s\n    }' "$BUSER" "$HASH")
    fi

    ask_acme "$domain" "$M_ACME"
    ask_access "$M_ALLOW" "$M_PPATHS" "$M_PCIDRS"

    {
        echo "${domain} {"
        emit_tls
        emit_access
        [[ -n "$authblock" ]] && echo "$authblock"
        echo "    encode zstd gzip"
        if [[ -n "$PATHMATCH" ]]; then
            echo "    reverse_proxy ${PATHMATCH}* ${BACKENDS} {"
        else
            echo "    reverse_proxy ${BACKENDS} {"
        fi
        printf '%s\n' "${opts[@]}"
        echo "    }"
        echo "    log {"
        echo "        output file \"${CADDY_LOG_DIR}/$(log_name "$domain").log\""
        echo "    }"
        echo "}"
    } > "$(site_file "$domain")"

    save_meta "$domain" proxy "$BACKENDS"
}

create_host() {
    is_setup || setup_caddy
    ensure_dirs

    echo "--- Existing hosts ---"; list_hosts; echo
    DOMAIN=$(ask_domain "Domain (e.g. app.example.com): ")
    while [[ -f "$(site_file "$DOMAIN")" ]]; do
        echo "'$DOMAIN' already exists."
        DOMAIN=$(ask_domain "Domain: ")
    done

    # The HTTP challenge proves one name; '*.example.com' can only be proved
    # by a DNS record. Refusing here beats a host that looks fine and then
    # never gets a certificate.
    if [[ "$DOMAIN" == \*.* ]] && (( DESEC_ENABLED != 1 )); then
        echo
        echo "A wildcard host needs the DNS challenge, which is not set up yet."
        echo "Set up deSEC first (main menu, 'TLS / DNS challenge')."
        pause
        return
    fi

    echo
    echo "What should this host do?"
    echo "  1) Serve static files"
    echo "  2) Redirect to another URL"
    echo "  3) Reverse proxy to a backend"
    read -rp "Choice [3]: " TYPE; TYPE=${TYPE:-3}
    echo

    case "$TYPE" in
        1) build_static   "$DOMAIN" ;;
        2) build_redirect "$DOMAIN" ;;
        3) build_proxy    "$DOMAIN" ;;
        *) echo "Invalid."; pause; return ;;
    esac

    echo
    echo "--- Generated config ---"
    cat "$(site_file "$DOMAIN")"
    echo "------------------------"

    if reload_caddy; then
        echo "Host '$DOMAIN' is active. The certificate is fetched automatically (DNS has to point at this server)."
    else
        rm -f "$(site_file "$DOMAIN")" "$(meta_file "$DOMAIN")"
        reload_caddy || true
        echo "Rolled back."
    fi
    pause
}

show_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain: " DOMAIN; DOMAIN=$(trim "$DOMAIN")
    local f; f=$(site_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }
    load_meta "$DOMAIN"
    echo
    echo "Type: ${M_TYPE:-?}   certificate: ${M_ACME:-http}   target: ${M_TARGET:-?}"
    [[ -n "$M_ALLOW" ]]  && echo "Reachable only from: ${M_ALLOW}"
    [[ -n "$M_PPATHS" ]] && echo "Paths ${M_PPATHS} only from: ${M_PCIDRS}"
    echo; cat "$f"; echo
    pause
}

edit_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain to edit: " DOMAIN; DOMAIN=$(trim "$DOMAIN")
    ensure_dirs
    local f m; f=$(site_file "$DOMAIN"); m=$(meta_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    echo
    echo "1) Reconfigure (wizard, type can be changed)"
    echo "2) Open the config file directly in an editor"
    echo "3) Cancel"
    read -rp "Choice: " CH

    cp "$f" "$f.bak"
    [[ -f "$m" ]] && cp "$m" "$m.bak"

    case "$CH" in
        1)
            echo
            echo "  1) Static files"
            echo "  2) Redirect"
            echo "  3) Reverse proxy"
            read -rp "Type: " T
            case "$T" in
                1) build_static   "$DOMAIN" ;;
                2) build_redirect "$DOMAIN" ;;
                3) build_proxy    "$DOMAIN" ;;
                *) echo "Invalid."; rm -f "$f.bak" "$m.bak"; pause; return ;;
            esac
            ;;
        2)
            "${EDITOR:-nano}" "$f"
            ;;
        *)
            rm -f "$f.bak" "$m.bak"
            return
            ;;
    esac

    if reload_caddy; then
        rm -f "$f.bak" "$m.bak"
        echo "Updated."
        cat "$f"
    else
        mv "$f.bak" "$f"
        [[ -f "$m.bak" ]] && mv "$m.bak" "$m"
        reload_caddy || true
        echo "Rolled back."
    fi
    pause
}

delete_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain to delete: " DOMAIN; DOMAIN=$(trim "$DOMAIN")
    local f; f=$(site_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    read -rp "Really delete '$DOMAIN'? [y/N]: " C
    if [[ "$C" =~ ^[YyJj]$ ]]; then
        rm -f "$f" "$(meta_file "$DOMAIN")"
        reload_caddy || true
        echo "Deleted. (The certificate stays in Caddy's data directory.)"
    else
        echo "Cancelled."
    fi
    pause
}

uninstall() {
    echo ">>> Uninstall Caddy management"
    echo

    local n=0 orig=""
    [[ -d "$SITES_DIR" ]] && n=$(find "$SITES_DIR" -name '*.caddy' 2>/dev/null | wc -l) || true
    orig=$(ls -1t "$CADDYFILE".orig.* 2>/dev/null | head -1 || true)

    echo "The following will be removed:"
    echo "  - ${n} vhost(s) in $SITES_DIR"
    echo "  - metadata in $META_DIR"
    if [[ -n "$orig" ]]; then
        echo "  - $CADDYFILE is restored from $orig"
    else
        echo "  - $CADDYFILE is deleted (no .orig backup present)"
    fi
    echo "  - the caddy service is stopped and disabled"
    echo "  - $CONF, the cron check and the systemd drop-in"
    [[ -f "$DESEC_ENV_FILE" ]] && echo "  - the deSEC token $DESEC_ENV_FILE            [asked]"
    echo "  - /var/lib/caddy - CONTAINS THE TLS CERTIFICATES        [asked]"
    echo "  - /var/log/caddy                                        [asked]"
    echo "  - ufw rules 80/tcp and 443/tcp                          [asked]"
    echo
    echo "The caddy package and the apt repo stay. To remove them manually:"
    echo "    apt purge caddy && rm -f /etc/apt/sources.list.d/caddy-stable.list \\"
    echo "        /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup caddy "$CADDYFILE" "$SITES_DIR" "$META_DIR" "$CONF" "$DESEC_ENV_FILE"         || { pause; return; }

    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true

    rm -rf "$SITES_DIR" "$META_DIR"
    rm -f "$CONF" "$CRON_FILE" "$DESEC_DROPIN"
    systemctl daemon-reload >/dev/null 2>&1 || true

    # The token is a credential, not a config file: it gets its own question,
    # and it is in the backup either way.
    if [[ -f "$DESEC_ENV_FILE" ]] && confirm "Delete the deSEC token ${DESEC_ENV_FILE}?"; then
        rm -f "$DESEC_ENV_FILE"
    fi

    if [[ -n "$orig" ]]; then
        mv "$orig" "$CADDYFILE"
        echo "$CADDYFILE restored from $orig."
    else
        rm -f "$CADDYFILE"
    fi

    if [[ -d /var/lib/caddy ]]; then
        echo
        echo "Note: /var/lib/caddy holds the certificates issued by Let's Encrypt."
        echo "After deleting them they are requested again - with many domains"
        echo "that can run into Let's Encrypt's rate limit."
        if confirm "Delete /var/lib/caddy (certificates)?"; then
            if make_backup caddy-certificates /var/lib/caddy; then
                rm -rf /var/lib/caddy
            else
                echo "The certificates stay in place."
            fi
        fi
    fi

    if [[ -d /var/log/caddy ]] && confirm "Delete /var/log/caddy (access logs)?"; then
        rm -rf /var/log/caddy
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        echo "Careful: port 443 may also be used by the nginx relay."
        if confirm "Remove the ufw rules 80/tcp and 443/tcp?"; then
            ufw delete allow 80/tcp  >/dev/null 2>&1 || true
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi
    fi

    echo
    echo "Removed."
    pause
}

main_menu() {
    [[ -d "$SITES_DIR" ]] && migrate_legacy_names
    while true; do
        clear
        echo "==========================================="
        echo " Caddy management (TLS termination)"
        echo "==========================================="
        if is_setup; then
            echo "Status: set up | caddy: $(systemctl is-active caddy)"
            (( DESEC_ENABLED == 1 ))                 && echo "DNS challenge: deSEC | module: $(has_dns_module && echo present || echo MISSING)"
        else
            echo "Status: not set up (happens with the first host)"
        fi
        echo
        list_hosts
        echo
        echo "1) Create a host"
        echo "2) Show a host"
        echo "3) Edit a host"
        echo "4) Delete a host"
        echo "5) TLS / DNS challenge (deSEC)"
        echo "6) Check the config (caddy validate)"
        echo "7) Logs (journalctl -u caddy)"
        echo "8) Uninstall"
        echo "9) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) create_host ;;
            2) show_host ;;
            3) edit_host ;;
            4) delete_host ;;
            5) desec_menu ;;
            6) caddy validate --config "$CADDYFILE" --adapter caddyfile || true; pause ;;
            7) journalctl -u caddy -n 50 --no-pager || true; pause ;;
            8) uninstall ;;
            9) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check-plugin) check_plugin ;;
    --uninstall)    uninstall ;;
    "")             main_menu ;;
    *)              echo "Usage: $0 [--check-plugin|--uninstall|--version]"; exit 1 ;;
esac
