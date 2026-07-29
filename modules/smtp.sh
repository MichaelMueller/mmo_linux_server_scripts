#!/usr/bin/env bash
# modules/smtp.sh - SMTP-Zugang + Mailer (var/send-mail.sh) einrichten.
# Der Mailer ist die Grundlage fuer die Reports von updates und health; ohne ihn
# laufen die Cron-Jobs trotzdem, schreiben aber nur ins Log.

register smtp install smtp_install "SMTP-Zugang + Mailer einrichten"
register smtp status  smtp_status  "SMTP-Konfiguration anzeigen"
register smtp test    smtp_test    "Test-Mail senden"
register smtp remove  smtp_remove  "Mailer + Zugangsdaten entfernen"

smtp_install() {
  ensure_tool curl curl
  local cf script tlsdef pass2 k
  cf="$(conf_file smtp)"; script="$(mailer_path)"
  conf_load "$cf"

  echo
  echo "SMTP-Zugang einrichten. Die Zugangsdaten landen in $cf (chmod 600)."
  echo "Bei Gmail/Outlook/GMX ein App-Passwort verwenden, nie das Hauptpasswort."
  echo
  ask SMTP_HOST "SMTP-Server (Host)"                     "${SMTP_HOST:-}"
  ask_port SMTP_PORT "Port (465 = implizites TLS, 587 = STARTTLS)" "${SMTP_PORT:-465}" || return 1
  tlsdef="implicit"; [[ "$SMTP_PORT" == "587" ]] && tlsdef="starttls"
  ask_choice SMTP_TLS "TLS-Modus" "${SMTP_TLS:-$tlsdef}" implicit starttls
  ask SMTP_USER "SMTP-Benutzer (Login)"                  "${SMTP_USER:-}"
  ask SMTP_FROM "Absender (From)"                        "${SMTP_FROM:-${SMTP_USER:-}}"
  ask SMTP_TO   "Standard-Empfaenger fuer Reports"       "${SMTP_TO:-${SMTP_USER:-}}"
  ask_secret pass2 "SMTP-Passwort (leer = vorhandenes behalten)"
  [[ -n "$pass2" ]] && SMTP_PASS="$pass2"

  [[ -n "$SMTP_HOST" && -n "$SMTP_USER" && -n "$SMTP_FROM" ]] \
    || { err "Host, Benutzer und Absender sind Pflicht - Abbruch."; return 1; }
  [[ -n "${SMTP_PASS:-}" ]] || { err "Kein Passwort gesetzt - Abbruch."; return 1; }

  conf_save "$cf" SMTP_HOST SMTP_PORT SMTP_TLS SMTP_USER SMTP_PASS SMTP_FROM SMTP_TO || return 1
  # Hinweis auf die Secret-Store-Variante direkt in die Datei schreiben.
  {
    printf '# Alternative zum Klartext-Passwort: SMTP_PASS leeren und stattdessen\n'
    printf '# ein Kommando hinterlegen, das das Passwort auf stdout ausgibt:\n'
    printf "# SMTP_PASS_CMD='cat /root/.smtp-pass'\n"
  } >> "$cf"

  ensure_dir "$DEPLOY_DIR"
  install -m 700 "$TEMPLATE_DIR/send-mail.sh" "$script"
  log "Mailer angelegt: $script"
  echo "    Direkt nutzbar:  $script -s 'Betreff' -t du@example.com 'Text'"
  echo "                     echo Text | $script -s 'Betreff'"

  if [[ -n "${SMTP_TO:-}" ]] && confirm "Test-Mail an $SMTP_TO senden?" Y; then
    smtp_test
  fi
}

smtp_status() {
  local cf; cf="$(conf_file smtp)"
  echo "== Konfiguration =="
  conf_show "$cf"
  echo
  echo "== Mailer =="
  if [[ -x "$(mailer_path)" ]]; then printf '    %s (ausfuehrbar)\n' "$(mailer_path)"
  elif [[ -f "$(mailer_path)" ]]; then printf '    %s vorhanden, aber NICHT ausfuehrbar\n' "$(mailer_path)"
  else printf '    (kein Mailer: %s)\n' "$(mailer_path)"; fi
  echo
  if mailer_ready; then log "Mailversand ist einsatzbereit - updates/health koennen Reports schicken."
  else warn "Nicht einsatzbereit: './setup.sh smtp install' ausfuehren."; fi
}

smtp_test() {
  mailer_ready || { err "SMTP ist nicht eingerichtet - erst: ./setup.sh smtp install"; return 1; }
  local to; conf_load "$(conf_file smtp)"; to="${SMTP_TO:-}"
  [[ -n "$to" ]] || { err "Kein SMTP_TO in $(conf_file smtp)."; return 1; }
  if printf 'Test von setup.sh auf %s (%s).\n' "$(hostname 2>/dev/null || echo host)" \
       "$(date '+%F %T' 2>/dev/null || echo jetzt)" | "$(mailer_path)" -s "$APP_NAME SMTP-Test"; then
    log "Test-Mail an $to versendet."
  else
    err "Versand fehlgeschlagen. Host/Port/TLS/Zugangsdaten pruefen: $(conf_file smtp)"
    return 1
  fi
}

smtp_remove() {
  echo "Entfernt Mailer und SMTP-Zugangsdaten."
  warn "updates und health schreiben danach nur noch ins Log, keine Mails mehr."
  confirm "Fortfahren?" || { echo "Abbruch."; return 0; }
  rm -f "$(mailer_path)"; log "entfernt: $(mailer_path)"
  conf_remove "$(conf_file smtp)"
}
