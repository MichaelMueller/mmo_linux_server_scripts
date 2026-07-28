#!/usr/bin/env bash
#
# setup.sh (v2) - zentrales Steuerungssystem fuer Linux-Server mit Webanwendungen.
#
#   ./setup.sh                     interaktives Menue
#   ./setup.sh <modul> <verb> ...  einen Befehl direkt   (-y = keine Rueckfragen)
#   ./setup.sh <modul>             Befehle eines Moduls anzeigen
#   ./setup.sh --help              alle Befehle
#   DEPLOY_DIR=/pfad ./setup.sh    Zielordner ueberschreiben
#
# Aufbau: lib/ (Kernbibliothek) + modules/ (registrieren ihre Befehle) + templates/.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
MODULE_DIR="$SCRIPT_DIR/modules"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
DEPLOY_DIR="${DEPLOY_DIR:-$SCRIPT_DIR/var}"
CONF_FILE="$DEPLOY_DIR/.setup.conf"

# --- Kernbibliothek laden ---
for _f in core ui conf cron docker mail report registry; do
  # shellcheck disable=SC1090
  source "$LIB_DIR/$_f.sh"
done

# --- Kategorien in Menue-Reihenfolge (Titel) ---
category server      "Server-Haertung (SSH / ufw / fail2ban)"
category smtp        "Mail / SMTP"
category updates     "Auto-Updates"
category health      "Health-Checks"
category docker      "Docker"
category caddy       "Caddy / Reverse-Proxy"
category stack       "Stack (Einrichtung & Betrieb)"
category backup      "Backup"
category rauthy      "Rauthy (SSO)"
category nextcloud   "Nextcloud"
category vaultwarden "Vaultwarden"

# --- Module laden (registrieren ihre Befehle) ---
for _f in "$MODULE_DIR"/*.sh "$MODULE_DIR"/apps/*.sh; do
  [[ -e "$_f" ]] || continue
  # shellcheck disable=SC1090
  source "$_f"
done

# --- Argumente: globale Flags herausziehen, Rest = modul verb args ---
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)          ASSUME_YES=1 ;;
    -h|--help|help)    show_help; exit 0 ;;
    *)                 ARGS+=("$1") ;;
  esac
  shift
done

if [[ ${#ARGS[@]} -eq 0 ]]; then menu; else dispatch "${ARGS[@]}"; fi
