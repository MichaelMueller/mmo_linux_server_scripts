#!/usr/bin/env bash
# modules/smtp.sh - SMTP-Zugang + gehaerteten Mailer (var/send-mail.sh) einrichten.
# Laeuft auch ohne gerenderten Stack (nutzt BASE_DOMAIN/ACME_EMAIL nur als Default).

register smtp setup smtp_setup "SMTP-Zugang + Mailer einrichten"

smtp_setup() {
  ensure_tool curl curl
  conf_load || true
  local envf="$DEPLOY_DIR/.smtp.env" script="$DEPLOY_DIR/send-mail.sh" pass2 tlsdef k
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  echo; echo "SMTP-Zugang einrichten. Zugangsdaten -> $envf (chmod 600, var/ ist gitignored)."
  echo "Tipp: bei Gmail/Outlook/GMX ein App-Passwort verwenden, nie das Hauptpasswort."; echo
  ask SMTP_HOST "SMTP-Server (Host)"                    "${SMTP_HOST:-}"
  ask SMTP_PORT "Port (465=implizit TLS, 587=STARTTLS)" "${SMTP_PORT:-465}"
  tlsdef="implicit"; [[ "$SMTP_PORT" == "587" ]] && tlsdef="starttls"
  ask SMTP_TLS  "TLS-Modus (implicit/starttls)"         "${SMTP_TLS:-$tlsdef}"
  ask SMTP_USER "SMTP-Benutzer (Login)"                 "${SMTP_USER:-${ACME_EMAIL:-}}"
  ask SMTP_FROM "Absender (From)"                       "${SMTP_FROM:-${ACME_EMAIL:-no-reply@${BASE_DOMAIN:-localhost}}}"
  ask SMTP_TO   "Standard-Empfaenger"                   "${SMTP_TO:-${ACME_EMAIL:-}}"
  ask_secret pass2 "SMTP-Passwort (leer = vorhandenes behalten)"
  [[ -n "$pass2" ]] && SMTP_PASS="$pass2"
  [[ -n "${SMTP_PASS:-}" ]] || { err "Kein Passwort gesetzt - Abbruch."; return 1; }
  [[ -n "$SMTP_HOST" && -n "$SMTP_USER" && -n "$SMTP_FROM" ]] \
    || { err "Host/User/From noetig - Abbruch."; return 1; }

  ensure_dir "$DEPLOY_DIR"; umask 077
  put() { printf "%s='%s'\n" "$1" "$(sq "${!1}")"; }
  {
    echo "# Von setup.sh (smtp setup) erzeugt - Zugangsdaten, NICHT committen."
    for k in SMTP_HOST SMTP_PORT SMTP_TLS SMTP_USER SMTP_PASS SMTP_FROM SMTP_TO; do put "$k"; done
    echo "# Statt Klartext das Passwort aus einem Secret-Store ziehen (dann SMTP_PASS leeren):"
    echo "# SMTP_PASS_CMD='cat /root/.smtp-pass'"
  } > "$envf"
  chmod 600 "$envf"
  install -m 700 "$TEMPLATE_DIR/send-mail.sh" "$script"
  log "Mailer angelegt: $script"
  echo "   Nutzung: $script -s 'Betreff' -t you@example.com 'Text'"
  echo "            echo Body | $script -s 'Betreff'   (an SMTP_TO)"
  if [[ -n "$SMTP_TO" ]] && confirm "Test-Mail an $SMTP_TO senden?" Y; then
    if printf 'Test von setup.sh (%s).\n' "$(date '+%F %T' 2>/dev/null || echo now)" \
         | "$script" -s "setup.sh SMTP-Test"; then
      log "Test-Mail versendet."
    else warn "Test fehlgeschlagen - Host/Port/TLS/Zugangsdaten pruefen ($envf)."; fi
  fi
}
