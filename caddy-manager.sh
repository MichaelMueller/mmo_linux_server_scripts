#!/usr/bin/env bash
# caddy-manager.sh - Caddy Vhost-Verwaltung (TLS-Terminierung am Server)
# Host-Typen: statische Dateien, Weiterleitung, Reverse Proxy
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

CADDY_DIR=/etc/caddy
SITES_DIR="$CADDY_DIR/sites.d"
CADDYFILE="$CADDY_DIR/Caddyfile"
META_DIR="$CADDY_DIR/sites-meta.d"

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

is_setup() {
    command -v caddy &>/dev/null && [[ -d "$SITES_DIR" ]] && grep -q "import ${SITES_DIR}/\*.caddy" "$CADDYFILE" 2>/dev/null
}

setup_caddy() {
    echo ">>> Ersteinrichtung Caddy"

    if ! command -v caddy &>/dev/null; then
        echo ">>> Installiere Caddy aus offiziellem Repo..."
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

    read -rp "E-Mail für Let's Encrypt (optional, empfohlen): " ACME_MAIL

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
    echo ">>> Einrichtung abgeschlossen."
}

reload_caddy() {
    if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        return 0
    else
        echo "!!! Caddyfile fehlerhaft:"
        caddy validate --config "$CADDYFILE" --adapter caddyfile || true
        return 1
    fi
}

site_file() { echo "$SITES_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9.-' '_').caddy"; }
meta_file() { echo "$META_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9.-' '_').meta"; }

