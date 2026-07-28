#!/usr/bin/env bash
# modules/backup.sh - verschluesseltes Backup/Restore (GPG/AES256) + Nightly-Runner.

register backup run         bk_backup       "Backup jetzt (hot)"
register backup cold        bk_backup_cold  "Backup (cold, mit Downtime)"
register backup restore     bk_restore      "Restore"
register backup list        bk_list         "Backups auflisten"
register backup cron        bk_cron         "Naechtliches Backup per Cron einrichten"
register backup nightly-run bk_nightly_run  "Nightly-Backup ausfuehren (Cron-Runner)" 0

BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"

_bk_getpass() { # _bk_getpass [confirm]
  if [[ -n "${BACKUP_PASSPHRASE_FILE:-}" ]]; then
    [[ -f "$BACKUP_PASSPHRASE_FILE" ]] || { err "Passphrase-Datei fehlt: $BACKUP_PASSPHRASE_FILE"; return 1; }
    PASS="$(cat "$BACKUP_PASSPHRASE_FILE")"
  else
    read -rsp "Backup-Passphrase: " PASS; echo
    if [[ "${1:-}" == confirm ]]; then read -rsp "wiederholen: " P2; echo
      [[ "$PASS" == "$P2" ]] || { err "Passphrase stimmt nicht ueberein."; return 1; }; fi
  fi
  [[ -n "$PASS" ]] || { err "Leere Passphrase."; return 1; }
}
_bk_enc() { gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$1" - 3<<<"$PASS"; }
_bk_dec() { gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 -d "$1" 3<<<"$PASS"; }

bk_backup() {
  local COLD=0; [[ "${1:-}" == "--cold" ]] && COLD=1
  require_keys BASE_DOMAIN || return 1
  ensure_tool gpg gnupg; ensure_tool tar tar; need_docker
  _bk_getpass confirm || return 1
  ensure_dir "$BACKUP_DIR"
  local ts out tmp; ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/home_stack-backup-$ts.tar.gz.gpg"
  tmp="$DEPLOY_DIR/.backup-tmp"; rm -rf "$tmp"; mkdir -p "$tmp"
  local -a paths=( .setup.conf .env docker-compose.yml data/rauthy
                   data/nextcloud/data data/nextcloud/html data/vaultwarden )
  if [[ $COLD -eq 1 ]]; then
    log "Kaltes Backup: stoppe Stack ..."; dc stop; paths+=( data/nextcloud/db )
  else
    log "DB-Dump (--single-transaction) ..."
    dc exec -T nextcloud-db sh -c \
      'exec mariadb-dump --single-transaction --routines --triggers -uroot -p"$MARIADB_ROOT_PASSWORD" nextcloud' \
      > "$tmp/nextcloud-db.sql" || { err "DB-Dump fehlgeschlagen (laeuft der Stack?)."; return 1; }
    paths+=( .backup-tmp/nextcloud-db.sql )
  fi
  log "Packe & verschluessle -> $out"
  tar -C "$DEPLOY_DIR" --exclude='data/nextcloud/data/*/files/!tray/backup' \
      -czf - "${paths[@]}" | _bk_enc "$out"
  rm -rf "$tmp"
  [[ $COLD -eq 1 ]] && { log "starte Stack ..."; dc up -d; }
  log "Fertig: $out  ($(du -h "$out" | cut -f1))"
}

bk_backup_cold() { bk_backup --cold; }

bk_restore() {
  local in="${1:-}"
  if [[ -z "$in" ]]; then bk_list; read -rp "Backup-Datei: " in || true; fi
  [[ -f "$in" ]] || { err "Datei fehlt: $in"; return 1; }
  require_keys BASE_DOMAIN || return 1
  ensure_tool gpg gnupg; ensure_tool tar tar; need_docker
  echo "!! ACHTUNG: ueberschreibt Daten in $DEPLOY_DIR"
  local c; read -rp "Wirklich wiederherstellen? (tippe: ja) " c
  [[ "$c" == ja ]] || { echo "Abbruch."; return 0; }
  _bk_getpass || return 1
  ensure_dir "$DEPLOY_DIR"
  log "stoppe Stack ..."; dc down || true
  log "entschluessle & entpacke ..."
  _bk_dec "$in" | tar -C "$DEPLOY_DIR" -xzf -
  if [[ -f "$DEPLOY_DIR/.backup-tmp/nextcloud-db.sql" ]]; then
    log "starte DB und importiere Dump ..."; dc up -d nextcloud-db
    local i=0
    until dc exec -T nextcloud-db mariadb-admin ping --silent >/dev/null 2>&1 || [[ $i -ge 30 ]]; do sleep 2; i=$((i+1)); done
    dc exec -T nextcloud-db sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" nextcloud' \
      < "$DEPLOY_DIR/.backup-tmp/nextcloud-db.sql"
    rm -rf "$DEPLOY_DIR/.backup-tmp"
  fi
  log "starte Stack ..."; dc up -d
  log "Restore fertig."
}

bk_list() { ls -lh "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null || echo "(keine Backups in $BACKUP_DIR)"; }

bk_cron() {
  ensure_tool crontab cron
  local envf="$DEPLOY_DIR/.backup-nightly.env" passfile uid keep sched p1 p2
  echo; echo "Naechtliches heisses Backup per Cron einrichten."
  read -rp "Passphrase-Datei [$DEPLOY_DIR/.backup-pass]: " passfile || true
  passfile="${passfile:-$DEPLOY_DIR/.backup-pass}"
  if [[ ! -f "$passfile" ]]; then
    ask_secret p1 "Backup-Passphrase (neu)"; ask_secret p2 "wiederholen"
    [[ -n "$p1" && "$p1" == "$p2" ]] || { err "Passphrase leer/ungleich - Abbruch."; return 1; }
    umask 077; printf '%s' "$p1" > "$passfile"; chmod 600 "$passfile"
    log "Passphrase gespeichert: $passfile (chmod 600 - SICHER aufbewahren, sonst kein Restore!)"
  fi
  read -rp "Nextcloud-Sync-User-ID (optional, Kopie in dessen Ordner) []: " uid || true
  read -rp "Archive behalten (Rotation) [7]: " keep || true; keep="${keep:-7}"
  read -rp "Cron-Zeitplan [30 3 * * *]: " sched || true; sched="${sched:-30 3 * * *}"
  umask 077
  cat > "$envf" <<EOF
BACKUP_PASSPHRASE_FILE='$passfile'
BACKUP_KEEP='$keep'
NC_SYNC_UID='$uid'
EOF
  chmod 600 "$envf"
  install_cron "$sched" "$SCRIPT_DIR/setup.sh backup nightly-run >> $DEPLOY_DIR/backup-nightly.log 2>&1" "home_stack-nightly"
  if mailer_ready; then log "Mailer erkannt: Report bei Aenderung/Fehler."; else warn "Kein Mailer - nur Log. Optional: ./setup.sh smtp setup"; fi
  log "Nightly-Backup aktiv ($sched). Testlauf: ./setup.sh backup nightly-run"
}

bk_nightly_run() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  local envf="$DEPLOY_DIR/.backup-nightly.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  : "${BACKUP_KEEP:=7}"
  if [[ -z "${BACKUP_PASSPHRASE_FILE:-}" ]]; then err "BACKUP_PASSPHRASE_FILE fehlt (in $envf)."; [[ $_e -eq 1 ]] && set -e; return 1; fi
  export BACKUP_PASSPHRASE_FILE
  need_docker; report_init
  local HOST bk; HOST="$(hostname 2>/dev/null || echo host)"
  rlog "home_stack Nightly-Backup  $(date '+%F %T')  auf $HOST"; rlog ""
  rcapture "backup" bk_backup
  bk="$(ls -1t "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null | head -1)"
  if [[ -z "$bk" ]]; then rerror "Kein Backup erzeugt."; else
    rlog "Backup: $bk  ($(du -h "$bk" 2>/dev/null | cut -f1))"; rchanged
    local -a old; mapfile -t old < <(ls -1t "$BACKUP_DIR"/*.tar.gz.gpg 2>/dev/null | tail -n +$((BACKUP_KEEP+1)))
    [[ ${#old[@]} -gt 0 ]] && { rm -f "${old[@]}"; rlog "Rotation: ${#old[@]} alte entfernt (behalte $BACKUP_KEEP)."; }
    if [[ -n "${NC_SYNC_UID:-}" ]]; then
      local tray="$DEPLOY_DIR/data/nextcloud/data/$NC_SYNC_UID/files/!tray"
      mkdir -p "$tray/backup"; rm -f "$tray/backup"/*.tar.gz.gpg; cp "$bk" "$tray/backup/"
      chown -R 33:33 "$tray" 2>/dev/null || true
      ( cd "$DEPLOY_DIR" && $DOCKER compose exec -T -u www-data nextcloud php occ files:scan --path="$NC_SYNC_UID/files/!tray" ) >/dev/null 2>&1 || true
      rlog "Kopie in Nextcloud-Ordner: $NC_SYNC_UID/files/!tray/backup."
    fi
  fi
  rlog ""; [[ $REPORT_ERRORS -gt 0 ]] && rlog "Ergebnis: FEHLER." || rlog "Ergebnis: ok (behalte $BACKUP_KEEP)."
  local subj="home_stack Backup: $HOST"; [[ $REPORT_ERRORS -gt 0 ]] && subj="home_stack Backup FEHLER: $HOST"
  report_send changes "$subj"
  local rc=0; [[ $REPORT_ERRORS -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e; return $rc
}
