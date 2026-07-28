#!/usr/bin/env bash
# modules/caddy.sh - natives Caddy (systemd) installieren + Reverse-Proxy/Sites verwalten.
# Docker-Dienste sind nur auf 127.0.0.1 veroeffentlicht; Caddy terminiert TLS davor.

register caddy install     cad_install      "Caddy installieren"
register caddy render      cad_render       "Haupt-Caddyfile (Stack-Routen) rendern"
register caddy add-proxy   cad_add_proxy    "Reverse-Proxy-Host (mit WebSockets)"
register caddy add-static  cad_add_static   "Ordner als Website freigeben"
register caddy add-redirect cad_add_redirect "Redirect-Host (301/302)"
register caddy list        cad_list         "Zusatz-Hosts auflisten"
register caddy remove      cad_remove       "Zusatz-Host entfernen"
register caddy reload      cad_reload       "Caddy neu laden"

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
SITES_D="${SITES_D:-/etc/caddy/sites.d}"
SITEROOT="${SITEROOT:-/srv/sites}"
WEBROOT_DEFAULT="${WEBROOT_DEFAULT:-/srv/website}"

cad_slug() { echo "$1" | tr -c 'a-zA-Z0-9._-' '_' | sed 's/_*$//'; }

cad_install() {
  command -v caddy >/dev/null 2>&1 && { log "Caddy ist bereits installiert."; return 0; }
  command -v apt-get >/dev/null 2>&1 || die "Kein apt - Caddy manuell installieren: https://caddyserver.com/docs/install"
  log "Installiere Caddy (offizielles Repo) ..."
  ensure_tool curl curl; ensure_tool gpg gnupg
  $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | $SUDO gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  $SUDO chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  $SUDO apt-get update && $SUDO apt-get install -y caddy
}

cad_reload() {
  if $SUDO systemctl reload caddy 2>/dev/null; then log "Caddy neu geladen (systemd)."
  elif $SUDO caddy reload --config "$CADDYFILE" 2>/dev/null; then log "Caddy neu geladen."
  else warn "Reload fehlgeschlagen. Pruefe: $SUDO systemctl status caddy / $SUDO caddy validate --config $CADDYFILE"; fi
}

# Lese-/Durchlauf-Recht fuer den 'caddy'-User auf einem Verzeichnisbaum (behebt 403).
cad_webroot_access() {
  local root="$1"
  command -v setfacl >/dev/null 2>&1 || ensure_tool setfacl acl
  $SUDO setfacl -R -m u:caddy:rX "$root" 2>/dev/null \
    || { warn "(ACL nicht moeglich - falls 403: '$root' fuer 'caddy' lesbar machen)"; return 0; }
  $SUDO setfacl -R -d -m u:caddy:rX "$root" 2>/dev/null || true
  local d; d="$(dirname "$root")"
  while [[ "$d" != "/" && -n "$d" ]]; do $SUDO setfacl -m u:caddy:x "$d" 2>/dev/null || true; d="$(dirname "$d")"; done
}

cad_render() {
  cad_install
  require_keys BASE_DOMAIN ACME_EMAIL || return 1
  ensure_tool envsubst gettext-base; umask 022
  WEBROOT="${WEBROOT:-$WEBROOT_DEFAULT}"
  export BASE_DOMAIN CLOUD_DOMAIN VAULT_DOMAIN AUTH_DOMAIN OFFICE_DOMAIN ACME_EMAIL WEBROOT
  local VARS='$BASE_DOMAIN $CLOUD_DOMAIN $VAULT_DOMAIN $AUTH_DOMAIN $OFFICE_DOMAIN $ACME_EMAIL $WEBROOT'
  $SUDO mkdir -p "$SITES_D" "$WEBROOT" "$SITEROOT"
  [[ -z "$($SUDO ls -A "$WEBROOT" 2>/dev/null)" ]] && $SUDO cp -a "$TEMPLATE_DIR/website/." "$WEBROOT/"
  cad_webroot_access "$WEBROOT"
  envsubst "$VARS" < "$TEMPLATE_DIR/Caddyfile.native.tmpl" | $SUDO tee "$CADDYFILE" >/dev/null
  log "$CADDYFILE geschrieben."
  warn "DNS: $BASE_DOMAIN, www, $CLOUD_DOMAIN, $VAULT_DOMAIN, $AUTH_DOMAIN, $OFFICE_DOMAIN -> Server-IP."
  $SUDO systemctl enable caddy >/dev/null 2>&1 || true
  cad_reload
}

