#!/usr/bin/env bash
#
# setup.sh - Steuerungsskript fuer Linux-Server: Haertung (SSH/ufw/fail2ban),
#   Mail, Auto-Updates, Health-Checks, TCP-Erreichbarkeit, Caddy-vHosts.
#
#   ./setup.sh                       interaktives Menue
#   ./setup.sh <modul> <verb> [...]  Befehl direkt ausfuehren
#   ./setup.sh <modul>               Verben eines Moduls anzeigen
#   ./setup.sh --help                alle Befehle
#
#   -y | --yes    keine Rueckfragen (Defaults uebernehmen)
#   --            alles danach unveraendert an das Verb durchreichen
#
#   DEPLOY_DIR=/pfad ./setup.sh      Ablage fuer Configs und Logs umbiegen
#
# Aufbau: lib/ (Kernbibliothek) + modules/ (registrieren ihre Verben) + templates/.
#
set -euo pipefail

# Geht in Cron-Dateinamen, Mail-Betreffs und Konfigurationsnamen ein.
APP_NAME="mmo_linux_server_scripts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/setup.sh"
LIB_DIR="$SCRIPT_DIR/lib"
MODULE_DIR="$SCRIPT_DIR/modules"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Ablage fuer Modul-Configs (0600) und Logs. Liegt per Default im Repo unter var/
# und ist dort via .gitignore ausgeschlossen.
DEPLOY_DIR="${DEPLOY_DIR:-$SCRIPT_DIR/var}"

# --- Kernbibliothek (Reihenfolge zaehlt: core zuerst) ---
for _f in core ui conf cron mail report registry; do
  [[ -r "$LIB_DIR/$_f.sh" ]] || { echo "!!  lib/$_f.sh fehlt in $LIB_DIR" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$LIB_DIR/$_f.sh"
done

# --- Kategorien in Menue-Reihenfolge ---
category server  "Server-Haertung (SSH / ufw / fail2ban)"
category smtp    "Mail / SMTP"
category updates "Auto-Updates"
category health  "Health-Checks"
category tcp     "TCP-Erreichbarkeit"
category caddy   "Caddy / vHosts"

# --- Module laden (registrieren beim Sourcen ihre Verben) ---
for _f in "$MODULE_DIR"/*.sh; do
  [[ -e "$_f" ]] || continue
  # shellcheck disable=SC1090
  source "$_f"
done

# --- Globale Flags herausziehen, Rest = modul verb args ---
ARGS=(); PASSTHRU=0
while [[ $# -gt 0 ]]; do
  if [[ $PASSTHRU -eq 1 ]]; then ARGS+=("$1"); shift; continue; fi
  case "$1" in
    --)        PASSTHRU=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help|help)
      # Nur als erstes Argument ist es die globale Hilfe, sonst gehoert es dem Verb.
      if [[ ${#ARGS[@]} -eq 0 ]]; then show_help; exit 0; else ARGS+=("$1"); fi ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done

if [[ ${#ARGS[@]} -eq 0 ]]; then menu; else dispatch "${ARGS[@]}"; fi
