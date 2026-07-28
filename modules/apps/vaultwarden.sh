#!/usr/bin/env bash
# modules/apps/vaultwarden.sh - Vaultwarden steuern (inkl. Notfall-Export + Signups).

register vaultwarden status     vw_status     "Status"
register vaultwarden update     vw_update     "Aktualisieren (Image-Tag)"
register vaultwarden signups    vw_signups    "Registrierung ein/aus (on|off)"
register vaultwarden export     vw_export     "Notfall-Export per Cron einrichten"
register vaultwarden export-run vw_export_run "Export ausfuehren (Cron-Runner)" 0
register vaultwarden logs       vw_logs       "Logs" 0
register vaultwarden up         vw_up         "starten" 0
register vaultwarden down       vw_down       "stoppen" 0
register vaultwarden restart    vw_restart    "neu starten" 0

_VW=vaultwarden

vw_status()  { require_keys BASE_DOMAIN || return 1; need_docker; dc ps "$_VW"; }
vw_logs()    { require_keys BASE_DOMAIN || return 1; need_docker; dc logs --tail="${1:-200}" "$_VW"; }
vw_up()      { require_keys BASE_DOMAIN || return 1; need_docker; dc up -d "$_VW"; }
vw_down()    { require_keys BASE_DOMAIN || return 1; need_docker; dc stop "$_VW"; }
vw_restart() { require_keys BASE_DOMAIN || return 1; need_docker; dc restart "$_VW"; }

vw_update() {
  require_keys VAULTWARDEN_TAG || return 1; need_docker
  local new; ask new "Neuer Vaultwarden-Tag" "$VAULTWARDEN_TAG"
  confirm "Vaultwarden auf '$new' aktualisieren (pull + recreate)?" Y || { echo "Abbruch."; return 0; }
  conf_set VAULTWARDEN_TAG "$new"; env_set VAULTWARDEN_TAG "$new" || return 1
  dc pull "$_VW" || { err "pull fehlgeschlagen."; return 1; }
  dc up -d "$_VW" || { err "up fehlgeschlagen."; return 1; }
  sleep 2; dc ps "$_VW"; log "Vaultwarden auf '$new'."
}

vw_signups() {
  require_keys BASE_DOMAIN || return 1
  local val="${1:-}"
  case "$val" in
    on|true)   val=true ;;
    off|false) val=false ;;
    *) read -rp "Registrierung (on/off): " val; case "$val" in on|true) val=true ;; *) val=false ;; esac ;;
  esac
  need_docker
  conf_set VW_SIGNUPS "$val"; env_set VW_SIGNUPS "$val" || return 1
  dc up -d "$_VW"
  log "Vaultwarden SIGNUPS_ALLOWED=$val (Container neu erstellt)."
}

_vw_ensure_bw() {
  command -v bw >/dev/null 2>&1 && return 0
  log "Installiere Bitwarden CLI (offizielle Binary) ..."
  ensure_tool curl curl; ensure_tool unzip unzip
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/bw.zip" "https://vault.bitwarden.com/download/?app=cli&platform=linux"
  unzip -o "$tmp/bw.zip" -d "$tmp" >/dev/null
  $SUDO install -m 755 "$tmp/bw" /usr/local/bin/bw
  rm -rf "$tmp"
}

vw_export() {
  require_keys VAULT_DOMAIN || return 1
  ensure_tool crontab cron; _vw_ensure_bw
  local envf="$DEPLOY_DIR/.vw-export.env" dir keep sched cid csec mpw epw
  echo
  echo "!! API-Key + Master-Passwort landen in $envf (chmod 600); der Export ist"
  echo "   zusaetzlich mit einem eigenen Passwort verschluesselt."
  echo "   API-Key: Vaultwarden Web-Vault -> Account Settings -> Security -> Keys."
  echo
  read -rp "Rotation (Anzahl Exporte) [7]: " keep; keep="${keep:-7}"
  read -rp "Cron-Zeitplan [30 3 * * *]: " sched; sched="${sched:-30 3 * * *}"
  read -rp "API client_id: " cid
  ask_secret csec "API client_secret"
  ask_secret mpw  "Vaultwarden Master-Passwort"
  ask_secret epw  "Export-Passwort (leer = zufaellig)"
  if [[ -z "$epw" ]]; then epw="$(genb)"; echo ">> Export-Passwort: $epw  (SICHER notieren - ohne das kein Import!)"; fi
  dir="$DEPLOY_DIR/vw-backups"; ensure_dir "$dir"; umask 077
  cat > "$envf" <<EOF
BW_SERVER='https://${VAULT_DOMAIN}'
BW_CLIENTID='$(sq "$cid")'
BW_CLIENTSECRET='$(sq "$csec")'
BW_PASSWORD='$(sq "$mpw")'
VW_EXPORT_PASSWORD='$(sq "$epw")'
VW_EXPORT_DIR='$dir'
VW_EXPORT_KEEP='$keep'
EOF
  chmod 600 "$envf"
  install_cron "$sched" "$SCRIPT_DIR/setup.sh vaultwarden export-run >> $DEPLOY_DIR/vw-export.log 2>&1" "home_stack-vw-export"
  log "Cron aktiv. Exporte: $dir (Rotation $keep). Testlauf: ./setup.sh vaultwarden export-run"
}

vw_export_run() {
  local envf="${VW_EXPORT_CONF:-$DEPLOY_DIR/.vw-export.env}"
  [[ -f "$envf" ]] || { err "Config fehlt: $envf  (erst: ./setup.sh vaultwarden export)"; return 1; }
  # shellcheck disable=SC1090
  source "$envf"
  command -v bw >/dev/null 2>&1 || { err "bw (Bitwarden CLI) fehlt."; return 1; }
  : "${VW_EXPORT_DIR:=$DEPLOY_DIR/vw-backups}"; : "${VW_EXPORT_KEEP:=7}"
  export BITWARDENCLI_APPDATA_DIR="${BITWARDENCLI_APPDATA_DIR:-$VW_EXPORT_DIR/.bw}"
  mkdir -p "$VW_EXPORT_DIR"
  export BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD
  bw config server "$BW_SERVER" >/dev/null
  bw logout >/dev/null 2>&1 || true
  bw login --apikey >/dev/null
  local sess; sess="$(bw unlock --passwordenv BW_PASSWORD --raw)"; export BW_SESSION="$sess"
  bw sync >/dev/null
  local ts out; ts="$(date +%Y%m%d-%H%M%S)"; out="$VW_EXPORT_DIR/vault-$ts.json"
  bw export --format encrypted_json --password "$VW_EXPORT_PASSWORD" --output "$out" >/dev/null
  chmod 600 "$out"
  bw lock >/dev/null 2>&1 || true; bw logout >/dev/null 2>&1 || true
  local -a old; mapfile -t old < <(ls -1t "$VW_EXPORT_DIR"/vault-*.json 2>/dev/null | tail -n +$((VW_EXPORT_KEEP+1)))
  [[ ${#old[@]} -gt 0 ]] && rm -f "${old[@]}"
  echo "$(date '+%F %T') export ok -> $out  (behalte $VW_EXPORT_KEEP)"
}