cad_add_proxy() {
  cad_install; ensure_tool envsubst gettext-base; umask 022
  local domain="${1:-}" target="${2:-}" slug tmp tpl
  [[ -n "$domain" ]] || read -rp "Domain (z.B. app.example.com): " domain
  [[ -n "$domain" ]] || { err "Keine Domain - Abbruch."; return 1; }
  [[ -n "$target" ]] || read -rp "Proxy-Ziel (host:port, z.B. 127.0.0.1:3000): " target
  [[ -n "$target" ]] || { err "Kein Ziel - Abbruch."; return 1; }
  tpl="$TEMPLATE_DIR/site-proxy.caddy.tmpl"
  echo "   WebSockets funktionieren mit Caddy automatisch."
  confirm "Streaming/SSE aktivieren (flush_interval -1; fuer Live-Streams/Events)?" \
    && tpl="$TEMPLATE_DIR/site-proxy-ws.caddy.tmpl"
  slug="$(cad_slug "$domain")"; $SUDO mkdir -p "$SITES_D"; tmp="$(mktemp)"
  SITE_DOMAIN="$domain" SITE_TARGET="$target" \
    envsubst '$SITE_DOMAIN $SITE_TARGET' < "$tpl" > "$tmp"
  $SUDO install -m 644 "$tmp" "$SITES_D/$slug.caddy"; rm -f "$tmp"
  log "Proxy: $domain -> $target  ($SITES_D/$slug.caddy)"
  warn "DNS fuer '$domain' auf die Server-IP zeigen lassen (TLS holt Caddy automatisch)."
  cad_reload
}

cad_add_static() {
  cad_install; ensure_tool envsubst gettext-base; umask 022
  local domain="${1:-}" root="${2:-}" slug tmp
  [[ -n "$domain" ]] || read -rp "Domain (z.B. blog.example.com): " domain
  [[ -n "$domain" ]] || { err "Keine Domain - Abbruch."; return 1; }
  slug="$(cad_slug "$domain")"
  [[ -n "$root" ]] || read -rp "Ordner [$SITEROOT/$slug]: " root
  root="${root:-$SITEROOT/$slug}"
  $SUDO mkdir -p "$root" "$SITES_D"
  if ! $SUDO test -e "$root/index.html"; then
    printf '<!doctype html><meta charset=utf-8><h1>%s</h1>\n' "$domain" | $SUDO tee "$root/index.html" >/dev/null
  fi
  cad_webroot_access "$root"
  tmp="$(mktemp)"
  SITE_DOMAIN="$domain" SITE_ROOT="$root" \
    envsubst '$SITE_DOMAIN $SITE_ROOT' < "$TEMPLATE_DIR/site-static.caddy.tmpl" > "$tmp"
  $SUDO install -m 644 "$tmp" "$SITES_D/$slug.caddy"; rm -f "$tmp"
  log "Statisch: $domain -> $root  ($SITES_D/$slug.caddy)"
  warn "DNS fuer '$domain' auf die Server-IP zeigen lassen."
  cad_reload
}

cad_add_redirect() {
  cad_install; ensure_tool envsubst gettext-base; umask 022
  local domain="${1:-}" target="${2:-}" code="${3:-}" slug tmp
  [[ -n "$domain" ]] || read -rp "Domain (z.B. alt.example.com): " domain
  [[ -n "$domain" ]] || { err "Keine Domain - Abbruch."; return 1; }
  [[ -n "$target" ]] || read -rp "Ziel-URL (z.B. https://neu.example.com): " target
  [[ -n "$target" ]] || { err "Kein Ziel - Abbruch."; return 1; }
  [[ -n "$code" ]] || { read -rp "Code [301]: " code; code="${code:-301}"; }
  slug="$(cad_slug "$domain")"; $SUDO mkdir -p "$SITES_D"; tmp="$(mktemp)"
  SITE_DOMAIN="$domain" SITE_TARGET="$target" SITE_REDIR_CODE="$code" \
    envsubst '$SITE_DOMAIN $SITE_TARGET $SITE_REDIR_CODE' < "$TEMPLATE_DIR/site-redirect.caddy.tmpl" > "$tmp"
  $SUDO install -m 644 "$tmp" "$SITES_D/$slug.caddy"; rm -f "$tmp"
  log "Redirect: $domain -> $target ($code)  ($SITES_D/$slug.caddy)"
  cad_reload
}

cad_list() {
  $SUDO ls -1 "$SITES_D"/*.caddy >/dev/null 2>&1 || { echo "(keine Zusatz-Hosts)"; return 0; }
  echo "Zusatz-Hosts:"
  local f
  for f in $($SUDO ls -1 "$SITES_D"/*.caddy); do
    $SUDO awk 'NR==1{sub(/ *\{.*/,""); print "  - "$0}' "$f"
  done
}

cad_remove() {
  local domain="${1:-}" slug
  [[ -n "$domain" ]] || { cad_list; read -rp "Zu entfernende Domain: " domain; }
  [[ -n "$domain" ]] || { err "Keine Domain - Abbruch."; return 1; }
  slug="$(cad_slug "$domain")"
  $SUDO test -f "$SITES_D/$slug.caddy" || { err "Nicht gefunden: $SITES_D/$slug.caddy"; return 1; }
  $SUDO rm -f "$SITES_D/$slug.caddy"; log "Entfernt: $SITES_D/$slug.caddy"
  $SUDO test -d "$SITEROOT/$slug" && warn "Statische Inhalte bleiben unter $SITEROOT/$slug/ (bei Bedarf loeschen)."
  cad_reload
}
