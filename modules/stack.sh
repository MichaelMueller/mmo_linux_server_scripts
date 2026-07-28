#!/usr/bin/env bash
# modules/stack.sh - Kern-Stack: rendern + Betrieb (ein gemeinsames Compose-Projekt).

register stack config  st_config  "Konfiguration / Stack rendern"
register stack up      st_up      "Stack starten"
register stack down    st_down    "Stack stoppen"
register stack status  st_status  "Status & Zugaenge"
register stack all     st_all     "Komplett-Setup (config + start + caddy + wire + office)"

# Website per Cron aktuell halten (git pull), gesteuert ueber WEBSITE_PULL/-_MIN.
apply_website_pull() {
  if yesish "${WEBSITE_PULL:-n}"; then
    ensure_tool git git
    local repo; repo="$(git -C "$WEBROOT" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$repo" ]] || { warn "Website-Auto-Update uebersprungen: '$WEBROOT' ist kein git-Repo."; return 0; }
    install_cron "*/${WEBSITE_PULL_MIN:-5} * * * *" \
      "git -C '$repo' pull --ff-only >> $DEPLOY_DIR/website-pull.log 2>&1" "home_stack-website-pull"
    log "Website-Auto-Update: alle ${WEBSITE_PULL_MIN:-5} min 'git pull' in $repo"
  else
    remove_cron "home_stack-website-pull"
  fi
}

