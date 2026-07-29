#!/usr/bin/env bash
# lib/cron.sh - geplante Laeufe ueber /etc/cron.d (nicht die User-Crontab).
#
# Warum /etc/cron.d:
#   - explizites User-Feld: die Jobs laufen als root, also braucht apt kein
#     passwortloses sudo
#   - eigene Datei pro Job: anlegen/pruefen/entfernen ohne die Crontab zu parsen
#   - PATH kann gesetzt werden. Cron startet sonst mit /usr/bin:/bin, dann fehlt
#     /usr/local/bin und selbst installierte Tools werden nicht gefunden.

CRON_D="${CRON_D:-/etc/cron.d}"
CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Dateinamen in /etc/cron.d duerfen nur [A-Za-z0-9_-] enthalten (kein Punkt!).
cron_file() { printf '%s/%s-%s' "$CRON_D" "$APP_NAME" "$1"; }
cron_has()  { $SUDO test -f "$(cron_file "$1")"; }

# cron_install NAME "ZEITPLAN" "KOMMANDO" [USER]
cron_install() {
  local name="$1" sched="$2" cmd="$3" user="${4:-root}" f tmp
  f="$(cron_file "$name")"; tmp="$(mktemp)"
  {
    printf '# %s (%s) - erzeugt von setup.sh\n' "$APP_NAME" "$name"
    printf '# Entfernen mit: %s %s remove\n' "$SETUP_SH" "$name"
    printf 'PATH=%s\n' "$CRON_PATH"
    printf 'MAILTO=""\n'
    printf '%s %s %s\n' "$sched" "$user" "$cmd"
  } > "$tmp"
  $SUDO install -m 644 -o root -g root "$tmp" "$f" || { rm -f "$tmp"; err "Cron konnte nicht geschrieben werden."; return 1; }
  rm -f "$tmp"
  log "Cron aktiv: $f"
  warn "Zeitplan: $sched   (als $user)"
}

cron_remove() {
  local f; f="$(cron_file "$1")"
  cron_has "$1" || { warn "kein Cron-Eintrag vorhanden ($f)"; return 0; }
  $SUDO rm -f "$f"; log "Cron entfernt: $f"
}

# cron_show NAME  -> die wirksame Zeile(n) anzeigen.
cron_show() {
  local f; f="$(cron_file "$1")"
  if cron_has "$1"; then $SUDO grep -vE '^\s*(#|$)' "$f" | indent
  else printf '    (kein Cron-Eintrag: %s)\n' "$f"; fi
}
