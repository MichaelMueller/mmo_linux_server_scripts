#!/usr/bin/env bash
# modules/apps/nextcloud.sh - Nextcloud steuern (inkl. gestuftem Major-Upgrade).

register nextcloud status  nc_status  "Status + Version"
register nextcloud update  nc_update  "Aktualisieren (gestuft, eine Major pro Schritt)"
register nextcloud wire    nc_wire    "Mit Rauthy (OIDC) verbinden"
register nextcloud office  nc_office  "Office (Collabora) aktivieren"
register nextcloud migrate nc_migrate "ownCloud-Dateien umziehen (rsync + scan)"
register nextcloud occ     nc_occ     "occ-Befehl ausfuehren: ... occ <args>"
register nextcloud logs    nc_logs    "Logs" 0
register nextcloud up      nc_up      "starten" 0
register nextcloud down    nc_down    "stoppen" 0
register nextcloud restart nc_restart "neu starten" 0

_NC=nextcloud

nc_logs()    { require_keys BASE_DOMAIN || return 1; need_docker; dc logs --tail="${1:-200}" "$_NC"; }
nc_up()      { require_keys BASE_DOMAIN || return 1; need_docker; dc up -d "$_NC"; }
nc_down()    { require_keys BASE_DOMAIN || return 1; need_docker; dc stop "$_NC"; }
nc_restart() { require_keys BASE_DOMAIN || return 1; need_docker; dc restart "$_NC"; }
nc_occ()     { require_keys BASE_DOMAIN || return 1; need_docker; occ "$@"; }

_nc_major() { occ status --output=json 2>/dev/null | sed -n 's/.*"versionstring":"\([0-9]\+\)\..*/\1/p'; }

nc_status() {
  require_keys BASE_DOMAIN || return 1; need_docker
  dc ps "$_NC"; echo
  occ status 2>/dev/null || warn "(occ nicht erreichbar - laeuft der Stack?)"
}

nc_wire() {
  require_keys AUTH_DOMAIN NC_OIDC_CLIENT_SECRET || return 1
  need_docker
  log "Warte auf Nextcloud (Erstinstallation kann einige Minuten dauern) ..."
  local i=0
  until occ status --output=json 2>/dev/null | grep -q '"installed":true' || [[ $i -ge 100 ]]; do sleep 3; i=$((i+1)); done
  if ! occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
    warn "Nextcloud noch nicht fertig installiert - spaeter './setup.sh nextcloud wire' erneut."; return 0
  fi
  log "Verbinde Nextcloud mit Rauthy (OIDC) ..."
  occ app:install user_oidc 2>/dev/null || occ app:enable user_oidc
  if occ user_oidc:provider Rauthy \
       --clientid="nextcloud" --clientsecret="$NC_OIDC_CLIENT_SECRET" \
       --discoveryuri="https://$AUTH_DOMAIN/auth/v1/.well-known/openid-configuration" \
       --scope="openid email profile" --mapping-uid="preferred_username" 2>/dev/null; then
    log "Nextcloud-OIDC gesetzt."
  else
    warn "OIDC noch nicht gesetzt (DNS/Zertifikat evtl. noch nicht aktiv). Spaeter erneut: ./setup.sh nextcloud wire"
  fi
}

nc_office() {
  require_keys OFFICE_DOMAIN CLOUD_DOMAIN || return 1
  ensure_tool curl curl; need_docker
  log "Warte auf Collabora (Start kann 1-2 Minuten dauern) ..."
  local ci=0
  until curl -sfo /dev/null http://127.0.0.1:9980/hosting/discovery || [[ $ci -ge 40 ]]; do sleep 3; ci=$((ci+1)); done
  log "Aktiviere Nextcloud Office (richdocuments) -> https://$OFFICE_DOMAIN"
  occ app:install richdocuments 2>/dev/null || occ app:enable richdocuments
  occ config:app:set richdocuments wopi_url --value "https://$OFFICE_DOMAIN"
  occ config:app:set richdocuments public_wopi_url --value "https://$OFFICE_DOMAIN"
  occ config:app:set richdocuments wopi_allowlist --value "127.0.0.1,::1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"
  if curl -sfo /dev/null http://127.0.0.1:9980/hosting/discovery; then
    occ richdocuments:activate-config 2>/dev/null || true; log "Office aktiv."
  else
    warn "Collabora antwortet noch nicht (127.0.0.1:9980) - spaeter erneut: ./setup.sh nextcloud office"
  fi
}

