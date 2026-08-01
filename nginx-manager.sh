#!/usr/bin/env bash
# nginx-manager.sh - nginx als reines TCP-Relais mit SNI-basiertem Host-Routing
# TLS wird NICHT terminiert, sondern zum Backend durchgereicht.
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

HOSTS_DIR=/etc/nginx/stream-hosts.d
STREAM_CONF=/etc/nginx/stream.conf
MAIN_CONF=/etc/nginx/nginx.conf

MARK_BEGIN='# >>> nginx-manager >>>'
MARK_END='# <<< nginx-manager <<<'

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
    [[ -f "$STREAM_CONF" ]] && grep -q "include ${STREAM_CONF};" "$MAIN_CONF" 2>/dev/null
}

setup_nginx() {
    echo ">>> Ersteinrichtung nginx stream-Relais"

    if ! command -v nginx &>/dev/null || ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
        echo ">>> Installiere nginx-extras (enthält stream-Modul)..."
        apt update -qq
        DEBIAN_FRONTEND=noninteractive apt install -y nginx-extras >/dev/null
    fi

    mkdir -p "$HOSTS_DIR"

    read -rp "Fallback-Backend für unbekannte/fehlende SNI (leer = Verbindung verwerfen): " FALLBACK

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

    # Marker, damit die Deinstallation den Block wieder exakt herausschneiden kann
    if ! grep -q "include ${STREAM_CONF};" "$MAIN_CONF"; then
        cat >> "$MAIN_CONF" <<EOF

${MARK_BEGIN}
stream {
    include ${STREAM_CONF};
}
${MARK_END}
EOF
    fi

    # Default-vhost auf :443 aus dem http-Block entfernen, sonst Portkonflikt
    if [[ -L /etc/nginx/sites-enabled/default ]]; then
        if grep -q "listen 443" /etc/nginx/sites-enabled/default 2>/dev/null; then
            echo ">>> Deaktiviere http-Default-vhost (Portkonflikt auf 443)..."
            rm -f /etc/nginx/sites-enabled/default
        fi
    fi

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 443/tcp
    fi

    nginx -t
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    echo ">>> Einrichtung abgeschlossen."
}

reload_nginx() {
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        return 0
    else
        echo "!!! nginx-Konfiguration fehlerhaft:"
        nginx -t || true
        return 1
    fi
}

