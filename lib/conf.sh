#!/usr/bin/env bash
# lib/conf.sh - Konfiguration pro Modul: eine Datei je Modul unter DEPLOY_DIR.
#   var/.server.env  var/.smtp.env  var/.updates.env  var/.health.env  var/.caddy.env
# Format: KEY='wert' (single-quoted, sicher escaped) -> per source lesbar, 0600.
# Es gibt bewusst KEINE zentrale Sammel-Config: jedes Modul steht fuer sich und
# funktioniert unabhaengig von den anderen.

conf_file() { printf '%s/.%s.env' "$DEPLOY_DIR" "$1"; }

# Single-Quote-sicheres Escapen fuer Werte in '...'-Zuweisungen.
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# conf_load DATEI  -> sourct die Datei, wenn sie existiert (sonst still ok).
conf_load() { [[ -f "${1:-}" ]] || return 0
  # shellcheck disable=SC1090
  source "$1"; }

# conf_save DATEI KEY...  -> schreibt genau diese Keys aus den aktuellen Variablen.
conf_save() {
  local f="$1"; shift; local k
  umask 077; ensure_dir "$(dirname "$f")" || { err "Kann $(dirname "$f") nicht anlegen."; return 1; }
  {
    printf '# %s - erzeugt von setup.sh, %s\n' "$(basename "$f")" "$(date '+%F %T' 2>/dev/null || true)"
    printf '# Kann Zugangsdaten enthalten. chmod 600, nicht ins Git.\n'
    for k in "$@"; do printf "%s='%s'\n" "$k" "$(sq "${!k:-}")"; done
  } > "$f"
  chmod 600 "$f"
}

# conf_show DATEI  -> Config anzeigen, Passwoerter/Tokens maskiert.
conf_show() {
  local f="$1" k v
  [[ -f "$f" ]] || { printf '    (keine Config: %s)\n' "$f"; return 0; }
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    v="${v#\'}"; v="${v%\'}"
    case "$k" in *PASS*|*SECRET*|*TOKEN*|*KEY*) [[ -n "$v" ]] && v='********' ;; esac
    printf '    %-20s %s\n' "$k" "$v"
  done < "$f"
}

conf_remove() { local f="$1"; [[ -f "$f" ]] || return 0; rm -f "$f"; log "Config entfernt: $f"; }