# Gestuftes Major-Upgrade: eine Version nach der anderen (Nextcloud verbietet Spruenge).
nc_update() {
  require_keys NEXTCLOUD_TAG CLOUD_DOMAIN || return 1; need_docker
  local ver target m tag now i
  ver="$(_nc_major)"
  [[ -n "$ver" ]] || { err "Laufende Nextcloud-Version nicht ermittelbar (laeuft der Stack?)."; return 1; }
  log "Laufende Nextcloud-Major: $ver"
  ask target "Ziel-Major" "$((ver+1))"
  [[ "$target" =~ ^[0-9]+$ ]] || { err "Ziel muss eine Zahl sein."; return 1; }
  [[ "$target" -le "$ver" ]] && { log "Ziel $target <= aktuell $ver - nichts zu tun."; return 0; }
  warn "Nextcloud erlaubt nur EINE Major pro Schritt -> $ver..$target in Einzelschritten."
  if confirm "Vorher ein Backup anlegen (dringend empfohlen)?" Y; then
    bk_backup || { err "Backup fehlgeschlagen - Upgrade abgebrochen."; return 1; }
  fi
  for (( m=ver+1; m<=target; m++ )); do
    echo; log "=== Upgrade auf Nextcloud $m ==="
    confirm "Jetzt auf $m?" Y || { warn "Gestoppt bei Major $((m-1))."; return 0; }
    tag="$m-apache"
    conf_set NEXTCLOUD_TAG "$tag"; env_set NEXTCLOUD_TAG "$tag" || return 1
    dc pull "$_NC"    || { err "pull fehlgeschlagen."; return 1; }
    dc up -d "$_NC"   || { err "up fehlgeschlagen."; return 1; }
    i=0
    until occ status --output=json 2>/dev/null | grep -q '"installed":true' || [[ $i -ge 60 ]]; do sleep 3; i=$((i+1)); done
    occ upgrade 2>/dev/null || true            # falls der Entrypoint es nicht schon tat
    occ app:update --all 2>/dev/null || true
    now="$(_nc_major)"
    log "Jetzt Nextcloud-Major: ${now:-?}"
    [[ "$now" == "$m" ]] || { err "Upgrade auf $m nicht bestaetigt (Version=${now:-?}) - stoppe. Logs: ./setup.sh nextcloud logs"; return 1; }
  done
  log "Nextcloud-Upgrade abgeschlossen (Major $target)."
}

nc_migrate() {
  require_keys BASE_DOMAIN || return 1; need_docker; ensure_tool rsync rsync
  local ncdata="$DEPLOY_DIR/data/nextcloud/data" src_host src_base m entry old new
  echo; echo "ownCloud/Nextcloud-DATEIEN umziehen - nur files/ (keine Shares/Kalender/Versionen)."
  echo "Ablauf je Nutzer: rsync -> chown 33:33 -> occ files:scan. Erst ein Trockenlauf."
  echo "Achtung: war im alten ownCloud die Server-Verschluesselung an, vorher dort 'occ encryption:decrypt-all'."; echo
  read -rp "Quelle SSH-Ziel (user@altserver; leer = lokaler Pfad hier): " src_host || true
  read -rp "Quell-Datenbasis (mit den User-Ordnern, z.B. /var/www/owncloud/data): " src_base || true
  [[ -n "$src_base" ]] || { err "Kein Quellpfad - Abbruch."; return 1; }
  echo; echo "Ziel-Nutzer (Ordnernamen) in Nextcloud:"; occ user:list 2>/dev/null || echo "  (occ nicht erreichbar)"
  echo; echo "Nutzer-Mapping ALT=NEU (oder nur NAME, wenn gleich). Leere Eingabe = fertig."
  local -a maps=()
  while read -rp "  Mapping [Enter=fertig]: " m && [[ -n "$m" ]]; do maps+=("$m"); done
  [[ ${#maps[@]} -gt 0 ]] || { err "Keine Nutzer angegeben - Abbruch."; return 1; }
  _nc_srcpath() { local o="$1" s; s="$src_base/$o/files/"; [[ -n "$src_host" ]] && s="$src_host:$s"; printf '%s' "$s"; }

  echo; echo "=== Trockenlauf (nichts wird veraendert) ==="
  for entry in "${maps[@]}"; do
    old="${entry%%=*}"; new="${entry#*=}"; [[ "$entry" == *=* ]] || new="$old"
    echo "-- $old -> $new"
    [[ -d "$ncdata/$new" ]] || { warn "! Zielnutzer '$new' fehlt ($ncdata/$new) - erst per SSO einloggen lassen."; continue; }
    rsync -aH --dry-run --stats "$(_nc_srcpath "$old")" "$ncdata/$new/files/" || warn "(rsync-Fehler - Quelle/SSH/Pfad pruefen)"
  done
  confirm "Jetzt WIRKLICH kopieren (rsync + chown + scan)?" || { echo "Abbruch - nichts geaendert."; return 0; }
  for entry in "${maps[@]}"; do
    old="${entry%%=*}"; new="${entry#*=}"; [[ "$entry" == *=* ]] || new="$old"
    echo; echo "== $old -> $new =="
    [[ -d "$ncdata/$new" ]] || { warn "! Zielnutzer '$new' fehlt - uebersprungen."; continue; }
    mkdir -p "$ncdata/$new/files"
    rsync -aH --info=progress2 "$(_nc_srcpath "$old")" "$ncdata/$new/files/" || { warn "rsync fehlgeschlagen - uebersprungen."; continue; }
    chown_uid 33:33 "$ncdata/$new/files"
    occ files:scan --path="$new/files" || warn "files:scan-Fehler - spaeter: occ files:scan --path=\"$new/files\""
  done
  echo; log "Fertig. Kontrolle: ./setup.sh nextcloud occ files:scan --all"
}
