#!/usr/bin/env bash
# lib/mail.sh - notify() nutzt den optionalen SMTP-Mailer (var/send-mail.sh).
# Ist kein Mailer eingerichtet, ist notify() ein No-op (stdin wird verworfen).

mailer_ready() { [[ -x "$DEPLOY_DIR/send-mail.sh" && -f "$DEPLOY_DIR/.smtp.env" ]]; }

notify() { # notify SUBJECT   (Body via stdin)
  local subj="$1"
  if mailer_ready; then
    "$DEPLOY_DIR/send-mail.sh" -s "$subj" || return 1
  else
    cat >/dev/null 2>&1 || true
  fi
}
