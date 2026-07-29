#!/usr/bin/env bash
# modules/updates.sh - automatische System-Updates (apt) per Cron, mit Report.
# Der Cron-Job laeuft als root (siehe lib/cron.sh), apt braucht daher kein sudo.

register updates install up_install "Auto-Updates einrichten (apt, per Cron)"
register updates status  up_status  "Status: Cron, Config, offene Updates"
register updates remove  up_remove  "Auto-Updates entfernen"
register updates run     up_run     "Jetzt ausfuehren (Cron-Runner)" 0

UP_JOB="updates"
REBOOT_FLAG="${REBOOT_FLAG:-/var/run/reboot-required}"

up_install() {
  have apt-get || { err "Dieses Modul setzt apt voraus."; return 1; }
  local cf logf; cf="$(conf_file updates)"; conf_load "$cf"

  echo
  echo "Regelmaessige System-Updates einrichten (apt update + upgrade + autoremove)."
  echo
  ask_choice UPDATE_MODE "Upgrade-Variante" "${UPDATE_MODE:-upgrade}" upgrade full-upgrade
  echo "    upgrade      = konservativ, entfernt/installiert keine Pakete"
  echo "    full-upgrade = darf Pakete entfernen, wenn Abhaengigkeiten es verlangen"
  echo
  ask_choice AUTO_REBOOT "Automatisch neu starten, falls noetig" "${AUTO_REBOOT:-n}" j n
  ask_choice MAIL_MODE   "E-Mail-Report" "${MAIL_MODE:-changes}" always changes never
  ask UPDATE_SCHED       "Cron-Zeitplan" "${UPDATE_SCHED:-30 4 * * 0}"

  conf_save "$cf" UPDATE_MODE AUTO_REBOOT MAIL_MODE UPDATE_SCHED || return 1
  logf="$(log_prepare "$UP_JOB")"
  cron_install "$UP_JOB" "$UPDATE_SCHED" "$SETUP_SH updates run >> $logf 2>&1" root || return 1

  if mailer_ready; then log "Mailer erkannt: Reports gehen raus (Modus: $MAIL_MODE)."
  else warn "Kein Mailer - Reports nur im Log. Optional: ./setup.sh smtp install"; fi
  log "Testlauf: ./setup.sh updates run"
}

up_status() {
  echo "== Cron =="
  cron_show "$UP_JOB"
  echo; echo "== Konfiguration =="
  conf_show "$(conf_file updates)"
  echo; echo "== Offene Updates =="
  if have apt-get; then
    local n
    n="$($SUDO apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
    printf '    %s Paket(e) wuerden aktualisiert\n' "${n:-0}"
    if [[ "${n:-0}" -gt 0 ]]; then
      $SUDO apt-get -s upgrade 2>/dev/null | awk '/^Inst/{print $2, $3}' | head -20 | indent
      [[ "$n" -gt 20 ]] && printf '    ... (%s weitere)\n' "$((n-20))"
    fi
  else
    printf '    (kein apt-get)\n'
  fi
  echo; echo "== Neustart =="
  if [[ -f "$REBOOT_FLAG" ]]; then
    printf '    ERFORDERLICH (%s)\n' "$REBOOT_FLAG"
    [[ -r "$REBOOT_FLAG.pkgs" ]] && printf '    Ausloeser: %s\n' "$(tr '\n' ' ' < "$REBOOT_FLAG.pkgs")"
  else
    printf '    nicht erforderlich\n'
  fi
  echo; echo "== Letzter Lauf =="
  log_tail "$UP_JOB" 15
}

up_remove() {
  confirm "Auto-Updates entfernen (Cron-Eintrag loeschen)?" Y || { echo "Abbruch."; return 0; }
  cron_remove "$UP_JOB"
  if confirm "Auch die Konfiguration loeschen?"; then conf_remove "$(conf_file updates)"; fi
}

# --- Cron-Runner -----------------------------------------------------------
# Laeuft unbeaufsichtigt: set -e wird abgeschaltet, Fehler werden gesammelt und
# am Ende gemeldet, statt den Lauf mitten drin abzubrechen.
up_run() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  conf_load "$(conf_file updates)"
  : "${UPDATE_MODE:=upgrade}"; : "${AUTO_REBOOT:=n}"; : "${MAIL_MODE:=changes}"

  report_init
  local HOST n subj rc=0
  HOST="$(hostname 2>/dev/null || echo host)"
  rlog "$APP_NAME Auto-Update   $(date '+%F %T')   auf $HOST"
  rlog ""

  if ! have apt-get; then
    rerror "apt-get nicht gefunden - nichts zu tun."
  else
    export DEBIAN_FRONTEND=noninteractive
    rlog "== apt =="
    rcapture "apt-get update" $SUDO apt-get update -qq
    n="$($SUDO apt-get -s "$UPDATE_MODE" 2>/dev/null | grep -c '^Inst')"
    if [[ "${n:-0}" -gt 0 ]]; then
      rlog "$n Paket(e) werden aktualisiert ($UPDATE_MODE)."
      rcapture "apt-get $UPDATE_MODE" $SUDO apt-get -y \
        -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$UPDATE_MODE"
      rcapture "apt-get autoremove" $SUDO apt-get -y autoremove --purge
      rchanged
    else
      rlog "System ist aktuell."
    fi
    rlog ""
  fi

  local reboot_needed=0
  if [[ -f "$REBOOT_FLAG" ]]; then
    reboot_needed=1; rchanged
    rlog "!! Neustart erforderlich ($REBOOT_FLAG)."
    [[ -r "$REBOOT_FLAG.pkgs" ]] && rlog "   Ausloeser: $(tr '\n' ' ' < "$REBOOT_FLAG.pkgs")"
    rlog ""
  fi

  if   [[ $REPORT_ERRORS -gt 0 ]]; then rlog "Ergebnis: $REPORT_ERRORS Fehler."
  elif [[ $REPORT_CHANGED -eq 1 ]]; then rlog "Ergebnis: Updates angewandt."
  else                                   rlog "Ergebnis: nichts zu tun."
  fi

  subj="$APP_NAME Update: $HOST"
  [[ $REPORT_ERRORS -gt 0 ]] && subj="$APP_NAME Update FEHLER: $HOST"

  if [[ $reboot_needed -eq 1 ]] && yesish "$AUTO_REBOOT"; then
    rlog "AUTO_REBOOT ist an -> Neustart in 1 Minute."
    report_send "$MAIL_MODE" "$subj"      # erst mailen, dann neu starten
    $SUDO shutdown -r +1 "$APP_NAME: Neustart nach Updates" 2>/dev/null || $SUDO systemctl reboot
    [[ $_e -eq 1 ]] && set -e
    return 0
  fi

  report_send "$MAIL_MODE" "$subj"
  [[ $REPORT_ERRORS -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e
  return $rc
}
