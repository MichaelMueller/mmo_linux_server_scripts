#!/usr/bin/env bash
# modules/apps/rauthy.sh - Rauthy (Identity Provider / SSO) steuern.

register rauthy status  ra_status  "Status"
register rauthy update  ra_update  "Aktualisieren (Image-Tag)"
register rauthy admin   ra_admin   "Admin-Zugang anzeigen"
register rauthy logs    ra_logs    "Logs" 0
register rauthy up      ra_up      "starten" 0
register rauthy down    ra_down    "stoppen" 0
register rauthy restart ra_restart "neu starten" 0

_RA=rauthy

ra_status()  { require_keys BASE_DOMAIN || return 1; need_docker; dc ps "$_RA"; }
ra_logs()    { require_keys BASE_DOMAIN || return 1; need_docker; dc logs --tail="${1:-200}" "$_RA"; }
ra_up()      { require_keys BASE_DOMAIN || return 1; need_docker; dc up -d "$_RA"; }
ra_down()    { require_keys BASE_DOMAIN || return 1; need_docker; dc stop "$_RA"; }
ra_restart() { require_keys BASE_DOMAIN || return 1; need_docker; dc restart "$_RA"; }

ra_admin() {
  require_keys AUTH_DOMAIN ACME_EMAIL RAUTHY_ADMIN_PASSWORD || return 1
  echo "Rauthy-Admin : https://$AUTH_DOMAIN/auth/v1/admin"
  echo "User         : $ACME_EMAIL"
  echo "Passwort     : $RAUTHY_ADMIN_PASSWORD"
}

ra_update() {
  require_keys RAUTHY_TAG || return 1; need_docker
  local new; ask new "Neuer Rauthy-Tag" "$RAUTHY_TAG"
  warn "Rauthy ist pre-1.0 - Release-Notes pruefen (config.toml kann sich zwischen Versionen aendern)."
  confirm "Rauthy auf '$new' aktualisieren (pull + recreate)?" Y || { echo "Abbruch."; return 0; }
  conf_set RAUTHY_TAG "$new"; env_set RAUTHY_TAG "$new" || return 1
  dc pull "$_RA" || { err "pull fehlgeschlagen."; return 1; }
  dc up -d "$_RA" || { err "up fehlgeschlagen."; return 1; }
  sleep 2; dc ps "$_RA"
  log "Rauthy auf '$new'. Logs pruefen: ./setup.sh rauthy logs"
}
