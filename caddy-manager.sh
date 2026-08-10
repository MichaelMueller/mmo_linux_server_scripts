#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# caddy-manager.sh - Caddy vhost management (TLS termination on this server)
# Host types: static files, redirect, reverse proxy
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.1.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

CADDY_DIR=/etc/caddy
SITES_DIR="$CADDY_DIR/sites.d"
CADDYFILE="$CADDY_DIR/Caddyfile"
META_DIR="$CADDY_DIR/sites-meta.d"

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
    command -v caddy &>/dev/null && [[ -d "$SITES_DIR" ]] && grep -q "import ${SITES_DIR}/\*.caddy" "$CADDYFILE" 2>/dev/null
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

    mkdir -p "$SITES_DIR" "$META_DIR"

    read -rp "Mail address for Let's Encrypt (optional, recommended): " ACME_MAIL

    if [[ -f "$CADDYFILE" ]] && ! grep -q "import ${SITES_DIR}" "$CADDYFILE"; then
        cp "$CADDYFILE" "$CADDYFILE.orig.$(date +%s)"
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

    systemctl enable caddy >/dev/null 2>&1 || true
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || true
    systemctl restart caddy
    echo ">>> Setup complete."
}

reload_caddy() {
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
ensure_dirs() { mkdir -p "$SITES_DIR" "$META_DIR"; }

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
    printf "%-35s %-14s %s\n" "DOMAIN" "TYPE" "TARGET"
    printf "%-35s %-14s %s\n" "-----------------------------------" "--------------" "--------------------"
    for f in "$SITES_DIR"/*.caddy; do
        local d t g m
        # first non-comment line that opens a site block; a site can carry
        # several addresses, so keep them all
        d=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
                 /\{[[:space:]]*$/ {sub(/[[:space:]]*\{[[:space:]]*$/, "");
                                    gsub(/[[:space:]]*,[[:space:]]*|[[:space:]]+/, ","); print; exit}' "$f")
        [[ -n "$d" ]] || d="(unparsed: $(basename "$f"))"
        m=$(meta_file "${d%%,*}")
        if [[ -f "$m" ]]; then
            t=$(grep '^TYPE=' "$m" | cut -d= -f2-)
            g=$(grep '^TARGET=' "$m" | cut -d= -f2-)
        else
            t="?"; g="?"
        fi
        printf "%-35s %-14s %s\n" "$d" "$t" "$g"
    done
}

# --- Type 1: static files -----------------------------------------------------
build_static() {
    local domain=$1
    read -rp "Directory (root) [/var/www/${domain}]: " ROOT
    ROOT=${ROOT:-/var/www/${domain}}

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

    {
        echo "${domain} {"
        echo "    root * ${ROOT}"
        [[ -n "$authblock" ]] && echo "$authblock"
        echo "    encode zstd gzip"
        echo "    file_server$([[ "$BROWSE" =~ ^[YyJj]$ ]] && echo " browse")"
        echo "    log {"
        echo "        output file /var/log/caddy/${domain}.log"
        echo "    }"
        echo "}"
    } > "$(site_file "$domain")"

    printf 'TYPE=static\nTARGET=%s\n' "$ROOT" > "$(meta_file "$domain")"
}

# --- Type 2: redirect ---------------------------------------------------------
build_redirect() {
    local domain=$1
    read -rp "Target URL (e.g. https://example.com): " TARGET
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

    {
        echo "${domain} {"
        echo "    redir ${TARGET}${SUFFIX} ${CODE}"
        echo "}"
    } > "$(site_file "$domain")"

    printf 'TYPE=redirect\nTARGET=%s\n' "$TARGET" > "$(meta_file "$domain")"
}

# --- Type 3: reverse proxy ----------------------------------------------------
build_proxy() {
    local domain=$1
    read -rp "Backend (e.g. 10.10.0.2:32000, several space-separated): " BACKENDS
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

    {
        echo "${domain} {"
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
        echo "        output file /var/log/caddy/${domain}.log"
        echo "    }"
        echo "}"
    } > "$(site_file "$domain")"

    printf 'TYPE=proxy\nTARGET=%s\n' "$BACKENDS" > "$(meta_file "$domain")"
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

    echo
    echo "What should this host do?"
    echo "  1) Serve static files"
    echo "  2) Redirect to another URL"
    echo "  3) Reverse proxy to a backend"
    read -rp "Choice [3]: " TYPE; TYPE=${TYPE:-3}
    echo

    mkdir -p /var/log/caddy
    chown caddy:caddy /var/log/caddy 2>/dev/null || true

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
    echo "  - /var/lib/caddy - CONTAINS THE TLS CERTIFICATES        [asked]"
    echo "  - /var/log/caddy                                        [asked]"
    echo "  - ufw rules 80/tcp and 443/tcp                          [asked]"
    echo
    echo "The caddy package and the apt repo stay. To remove them manually:"
    echo "    apt purge caddy && rm -f /etc/apt/sources.list.d/caddy-stable.list \\"
    echo "        /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup caddy "$CADDYFILE" "$SITES_DIR" "$META_DIR" || { pause; return; }

    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true

    rm -rf "$SITES_DIR" "$META_DIR"

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
        echo "5) Check the config (caddy validate)"
        echo "6) Logs (journalctl -u caddy)"
        echo "7) Uninstall"
        echo "8) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) create_host ;;
            2) show_host ;;
            3) edit_host ;;
            4) delete_host ;;
            5) caddy validate --config "$CADDYFILE" --adapter caddyfile || true; pause ;;
            6) journalctl -u caddy -n 50 --no-pager || true; pause ;;
            7) uninstall ;;
            8) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--uninstall|--version]"; exit 1 ;;
esac