list_hosts() {
    if [[ ! -d "$SITES_DIR" ]] || ! ls "$SITES_DIR"/*.caddy &>/dev/null; then
        echo "(keine Hosts angelegt)"
        return
    fi
    printf "%-35s %-14s %s\n" "DOMAIN" "TYP" "ZIEL"
    printf "%-35s %-14s %s\n" "-----------------------------------" "--------------" "--------------------"
    for f in "$SITES_DIR"/*.caddy; do
        local d t g m
        d=$(head -1 "$f" | awk '{print $1}')
        m=$(meta_file "$d")
        if [[ -f "$m" ]]; then
            t=$(grep '^TYPE=' "$m" | cut -d= -f2-)
            g=$(grep '^TARGET=' "$m" | cut -d= -f2-)
        else
            t="?"; g="?"
        fi
        printf "%-35s %-14s %s\n" "$d" "$t" "$g"
    done
}

# --- Typ 1: statische Dateien -------------------------------------------------
build_static() {
    local domain=$1
    read -rp "Verzeichnis (root) [/var/www/${domain}]: " ROOT
    ROOT=${ROOT:-/var/www/${domain}}

    if [[ ! -d "$ROOT" ]]; then
        read -rp "Verzeichnis existiert nicht. Anlegen? [J/n]: " C
        C=${C:-J}
        if [[ "$C" =~ ^[Jj]$ ]]; then
            mkdir -p "$ROOT"
            echo "<h1>${domain}</h1>" > "$ROOT/index.html"
            chown -R caddy:caddy "$ROOT" 2>/dev/null || true
        fi
    fi

    read -rp "Verzeichnis-Listing aktivieren (browse)? [j/N]: " BROWSE
    read -rp "Basic-Auth einrichten? [j/N]: " BAUTH

    local authblock=""
    if [[ "$BAUTH" =~ ^[Jj]$ ]]; then
        read -rp "  Benutzername: " BUSER
        read -rsp "  Passwort: " BPASS; echo
        local HASH
        HASH=$(caddy hash-password --plaintext "$BPASS")
        authblock=$(printf '    basic_auth {\n        %s %s\n    }\n' "$BUSER" "$HASH")
    fi

    {
        echo "${domain} {"
        echo "    root * ${ROOT}"
        [[ -n "$authblock" ]] && echo "$authblock"
        echo "    encode zstd gzip"
        echo "    file_server$([[ "$BROWSE" =~ ^[Jj]$ ]] && echo " browse")"
        echo "    log {"
        echo "        output file /var/log/caddy/${domain}.log"
        echo "    }"
        echo "}"
    } > "$(site_file "$domain")"

    printf 'TYPE=static\nTARGET=%s\n' "$ROOT" > "$(meta_file "$domain")"
}

# --- Typ 2: Weiterleitung -----------------------------------------------------
build_redirect() {
    local domain=$1
    read -rp "Ziel-URL (z.B. https://example.com): " TARGET
    while [[ -z "$TARGET" ]]; do read -rp "  -> Pflichtfeld: " TARGET; done

    echo "  1) 301 permanent"
    echo "  2) 302 temporär"
    read -rp "Art [1]: " RC; RC=${RC:-1}
    local CODE="permanent"
    [[ "$RC" == "2" ]] && CODE="temporary"

    read -rp "Pfad + Query mit übernehmen (z.B. /foo?bar)? [J/n]: " KEEP
    KEEP=${KEEP:-J}
    local SUFFIX=""
    [[ "$KEEP" =~ ^[Jj]$ ]] && SUFFIX='{uri}'

    {
        echo "${domain} {"
        echo "    redir ${TARGET}${SUFFIX} ${CODE}"
        echo "}"
    } > "$(site_file "$domain")"

    printf 'TYPE=redirect\nTARGET=%s\n' "$TARGET" > "$(meta_file "$domain")"
}

# --- Typ 3: Reverse Proxy -----------------------------------------------------
build_proxy() {
    local domain=$1
    read -rp "Backend (z.B. 10.10.0.2:32000, mehrere space-getrennt): " BACKENDS
    while [[ -z "$BACKENDS" ]]; do read -rp "  -> Pflichtfeld: " BACKENDS; done

    read -rp "Backend spricht HTTPS? [j/N]: " ISTLS
    read -rp "Pfad-Präfix begrenzen (leer = alles, z.B. /api): " PATHMATCH

    local opts=()

    if [[ "$ISTLS" =~ ^[Jj]$ ]]; then
        opts+=("        transport http {")
        opts+=("            tls")
        read -rp "  Zertifikat des Backends nicht prüfen (self-signed)? [j/N]: " NOVERIFY
        [[ "$NOVERIFY" =~ ^[Jj]$ ]] && opts+=("            tls_insecure_skip_verify")
        opts+=("        }")
    fi

    read -rp "WebSocket-/Streaming-Modus (Buffering aus, lange Timeouts)? [j/N]: " WS
    if [[ "$WS" =~ ^[Jj]$ ]]; then
        opts+=("        flush_interval -1")
    fi

    read -rp "Original-Host-Header an Backend weitergeben? [J/n]: " KEEPHOST
    KEEPHOST=${KEEPHOST:-J}
    if [[ "$KEEPHOST" =~ ^[Jj]$ ]]; then
        opts+=("        header_up Host {upstream_hostport}")
    fi
    opts+=("        header_up X-Real-IP {remote_host}")

    read -rp "Health-Check aktivieren? [j/N]: " HC
    if [[ "$HC" =~ ^[Jj]$ ]]; then
        read -rp "  Health-Pfad [/]: " HCPATH; HCPATH=${HCPATH:-/}
        opts+=("        health_uri ${HCPATH}")
        opts+=("        health_interval 30s")
    fi

    local backend_count
    backend_count=$(echo "$BACKENDS" | wc -w)
    if (( backend_count > 1 )); then
        echo "  Load-Balancing-Policy: 1) round_robin  2) least_conn  3) ip_hash"
        read -rp "  Auswahl [1]: " LB; LB=${LB:-1}
        case "$LB" in
            2) opts+=("        lb_policy least_conn") ;;
            3) opts+=("        lb_policy ip_hash") ;;
            *) opts+=("        lb_policy round_robin") ;;
        esac
    fi

    read -rp "Basic-Auth davorschalten? [j/N]: " BAUTH
    local authblock=""
    if [[ "$BAUTH" =~ ^[Jj]$ ]]; then
        read -rp "  Benutzername: " BUSER
        read -rsp "  Passwort: " BPASS; echo
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

    echo "--- Vorhandene Hosts ---"; list_hosts; echo
    read -rp "Domain (z.B. app.example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]] || [[ -f "$(site_file "$DOMAIN")" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Domain: " DOMAIN
    done

    echo
    echo "Was soll dieser Host tun?"
    echo "  1) Statische Dateien ausliefern"
    echo "  2) Weiterleitung auf andere URL"
    echo "  3) Reverse Proxy auf Backend"
    read -rp "Auswahl [3]: " TYPE; TYPE=${TYPE:-3}
    echo

    mkdir -p /var/log/caddy
    chown caddy:caddy /var/log/caddy 2>/dev/null || true

    case "$TYPE" in
        1) build_static   "$DOMAIN" ;;
        2) build_redirect "$DOMAIN" ;;
        3) build_proxy    "$DOMAIN" ;;
        *) echo "Ungültig."; pause; return ;;
    esac

    echo
    echo "--- Erzeugte Config ---"
    cat "$(site_file "$DOMAIN")"
    echo "-----------------------"

    if reload_caddy; then
        echo "Host '$DOMAIN' aktiv. Zertifikat wird automatisch geholt (DNS muss auf diesen Server zeigen)."
    else
        rm -f "$(site_file "$DOMAIN")" "$(meta_file "$DOMAIN")"
        reload_caddy || true
        echo "Zurückgerollt."
    fi
    pause
}

show_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain: " DOMAIN
    local f; f=$(site_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }
    echo; cat "$f"; echo
    pause
}

edit_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain zum Bearbeiten: " DOMAIN
    local f m; f=$(site_file "$DOMAIN"); m=$(meta_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    echo
    echo "1) Neu konfigurieren (Assistent, Typ wählbar)"
    echo "2) Config-Datei direkt im Editor öffnen"
    echo "3) Abbrechen"
    read -rp "Auswahl: " CH

    cp "$f" "$f.bak"
    [[ -f "$m" ]] && cp "$m" "$m.bak"

    case "$CH" in
        1)
            echo
            echo "  1) Statische Dateien"
            echo "  2) Weiterleitung"
            echo "  3) Reverse Proxy"
            read -rp "Typ: " T
            case "$T" in
                1) build_static   "$DOMAIN" ;;
                2) build_redirect "$DOMAIN" ;;
                3) build_proxy    "$DOMAIN" ;;
                *) echo "Ungültig."; rm -f "$f.bak" "$m.bak"; pause; return ;;
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
        echo "Aktualisiert."
        cat "$f"
    else
        mv "$f.bak" "$f"
        [[ -f "$m.bak" ]] && mv "$m.bak" "$m"
        reload_caddy || true
        echo "Zurückgerollt."
    fi
    pause
}

delete_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain zum Löschen: " DOMAIN
    local f; f=$(site_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    read -rp "'$DOMAIN' wirklich löschen? [j/N]: " C
    if [[ "$C" =~ ^[Jj]$ ]]; then
        rm -f "$f" "$(meta_file "$DOMAIN")"
        reload_caddy || true
        echo "Gelöscht. (Zertifikat bleibt im Caddy-Datenverzeichnis liegen.)"
    else
        echo "Abgebrochen."
    fi
    pause
}

uninstall() {
    echo ">>> Deinstallation Caddy-Verwaltung"
    echo

    local n=0 orig=""
    [[ -d "$SITES_DIR" ]] && n=$(find "$SITES_DIR" -name '*.caddy' 2>/dev/null | wc -l) || true
    orig=$(ls -1t "$CADDYFILE".orig.* 2>/dev/null | head -1 || true)

    echo "Folgendes wird entfernt:"
    echo "  - ${n} vHost(s) in $SITES_DIR"
    echo "  - Metadaten in $META_DIR"
    if [[ -n "$orig" ]]; then
        echo "  - $CADDYFILE wird aus $orig wiederhergestellt"
    else
        echo "  - $CADDYFILE wird gelöscht (kein .orig-Backup vorhanden)"
    fi
    echo "  - Dienst caddy wird gestoppt und deaktiviert"
    echo "  - /var/lib/caddy - ENTHÄLT DIE TLS-ZERTIFIKATE          [Rückfrage]"
    echo "  - /var/log/caddy                                        [Rückfrage]"
    echo "  - ufw-Regeln 80/tcp und 443/tcp                         [Rückfrage]"
    echo
    echo "Das Paket caddy und das apt-Repo bleiben bestehen. Manuell entfernen:"
    echo "    apt purge caddy && rm -f /etc/apt/sources.list.d/caddy-stable.list \\"
    echo "        /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup caddy "$CADDYFILE" "$SITES_DIR" "$META_DIR" || { pause; return; }

    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true

    rm -rf "$SITES_DIR" "$META_DIR"

    if [[ -n "$orig" ]]; then
        mv "$orig" "$CADDYFILE"
        echo "$CADDYFILE aus $orig wiederhergestellt."
    else
        rm -f "$CADDYFILE"
    fi

    if [[ -d /var/lib/caddy ]]; then
        echo
        echo "Hinweis: /var/lib/caddy enthält die von Let's Encrypt ausgestellten"
        echo "Zertifikate. Nach dem Löschen werden sie neu beantragt - bei vielen"
        echo "Domains kann das an das Rate-Limit von Let's Encrypt stoßen."
        if confirm "/var/lib/caddy (Zertifikate) löschen?"; then
            if make_backup caddy-zertifikate /var/lib/caddy; then
                rm -rf /var/lib/caddy
            else
                echo "Zertifikate bleiben liegen."
            fi
        fi
    fi

    if [[ -d /var/log/caddy ]] && confirm "/var/log/caddy (Zugriffs-Logs) löschen?"; then
        rm -rf /var/log/caddy
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        echo "Achtung: Port 443 wird eventuell auch vom nginx-Relais benutzt."
        if confirm "ufw-Regeln 80/tcp und 443/tcp entfernen?"; then
            ufw delete allow 80/tcp  >/dev/null 2>&1 || true
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi
    fi

    echo
    echo "Entfernt."
    pause
}

main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Caddy-Verwaltung (TLS-Terminierung)"
        echo "==========================================="
        if is_setup; then
            echo "Status: eingerichtet | caddy: $(systemctl is-active caddy)"
        else
            echo "Status: nicht eingerichtet (erfolgt beim ersten Host)"
        fi
        echo
        list_hosts
        echo
        echo "1) Host erstellen"
        echo "2) Host anzeigen"
        echo "3) Host bearbeiten"
        echo "4) Host löschen"
        echo "5) Config prüfen (caddy validate)"
        echo "6) Logs (journalctl -u caddy)"
        echo "7) Deinstallieren"
        echo "8) Beenden"
        read -rp "Auswahl: " CH
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
    *)           echo "Verwendung: $0 [--uninstall]"; exit 1 ;;
esac