st_config() {
  ensure_tool openssl openssl; ensure_tool envsubst gettext-base; ensure_tool curl curl
  log "Deploy-Ordner: $DEPLOY_DIR"; ensure_dir "$DEPLOY_DIR"
  conf_load

  echo; echo "=== Basis-Parameter ==="
  local OLD_BASE="${BASE_DOMAIN:-}" v cur
  ask BASE_DOMAIN          "Basis-Domain (deine Website)"          "${BASE_DOMAIN:-example.com}"
  if [[ -n "$OLD_BASE" && "$BASE_DOMAIN" != "$OLD_BASE" ]]; then
    for v in CLOUD_DOMAIN VAULT_DOMAIN AUTH_DOMAIN OFFICE_DOMAIN; do
      cur="${!v:-}"
      [[ "$cur" == *".$OLD_BASE" ]] && printf -v "$v" '%s' "${cur%.$OLD_BASE}.$BASE_DOMAIN"
    done
    warn "(Basis geaendert -> Subdomains umgestellt; unten pruefen, Enter behaelt.)"
  fi
  ask CLOUD_DOMAIN         "Nextcloud-Subdomain"                   "${CLOUD_DOMAIN:-nc.$BASE_DOMAIN}"
  ask VAULT_DOMAIN         "Vaultwarden-Subdomain"                 "${VAULT_DOMAIN:-va.$BASE_DOMAIN}"
  ask AUTH_DOMAIN          "Rauthy/SSO-Subdomain"                  "${AUTH_DOMAIN:-au.$BASE_DOMAIN}"
  ask OFFICE_DOMAIN        "Collabora/Office-Subdomain"            "${OFFICE_DOMAIN:-of.$BASE_DOMAIN}"
  ask ACME_EMAIL           "E-Mail (Let's Encrypt + Rauthy-Admin)" "${ACME_EMAIL:-admin@$BASE_DOMAIN}"
  ask TZ                   "Zeitzone"                              "${TZ:-Europe/Berlin}"
  ask NEXTCLOUD_ADMIN_USER "Nextcloud lokaler Admin-User"          "${NEXTCLOUD_ADMIN_USER:-ncadmin}"
  ask WEBROOT              "Public-HTML-Ordner der Website"        "${WEBROOT:-/srv/website}"
  ask WEBSITE_PULL         "Website automatisch per 'git pull'? (j/n)" "${WEBSITE_PULL:-n}"
  yesish "$WEBSITE_PULL" && ask WEBSITE_PULL_MIN "  Intervall in Minuten" "${WEBSITE_PULL_MIN:-5}"

  RAUTHY_TAG="${RAUTHY_TAG:-0.35.2}"; NEXTCLOUD_TAG="${NEXTCLOUD_TAG:-30-apache}"
  MARIADB_TAG="${MARIADB_TAG:-lts}"; REDIS_TAG="${REDIS_TAG:-7-alpine}"
  VAULTWARDEN_TAG="${VAULTWARDEN_TAG:-latest}"; COLLABORA_TAG="${COLLABORA_TAG:-latest}"
  VW_SIGNUPS="${VW_SIGNUPS:-false}"

  : "${MYSQL_ROOT_PASSWORD:=$(gen)}"; : "${MYSQL_PASSWORD:=$(gen)}"
  : "${REDIS_PASSWORD:=$(gen)}"; : "${NEXTCLOUD_ADMIN_PASSWORD:=$(genb)}"
  : "${VW_ADMIN_TOKEN:=$(gen)}"
  : "${VW_SSO_CLIENT_SECRET:=$(gen)}"
  : "${NC_OIDC_CLIENT_SECRET:=$(gen)}"
  : "${RAUTHY_ADMIN_PASSWORD:=$(genb)}"
  : "${RAUTHY_ENC_KEY_ACTIVE:=$(openssl rand -hex 4)}"
  : "${RAUTHY_ENC_KEYS:=$RAUTHY_ENC_KEY_ACTIVE/$(openssl rand -base64 32)}"
  : "${HQL_SECRET_RAFT:=$(genb)}"
  : "${HQL_SECRET_API:=$(genb)}"

  umask 077
  cat > "$CONF_FILE" <<EOF
# Von setup.sh erzeugt - Secrets, NICHT committen.
BASE_DOMAIN='$BASE_DOMAIN'
CLOUD_DOMAIN='$CLOUD_DOMAIN'
VAULT_DOMAIN='$VAULT_DOMAIN'
AUTH_DOMAIN='$AUTH_DOMAIN'
OFFICE_DOMAIN='$OFFICE_DOMAIN'
ACME_EMAIL='$ACME_EMAIL'
TZ='$TZ'
WEBROOT='$WEBROOT'
WEBSITE_PULL='$WEBSITE_PULL'
WEBSITE_PULL_MIN='${WEBSITE_PULL_MIN:-5}'
NEXTCLOUD_ADMIN_USER='$NEXTCLOUD_ADMIN_USER'
RAUTHY_TAG='$RAUTHY_TAG'
NEXTCLOUD_TAG='$NEXTCLOUD_TAG'
MARIADB_TAG='$MARIADB_TAG'
REDIS_TAG='$REDIS_TAG'
VAULTWARDEN_TAG='$VAULTWARDEN_TAG'
COLLABORA_TAG='$COLLABORA_TAG'
VW_SIGNUPS='$VW_SIGNUPS'
RAUTHY_ENC_KEYS='$RAUTHY_ENC_KEYS'
RAUTHY_ENC_KEY_ACTIVE='$RAUTHY_ENC_KEY_ACTIVE'
RAUTHY_ADMIN_PASSWORD='$RAUTHY_ADMIN_PASSWORD'
HQL_SECRET_RAFT='$HQL_SECRET_RAFT'
HQL_SECRET_API='$HQL_SECRET_API'
MYSQL_ROOT_PASSWORD='$MYSQL_ROOT_PASSWORD'
MYSQL_PASSWORD='$MYSQL_PASSWORD'
REDIS_PASSWORD='$REDIS_PASSWORD'
NEXTCLOUD_ADMIN_PASSWORD='$NEXTCLOUD_ADMIN_PASSWORD'
VW_ADMIN_TOKEN='$VW_ADMIN_TOKEN'
VW_SSO_CLIENT_SECRET='$VW_SSO_CLIENT_SECRET'
NC_OIDC_CLIENT_SECRET='$NC_OIDC_CLIENT_SECRET'
EOF
  chmod 600 "$CONF_FILE"

  export BASE_DOMAIN CLOUD_DOMAIN VAULT_DOMAIN AUTH_DOMAIN OFFICE_DOMAIN ACME_EMAIL TZ \
         NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD RAUTHY_TAG NEXTCLOUD_TAG \
         MARIADB_TAG REDIS_TAG VAULTWARDEN_TAG COLLABORA_TAG VW_SIGNUPS \
         RAUTHY_ENC_KEYS RAUTHY_ENC_KEY_ACTIVE RAUTHY_ADMIN_PASSWORD HQL_SECRET_RAFT HQL_SECRET_API \
         MYSQL_ROOT_PASSWORD MYSQL_PASSWORD REDIS_PASSWORD \
         VW_ADMIN_TOKEN VW_SSO_CLIENT_SECRET NC_OIDC_CLIENT_SECRET

  local VARS='$BASE_DOMAIN $CLOUD_DOMAIN $VAULT_DOMAIN $AUTH_DOMAIN $OFFICE_DOMAIN $ACME_EMAIL $TZ $NEXTCLOUD_ADMIN_USER $NEXTCLOUD_ADMIN_PASSWORD $RAUTHY_TAG $NEXTCLOUD_TAG $MARIADB_TAG $REDIS_TAG $VAULTWARDEN_TAG $COLLABORA_TAG $VW_SIGNUPS $RAUTHY_ENC_KEYS $RAUTHY_ENC_KEY_ACTIVE $RAUTHY_ADMIN_PASSWORD $MYSQL_ROOT_PASSWORD $MYSQL_PASSWORD $REDIS_PASSWORD $VW_ADMIN_TOKEN $VW_SSO_CLIENT_SECRET $NC_OIDC_CLIENT_SECRET'

  mkdir -p "$DEPLOY_DIR/data/nextcloud/html" "$DEPLOY_DIR/data/nextcloud/data" \
           "$DEPLOY_DIR/data/nextcloud/db" "$DEPLOY_DIR/data/vaultwarden" \
           "$DEPLOY_DIR/data/rauthy" "$DEPLOY_DIR/rauthy-bootstrap" \
           "$DEPLOY_DIR/rauthy-config"

  cp -f "$TEMPLATE_DIR/docker-compose.yml" "$DEPLOY_DIR/docker-compose.yml"
  envsubst "$VARS" < "$TEMPLATE_DIR/env.tmpl" > "$DEPLOY_DIR/.env"
  envsubst '$CLOUD_DOMAIN $VAULT_DOMAIN $NC_OIDC_CLIENT_SECRET $VW_SSO_CLIENT_SECRET' \
    < "$TEMPLATE_DIR/rauthy/clients.json.tmpl" > "$DEPLOY_DIR/rauthy-bootstrap/clients.json"
  python3 -m json.tool "$DEPLOY_DIR/rauthy-bootstrap/clients.json" >/dev/null \
    || { err "clients.json ungueltig - Abbruch."; return 1; }
  envsubst '$AUTH_DOMAIN $BASE_DOMAIN $RAUTHY_ENC_KEYS $RAUTHY_ENC_KEY_ACTIVE $ACME_EMAIL $RAUTHY_ADMIN_PASSWORD $HQL_SECRET_RAFT $HQL_SECRET_API' \
    < "$TEMPLATE_DIR/rauthy/config.toml.tmpl" > "$DEPLOY_DIR/rauthy-config/config.toml"
  chown_uid 10001:10001 "$DEPLOY_DIR/data/rauthy"
  chown_uid 10001:10001 "$DEPLOY_DIR/rauthy-bootstrap"
  chown_uid 10001:10001 "$DEPLOY_DIR/rauthy-config"

  apply_website_pull
  echo; log "Stack gerendert (Rauthy-Admin + OIDC-Clients werden beim 1. Start gebootstrappt)."
}

