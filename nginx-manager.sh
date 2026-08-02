#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# nginx-manager.sh - nginx as a pure TCP relay with SNI-based host routing
# TLS is NOT terminated, it is passed through to the backend.
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.0.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

HOSTS_DIR=/etc/nginx/stream-hosts.d
STREAM_CONF=/etc/nginx/stream.conf
MAIN_CONF=/etc/nginx/nginx.conf

MARK_BEGIN='# >>> nginx-manager >>>'
MARK_END='# <<< nginx-manager <<<'

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

is_setup() {
    [[ -f "$STREAM_CONF" ]] && grep -q "include ${STREAM_CONF};" "$MAIN_CONF" 2>/dev/null
}

setup_nginx() {
    echo ">>> First-time setup of the nginx stream relay"

    if ! command -v nginx &>/dev/null || ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
        echo ">>> Installing nginx-extras (contains the stream module)..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y nginx-extras >/dev/null
    fi

    mkdir -p "$HOSTS_DIR"

    read -rp "Fallback backend for unknown/missing SNI (empty = drop the connection): " FALLBACK

    if [[ -n "$FALLBACK" ]]; then
        echo "default    ${FALLBACK};" > "$HOSTS_DIR/00-default.map"
    else
        echo "default    \"\";" > "$HOSTS_DIR/00-default.map"
    fi

    cat > "$STREAM_CONF" <<EOF
map \$ssl_preread_server_name \$backend {
    include ${HOSTS_DIR}/*.map;
}

server {
    listen 443;
    listen [::]:443;
    proxy_pass \$backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 300s;
}
EOF

    # Markers, so the uninstall can cut the block out again exactly
    if ! grep -q "include ${STREAM_CONF};" "$MAIN_CONF"; then
        cat >> "$MAIN_CONF" <<EOF

${MARK_BEGIN}
stream {
    include ${STREAM_CONF};
}
${MARK_END}
EOF
    fi

    # Remove the default vhost on :443 from the http block, otherwise the port clashes
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        if grep -q "listen 443" /etc/nginx/sites-enabled/default 2>/dev/null; then
            echo ">>> Disabling the http default vhost (port clash on 443)..."
            rm -f /etc/nginx/sites-enabled/default
        fi
    fi

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 443/tcp
    fi

    nginx -t
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    echo ">>> Setup complete."
}

reload_nginx() {
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        return 0
    else
        echo "!!! The nginx configuration is broken:"
        nginx -t || true
        return 1
    fi
}

list_hosts() {
    if [[ ! -d "$HOSTS_DIR" ]] || ! ls "$HOSTS_DIR"/*.map &>/dev/null; then
        echo "(no hosts created)"
        return
    fi
    printf "%-40s %s\n" "SNI / DOMAIN" "BACKEND"
    printf "%-40s %s\n" "----------------------------------------" "--------------------"
    for f in "$HOSTS_DIR"/*.map; do
        local d b
        d=$(awk '{print $1}' "$f")
        b=$(awk '{print $2}' "$f" | tr -d ';"')
        [[ -z "$b" ]] && b="(drop)"
        printf "%-40s %s\n" "$d" "$b"
    done
}

host_file() {
    echo "$HOSTS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9.-' '_').map"
}

create_host() {
    is_setup || setup_nginx

    echo "--- Existing hosts ---"; list_hosts; echo
    read -rp "Domain (SNI, e.g. app.example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]] || [[ -f "$(host_file "$DOMAIN")" ]]; do
        echo "Invalid or already taken."
        read -rp "Domain: " DOMAIN
    done

    read -rp "Backend (IP:port, e.g. 10.10.0.2:443): " BACKEND
    while [[ ! "$BACKEND" =~ ^[^:]+:[0-9]+$ ]]; do
        echo "Format: IP:port"
        read -rp "Backend: " BACKEND
    done

    echo "${DOMAIN}    ${BACKEND};" > "$(host_file "$DOMAIN")"

    if reload_nginx; then
        echo "Host '$DOMAIN' -> $BACKEND created."
        echo "Note: the certificate for '$DOMAIN' has to live on $BACKEND."
    else
        rm -f "$(host_file "$DOMAIN")"
        echo "Rolled back."
    fi
    pause
}

edit_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain to edit: " DOMAIN
    local f; f=$(host_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    local cur; cur=$(awk '{print $2}' "$f" | tr -d ';"')
    read -rp "Backend [$cur]: " NEW; NEW=${NEW:-$cur}

    cp "$f" "$f.bak"
    echo "${DOMAIN}    ${NEW};" > "$f"

    if reload_nginx; then
        rm -f "$f.bak"
        echo "Updated -> $NEW"
    else
        mv "$f.bak" "$f"
        reload_nginx || true
        echo "Rolled back."
    fi
    pause
}

delete_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain to delete: " DOMAIN
    local f; f=$(host_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    read -rp "Really delete '$DOMAIN'? [y/N]: " C
    if [[ "$C" =~ ^[YyJj]$ ]]; then
        rm -f "$f"
        reload_nginx || true
        echo "Deleted."
    else
        echo "Cancelled."
    fi
    pause
}

# Cuts the stream block appended by this script out of nginx.conf.
# Primarily through the markers; older installations have none, and there the
# stream block containing our include line is removed instead.
remove_stream_block() {
    cp "$MAIN_CONF" "$MAIN_CONF.mgr.bak"

    if grep -qF "$MARK_BEGIN" "$MAIN_CONF"; then
        sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$MAIN_CONF"
    else
        awk -v inc="include ${STREAM_CONF};" '
            !inblk && /^[[:space:]]*stream[[:space:]]*\{/ {
                buf = $0; inblk = 1; found = 0
                depth = gsub(/\{/, "{") - gsub(/\}/, "}")
                if (depth <= 0) { print buf; inblk = 0 }
                next
            }
            inblk {
                buf = buf ORS $0
                if (index($0, inc)) found = 1
                depth += gsub(/\{/, "{") - gsub(/\}/, "}")
                if (depth <= 0) { inblk = 0; if (!found) print buf }
                next
            }
            { print }
            END { if (inblk && !found) print buf }
        ' "$MAIN_CONF" > "$MAIN_CONF.tmp" && mv "$MAIN_CONF.tmp" "$MAIN_CONF"
    fi

    if nginx -t 2>/dev/null; then
        rm -f "$MAIN_CONF.mgr.bak"
        return 0
    fi

    echo "!!! The nginx configuration is broken after the removal:"
    nginx -t || true
    mv "$MAIN_CONF.mgr.bak" "$MAIN_CONF"
    echo "Rolled back, $MAIN_CONF is unchanged."
    return 1
}

uninstall() {
    echo ">>> Uninstall the nginx relay"
    echo

    local n=0
    [[ -d "$HOSTS_DIR" ]] && n=$(find "$HOSTS_DIR" -name '*.map' 2>/dev/null | wc -l) || true

    echo "The following will be removed:"
    echo "  - ${n} host entry/entries in $HOSTS_DIR"
    echo "  - $STREAM_CONF"
    echo "  - the stream block from $MAIN_CONF (followed by nginx -t)"
    echo "  - ufw rule 443/tcp                                      [asked]"
    echo "  - stop and disable nginx                                [asked]"
    echo
    echo "The nginx-extras package stays installed. Manually: apt purge nginx-extras"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup nginx "$MAIN_CONF" "$STREAM_CONF" "$HOSTS_DIR" || { pause; return; }

    remove_stream_block || { pause; return; }

    rm -rf "$HOSTS_DIR"
    rm -f "$STREAM_CONF"

    # The default vhost was disabled during setup because of the port clash on
    # 443 - now it can come back.
    if [[ -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
        if confirm "Enable the http default vhost again?"; then
            ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        fi
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        echo "Careful: port 443 may also be used by Caddy."
        if confirm "Remove the ufw rule 443/tcp?"; then
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi

    if confirm "Stop and disable nginx?"; then
        systemctl stop nginx    >/dev/null 2>&1 || true
        systemctl disable nginx >/dev/null 2>&1 || true
    else
        echo "nginx keeps running (without the stream relay)."
    fi

    echo
    echo "Removed."
    pause
}

main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " nginx management (TCP relay, SNI routing)"
        echo "==========================================="
        if is_setup; then
            echo "Status: set up | nginx: $(systemctl is-active nginx)"
        else
            echo "Status: not set up (happens with the first host)"
        fi
        echo
        list_hosts
        echo
        echo "1) Create a host"
        echo "2) Edit a host"
        echo "3) Delete a host"
        echo "4) Test the config (nginx -t)"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) create_host ;;
            2) edit_host ;;
            3) delete_host ;;
            4) nginx -t || true; pause ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--uninstall|--version]"; exit 1 ;;
esac
