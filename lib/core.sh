#!/usr/bin/env bash
# lib/core.sh - Basis: Rechte, Ausgabe, Verzeichnisse, Tool-Installation, Dienste.
# Wird von setup.sh gesourct, nicht direkt ausfuehren.

# Als root laeuft alles direkt, sonst ueber sudo. $SUDO wird absichtlich UNGEQUOTET
# expandiert - als root verschwindet es dann restlos aus der Kommandozeile.
SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '    %s\n' "$*"; }
err()  { printf '!!  %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf -- '------------------------------------------------------------\n'; }
indent() { sed 's/^/    /'; }

have() { command -v "$1" >/dev/null 2>&1; }

# Verzeichnis anlegen; bei Bedarf per sudo und danach dem aufrufenden User uebergeben.
ensure_dir() {
  local d="$1"
  [[ -d "$d" && -w "$d" ]] && return 0
  mkdir -p "$d" 2>/dev/null && return 0
  $SUDO mkdir -p "$d" || return 1
  $SUDO chown "$(id -u):$(id -g)" "$d"
}

apt_install() { $SUDO apt-get update -qq && $SUDO apt-get install -y "$@"; }

# ensure_tool KOMMANDO PAKET -> installiert PAKET, wenn KOMMANDO fehlt (apt-Systeme).
ensure_tool() {
  have "$1" && return 0
  have apt-get || die "'$1' fehlt und es gibt kein apt-get. Bitte manuell installieren."
  log "installiere $2 ..."
  apt_install "$2"
  have "$1" || die "'$1' ist auch nach der Installation von '$2' nicht verfuegbar."
}

# --- systemd ---------------------------------------------------------------
unit_exists()  { $SUDO systemctl cat "$1" >/dev/null 2>&1; }
unit_active()  { $SUDO systemctl is-active --quiet "$1"; }
unit_enabled() { $SUDO systemctl is-enabled --quiet "$1" 2>/dev/null; }

# Kurzstatus einer Unit fuer status-Ausgaben: "aktiv (enabled)" / "gestoppt" / "-".
unit_state() {
  local u="$1" a e
  unit_exists "$u" || { printf 'nicht installiert'; return 0; }
  if unit_active "$u"; then a="aktiv"; else a="gestoppt"; fi
  if unit_enabled "$u"; then e="enabled"; else e="disabled"; fi
  printf '%s (%s)' "$a" "$e"
}

# --- Logdateien ------------------------------------------------------------
# Cron laeuft als root und haengt per >> an. Die Datei wird daher schon beim
# Einrichten vom aufrufenden User angelegt, damit sie ihm gehoert und lesbar bleibt.
log_path()    { printf '%s/%s.log' "$DEPLOY_DIR" "$1"; }
log_prepare() { local f; f="$(log_path "$1")"; ensure_dir "$DEPLOY_DIR"
  [[ -f "$f" ]] || : > "$f"; chmod 640 "$f" 2>/dev/null || true; printf '%s' "$f"; }

# Letzte Zeilen einer Logdatei anzeigen (auch wenn root sie geschrieben hat).
log_tail() {
  local f n="${2:-15}"; f="$(log_path "$1")"
  if [[ -r "$f" ]]; then tail -n "$n" "$f" | indent
  elif $SUDO test -f "$f"; then $SUDO tail -n "$n" "$f" | indent
  else echo "    (noch kein Log: $f)"; fi
}

trim() { local s="${1//$'\t'/ }"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
