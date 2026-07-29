#!/usr/bin/env bash
# lib/mail.sh - Mailversand ueber den optionalen Mailer aus dem smtp-Modul.
# Ohne eingerichtetes SMTP ist notify() ein No-op: die Runner von updates/health
# laufen dann trotzdem durch und schreiben nur ins Log.

mailer_path()  { printf '%s/send-mail.sh' "$DEPLOY_DIR"; }
mailer_ready() { [[ -x "$(mailer_path)" && -f "$(conf_file smtp)" ]]; }

# notify "Betreff"   (Mailtext kommt via stdin)
notify() {
  local subj="$1"
  if mailer_ready; then
    "$(mailer_path)" -s "$subj"
  else
    cat >/dev/null 2>&1 || true   # stdin leeren, damit der Aufrufer nicht blockiert
  fi
}