list_hosts() {
    if [[ ! -d "$HOSTS_DIR" ]] || ! ls "$HOSTS_DIR"/*.map &>/dev/null; then
        echo "(keine Hosts angelegt)"
        return
    fi
    printf "%-40s %s\n" "SNI / DOMAIN" "BACKEND"
    printf "%-40s %s\n" "----------------------------------------" "--------------------"
    for f in "$HOSTS_DIR"/*.map; do
        local d b
        d=$(awk '{print $1}' "$f")
        b=$(awk '{print $2}' "$f" | tr -d ';"')
        [[ -z "$b" ]] && b="(verwerfen)"
        printf "%-40s %s\n" "$d" "$b"
    done
}

host_file() {
    echo "$HOSTS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9.-' '_').map"
}

create_host() {
    is_setup || setup_nginx

    echo "--- Vorhandene Hosts ---"; list_hosts; echo
    read -rp "Domain (SNI, z.B. app.example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]] || [[ -f "$(host_file "$DOMAIN")" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Domain: " DOMAIN
    done

    read -rp "Backend (IP:Port, z.B. 10.10.0.2:443): " BACKEND
    while [[ ! "$BACKEND" =~ ^[^:]+:[0-9]+$ ]]; do
        echo "Format: IP:Port"
        read -rp "Backend: " BACKEND
    done

    echo "${DOMAIN}    ${BACKEND};" > "$(host_file "$DOMAIN")"

    if reload_nginx; then
        echo "Host '$DOMAIN' -> $BACKEND angelegt."
        echo "Hinweis: das Zertifikat für '$DOMAIN' muss auf $BACKEND liegen."
    else
        rm -f "$(host_file "$DOMAIN")"
        echo "Zurückgerollt."
    fi
    pause
}

edit_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain zum Bearbeiten: " DOMAIN
    local f; f=$(host_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    local cur; cur=$(awk '{print $2}' "$f" | tr -d ';"')
    read -rp "Backend [$cur]: " NEW; NEW=${NEW:-$cur}

    cp "$f" "$f.bak"
    echo "${DOMAIN}    ${NEW};" > "$f"

    if reload_nginx; then
        rm -f "$f.bak"
        echo "Aktualisiert -> $NEW"
    else
        mv "$f.bak" "$f"
        reload_nginx || true
        echo "Zurückgerollt."
    fi
    pause
}

delete_host() {
    echo "--- Hosts ---"; list_hosts; echo
    read -rp "Domain zum Löschen: " DOMAIN
    local f; f=$(host_file "$DOMAIN")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    read -rp "'$DOMAIN' wirklich löschen? [j/N]: " C
    if [[ "$C" =~ ^[Jj]$ ]]; then
        rm -f "$f"
        reload_nginx || true
        echo "Gelöscht."
    else
        echo "Abgebrochen."
    fi
    pause
}

# Schneidet den von diesem Skript angehängten stream-Block aus nginx.conf.
# Primär über die Marker; ältere Installationen haben keine, dort wird der
# stream-Block entfernt, der unsere include-Zeile enthält.
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

    echo "!!! nginx-Konfiguration nach dem Entfernen fehlerhaft:"
    nginx -t || true
    mv "$MAIN_CONF.mgr.bak" "$MAIN_CONF"
    echo "Zurückgerollt, $MAIN_CONF ist unverändert."
    return 1
}

uninstall() {
    echo ">>> Deinstallation nginx-Relais"
    echo

    local n=0
    [[ -d "$HOSTS_DIR" ]] && n=$(find "$HOSTS_DIR" -name '*.map' 2>/dev/null | wc -l) || true

    echo "Folgendes wird entfernt:"
    echo "  - ${n} Host-Eintrag/-Einträge in $HOSTS_DIR"
    echo "  - $STREAM_CONF"
    echo "  - der stream-Block aus $MAIN_CONF (mit anschließendem nginx -t)"
    echo "  - ufw-Regel 443/tcp                                      [Rückfrage]"
    echo "  - nginx stoppen und deaktivieren                         [Rückfrage]"
    echo
    echo "Das Paket nginx-extras bleibt installiert. Manuell: apt purge nginx-extras"
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup nginx "$MAIN_CONF" "$STREAM_CONF" "$HOSTS_DIR" || { pause; return; }

    remove_stream_block || { pause; return; }

    rm -rf "$HOSTS_DIR"
    rm -f "$STREAM_CONF"

    # Der Default-vHost wurde beim Setup wegen des Portkonflikts auf 443
    # deaktiviert - jetzt kann er zurück.
    if [[ -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
        if confirm "http-Default-vHost wieder aktivieren?"; then
            ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        fi
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        echo "Achtung: Port 443 wird eventuell auch von Caddy benutzt."
        if confirm "ufw-Regel 443/tcp entfernen?"; then
            ufw delete allow 443/tcp >/dev/null 2>&1 || true
        fi
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi

    if confirm "nginx stoppen und deaktivieren?"; then
        systemctl stop nginx    >/dev/null 2>&1 || true
        systemctl disable nginx >/dev/null 2>&1 || true
    else
        echo "nginx läuft weiter (ohne stream-Relais)."
    fi

    echo
    echo "Entfernt."
    pause
}

main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " nginx-Verwaltung (TCP-Relais, SNI-Routing)"
        echo "==========================================="
        if is_setup; then
            echo "Status: eingerichtet | nginx: $(systemctl is-active nginx)"
        else
            echo "Status: nicht eingerichtet (erfolgt beim ersten Host)"
        fi
        echo
        list_hosts
        echo
        echo "1) Host erstellen"
        echo "2) Host bearbeiten"
        echo "3) Host löschen"
        echo "4) Config testen (nginx -t)"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
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
    *)           echo "Verwendung: $0 [--uninstall]"; exit 1 ;;
esac
