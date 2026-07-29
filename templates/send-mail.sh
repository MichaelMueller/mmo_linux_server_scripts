#!/usr/bin/env bash
#
# send-mail.sh - minimaler, gehaerteter SMTP-Versand ueber curl.
#   Wird von 'setup.sh smtp install' nach var/ kopiert und liest die Zugangsdaten
#   aus .smtp.env daneben (chmod 600).
#
# Sicherheitsmerkmale:
#   - TLS wird ERZWUNGEN (--ssl-reqd), die Zertifikatspruefung bleibt an
#   - Zugangsdaten landen NIE in der Prozessliste: user:pass geht per curl-Config
#     ueber stdin (-K -) statt als Argument
#   - Nachricht in einem 0600-Tempfile, das beim Beenden geloescht wird
#   - Passwort optional aus einem Secret-Store via SMTP_PASS_CMD statt Klartext
#
# Aufruf:
#   ./send-mail.sh -s "Betreff" [-t "a@x,b@y"] [-a datei] ["Textkoerper"]
#   echo "Text" | ./send-mail.sh -s "Betreff" -t du@example.com
#   printf 'Report\n' | ./send-mail.sh -s "Backup" -a /pfad/archiv.tar.gz
#
# Ohne -t geht die Mail an SMTP_TO aus .smtp.env. Text aus Argument oder stdin.
#
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SMTP_ENV:-$DIR/.smtp.env}"
[[ -f "$CONF" ]] || { echo "SMTP-Konfig fehlt: $CONF  (erst: ./setup.sh smtp install)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

SUBJECT=""; TO="${SMTP_TO:-}"; ATTACH=""
while getopts "s:t:a:h" o; do
  case "$o" in
    s) SUBJECT="$OPTARG" ;;
    t) TO="$OPTARG" ;;
    a) ATTACH="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

command -v curl >/dev/null 2>&1 || { echo "curl fehlt." >&2; exit 1; }
[[ -n "${SMTP_HOST:-}" && -n "${SMTP_USER:-}" && -n "${SMTP_FROM:-}" ]] \
  || { echo "SMTP-Konfig unvollstaendig (SMTP_HOST/SMTP_USER/SMTP_FROM)." >&2; exit 1; }
[[ -n "$SUBJECT" ]] || { echo "Kein Betreff (-s)." >&2; exit 1; }
[[ -n "$TO" ]]      || { echo "Kein Empfaenger (-t oder SMTP_TO in .smtp.env)." >&2; exit 1; }
[[ -z "$ATTACH" || -f "$ATTACH" ]] || { echo "Anhang nicht gefunden: $ATTACH" >&2; exit 1; }

# Passwort: bevorzugt aus SMTP_PASS_CMD (Secret bleibt aus der Datei), sonst SMTP_PASS.
PASS="${SMTP_PASS:-}"
[[ -z "$PASS" && -n "${SMTP_PASS_CMD:-}" ]] && PASS="$(eval "$SMTP_PASS_CMD")"
[[ -n "$PASS" ]] || { echo "Kein Passwort (SMTP_PASS oder SMTP_PASS_CMD in .smtp.env)." >&2; exit 1; }

# Text aus Argument(en) oder stdin.
if [[ $# -gt 0 ]]; then BODY="$*"; else BODY="$(cat)"; fi

# Empfaengerliste (Komma-getrennt) -> je ein --mail-rcpt.
rcpt_args=(); IFS=',' read -ra _rcpts <<< "$TO"
for r in "${_rcpts[@]}"; do
  r="$(printf '%s' "$r" | tr -d '[:space:]')"
  [[ -n "$r" ]] && rcpt_args+=(--mail-rcpt "$r")
done
[[ ${#rcpt_args[@]} -gt 0 ]] || { echo "Kein gueltiger Empfaenger." >&2; exit 1; }

# Header duerfen nur ASCII enthalten -> Nicht-ASCII-Betreff nach RFC 2047 kodieren.
if LC_ALL=C grep -q '[^ -~]' <<< "$SUBJECT"; then
  SUBJECT_HDR="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')?="
else
  SUBJECT_HDR="$SUBJECT"
fi

MSG="$(mktemp)"; trap 'rm -f "$MSG"' EXIT
DATE="$(date -R 2>/dev/null || date)"
MSGID="<$(date +%s).$$@${SMTP_FROM##*@}>"

build_message() {
  printf 'From: %s\n' "$SMTP_FROM"
  printf 'To: %s\n' "$TO"
  printf 'Subject: %s\n' "$SUBJECT_HDR"
  printf 'Date: %s\n' "$DATE"
  printf 'Message-ID: %s\n' "$MSGID"
  printf 'MIME-Version: 1.0\n'
  if [[ -n "$ATTACH" ]]; then
    local b="=_${APP_BOUNDARY:-mailpart}_$$" name; name="$(basename "$ATTACH")"
    printf 'Content-Type: multipart/mixed; boundary="%s"\n\n' "$b"
    printf -- '--%s\n' "$b"
    printf 'Content-Type: text/plain; charset=UTF-8\n\n'
    printf '%s\n\n' "$BODY"
    printf -- '--%s\n' "$b"
    printf 'Content-Type: application/octet-stream; name="%s"\n' "$name"
    printf 'Content-Transfer-Encoding: base64\n'
    printf 'Content-Disposition: attachment; filename="%s"\n\n' "$name"
    base64 "$ATTACH"
    printf -- '\n--%s--\n' "$b"
  else
    printf 'Content-Type: text/plain; charset=UTF-8\n\n'
    printf '%s\n' "$BODY"
  fi
}
# Zeilenenden hart auf CRLF normalisieren (RFC 5322).
build_message | sed 's/\r$//; s/$/\r/' > "$MSG"

# 465 = implizites TLS (smtps://), 587 = STARTTLS auf smtp:// (+ --ssl-reqd).
PORT="${SMTP_PORT:-465}"
if [[ "${SMTP_TLS:-implicit}" == "starttls" && "$PORT" != "465" ]]; then
  URL="smtp://$SMTP_HOST:$PORT"
else
  URL="smtps://$SMTP_HOST:$PORT"
fi

# Backslash und " im Wert escapen (curl-Config-Quoting).
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

printf 'user = "%s:%s"\n' "$(esc "$SMTP_USER")" "$(esc "$PASS")" \
  | curl --silent --show-error --ssl-reqd \
         --url "$URL" \
         --mail-from "$SMTP_FROM" \
         "${rcpt_args[@]}" \
         --upload-file "$MSG" \
         --config -

echo "Mail an $TO gesendet ($URL)."
