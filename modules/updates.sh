#!/usr/bin/env bash
# modules/updates.sh - regelmaessige Auto-Updates (System-Pakete + Docker-Images)
# mit optionalem Auto-Neustart und Mail-Report (nur wenn SMTP eingerichtet ist).

register updates cron up_cron "Auto-Updates (System + Docker) per Cron einrichten"
register updates run  up_run  "Auto-Update jetzt ausfuehren (Cron-Runner)" 0

up_cron() {
  ensure_tool crontab cron
  local envf="$DEPLOY_DIR/.auto-update.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  echo; echo "Regelmaessige Auto-Updates (System-Pakete + Docker-Images) einrichten."
  echo "Hinweis: apt & Neustart brauchen root - Cron als root anlegen (sudo) oder passwortloses sudo."
  ask UPDATE_SYSTEM "System-Pakete via apt aktualisieren? (j/n)"       "${UPDATE_SYSTEM:-j}"
  ask UPDATE_DOCKER "Docker-Images aktualisieren + neu starten? (j/n)" "${UPDATE_DOCKER:-j}"
  ask AUTO_REBOOT   "Automatischer Neustart, falls noetig? (j/n)"      "${AUTO_REBOOT:-n}"
  ask MAIL_MODE     "E-Mail-Report (always/changes/never)"             "${MAIL_MODE:-changes}"
  ask UPDATE_SCHED  "Cron-Zeitplan"                                    "${UPDATE_SCHED:-30 4 * * 0}"
  umask 077
  cat > "$envf" <<EOF
# Von setup.sh (updates cron) erzeugt.
UPDATE_SYSTEM='$UPDATE_SYSTEM'
UPDATE_DOCKER='$UPDATE_DOCKER'
AUTO_REBOOT='$AUTO_REBOOT'
MAIL_MODE='$MAIL_MODE'
UPDATE_SCHED='$UPDATE_SCHED'
EOF
  chmod 600 "$envf"
  install_cron "$UPDATE_SCHED" "$SCRIPT_DIR/setup.sh updates run >> $DEPLOY_DIR/auto-update.log 2>&1" "home_stack-auto-update"
  if mailer_ready; then log "Mailer erkannt: Reports an SMTP_TO (Modus: $MAIL_MODE)."
  else warn "Kein Mailer - Reports nur im Log. Optional: ./setup.sh smtp setup"; fi
  log "Auto-Update aktiv ($UPDATE_SCHED). Testlauf: ./setup.sh updates run"
}

up_run() {
  # Runner: unter set -e nicht abbrechen, Fehler sammeln (wie v1 auto-update.sh).
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  local envf="$DEPLOY_DIR/.auto-update.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  : "${UPDATE_SYSTEM:=j}"; : "${UPDATE_DOCKER:=j}"; : "${AUTO_REBOOT:=n}"; : "${MAIL_MODE:=changes}"
  : "${REBOOT_FLAG:=/var/run/reboot-required}"
  need_docker
  report_init
  local HOST UPN UPOUT REBOOT_NEEDED=0
  HOST="$(hostname 2>/dev/null || echo host)"
  rlog "home_stack Auto-Update  $(date '+%F %T')  auf $HOST"; rlog ""

  if yesish "$UPDATE_SYSTEM" && command -v apt-get >/dev/null 2>&1; then
    rlog "== System-Pakete (apt) =="
    export DEBIAN_FRONTEND=noninteractive
    rcapture "apt-get update" $SUDO apt-get update -qq
    UPN="$($SUDO apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
    if [[ "${UPN:-0}" -gt 0 ]]; then
      rlog "$UPN Paket(e) werden aktualisiert."
      rcapture "apt-get upgrade" $SUDO apt-get -y -o Dpkg::Options::=--force-confold upgrade
      rcapture "apt-get autoremove" $SUDO apt-get -y autoremove --purge
      rchanged
    else rlog "System bereits aktuell."; fi
    rlog ""
  fi

  if yesish "$UPDATE_DOCKER"; then
    rlog "== Docker-Images =="
    if [[ -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
      rcapture "docker compose pull" dc pull
      UPOUT="$(dc up -d 2>&1)" || true; radd "$UPOUT"
      if printf '%s' "$UPOUT" | grep -qi 'recreat'; then
        rlog "Neue Images -> Container neu erstellt."
        rcapture "docker image prune" $SUDO docker image prune -f; rchanged
      else rlog "Docker-Images bereits aktuell."; fi
    else rlog "Kein docker-compose.yml in $DEPLOY_DIR - uebersprungen."; fi
    rlog ""
  fi

  if [[ -f "$REBOOT_FLAG" ]]; then
    REBOOT_NEEDED=1; rchanged
    rlog "!! Neustart erforderlich ($REBOOT_FLAG)."
    [[ -f "$REBOOT_FLAG.pkgs" ]] && rlog "   Ausloeser: $(tr '\n' ' ' < "$REBOOT_FLAG.pkgs" 2>/dev/null)"
    rlog ""
  fi

  if   [[ $REPORT_ERRORS -gt 0 ]]; then rlog "Ergebnis: $REPORT_ERRORS Fehler - Log: $DEPLOY_DIR/auto-update.log"
  elif [[ $REPORT_CHANGED -eq 1 ]]; then rlog "Ergebnis: Updates angewandt."
  else                                   rlog "Ergebnis: nichts zu tun."; fi

  local subj="home_stack Update: $HOST"
  [[ $REPORT_ERRORS -gt 0 ]] && subj="home_stack Update FEHLER: $HOST"

  if [[ $REBOOT_NEEDED -eq 1 ]] && yesish "$AUTO_REBOOT"; then
    rlog "AUTO_REBOOT aktiv -> Neustart in 1 Minute."
    report_send "$MAIL_MODE" "$subj"
    $SUDO shutdown -r +1 "home_stack auto-update: Neustart nach Updates" 2>/dev/null || $SUDO systemctl reboot
    [[ $_e -eq 1 ]] && set -e; return 0
  fi
  report_send "$MAIL_MODE" "$subj"
  local rc=0; [[ $REPORT_ERRORS -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e; return $rc
}
