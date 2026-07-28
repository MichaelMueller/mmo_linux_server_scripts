#!/usr/bin/env bash
# lib/conf.sh - zentrale Konfiguration (var/.setup.conf).
# CONF_FILE + DEPLOY_DIR werden von setup.sh gesetzt.

# Single-Quote-sicheres Escapen fuer Werte in '...'-Zuweisungen.
sq() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

conf_load() { [[ -f "$CONF_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONF_FILE"; }

# conf_set KEY VALUE  -> schreibt/aktualisiert einen Schluessel (ohne sed-Delimiter-Fallen).
conf_set() {
  local k="$1" v="$2" tmp; umask 077; ensure_dir "$DEPLOY_DIR"; touch "$CONF_FILE"
  tmp="$(mktemp)"
  grep -v "^$k=" "$CONF_FILE" 2>/dev/null > "$tmp" || true
  printf "%s='%s'\n" "$k" "$(sq "$v")" >> "$tmp"
  cat "$tmp" > "$CONF_FILE"; rm -f "$tmp"; chmod 600 "$CONF_FILE"
}

# env_set KEY VALUE  -> gezielt einen Wert in var/.env aendern (fuer App-Updates/Toggles).
# .env-Format ist unquoted (KEY=VALUE), wie von env.tmpl gerendert.
env_set() {
  local k="$1" v="$2" f="$DEPLOY_DIR/.env" tmp
  [[ -f "$f" ]] || { err ".env fehlt - erst: ./setup.sh stack config"; return 1; }
  tmp="$(mktemp)"; grep -v "^$k=" "$f" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# require_keys KEY...  -> sourct Conf und prueft, dass alle Keys gesetzt sind.
# Nur stack-/app-Module brauchen das; allgemeine Module laufen ohne gerenderten Stack.
require_keys() { conf_load; local k miss=0
  for k in "$@"; do [[ -n "${!k:-}" ]] || { err "Fehlt in Konfiguration: $k  (erst: ./setup.sh stack config)"; miss=1; }; done
  [[ $miss -eq 0 ]]; }