st_up() {
  require_keys BASE_DOMAIN || return 1
  need_docker
  log "Starte Docker-Stack ..."; dc up -d
  log "Stack laeuft. Status: ./setup.sh stack status"
}

st_down() {
  require_keys BASE_DOMAIN || return 1
  confirm "Stack stoppen (docker compose down)?" Y || { echo "Abbruch."; return 0; }
  need_docker
  log "Stoppe Docker-Stack ..."; dc down
}

st_status() {
  require_keys BASE_DOMAIN || return 1
  need_docker
  echo "== Container =="
  dc ps || warn "(Stack laeuft nicht? './setup.sh stack up')"
  echo
  echo "============================================================"
  echo " Zugaenge:"
  echo "   Rauthy-Admin : https://$AUTH_DOMAIN/auth/v1/admin"
  echo "                  User $ACME_EMAIL  /  PW $RAUTHY_ADMIN_PASSWORD"
  echo "   Nextcloud    : https://$CLOUD_DOMAIN  (lokal: $NEXTCLOUD_ADMIN_USER / $NEXTCLOUD_ADMIN_PASSWORD)"
  echo "   Vaultwarden  : https://$VAULT_DOMAIN"
  echo "   Office/Coll. : https://$OFFICE_DOMAIN"
  echo "   Alle Secrets : $CONF_FILE"
  echo "============================================================"
}

st_all() {
  st_config
  need_docker
  log "Starte Docker-Stack ..."; dc up -d
  cad_render || warn "Caddy-Schritt uebersprungen/fehlgeschlagen - spaeter: ./setup.sh caddy render"
  nc_wire
  nc_office || warn "Office-Aktivierung uebersprungen - spaeter: ./setup.sh nextcloud office"
  echo; st_status
  echo " Google-Login: Rauthy-UI -> Providers -> Google (manuell)."
  echo " Cron-Backups/Updates optional: ./setup.sh backup cron | updates cron | vaultwarden export"
}
