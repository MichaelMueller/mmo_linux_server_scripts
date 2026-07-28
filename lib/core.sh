#!/usr/bin/env bash
# lib/core.sh - Basis-Helfer: Rechte, Tool-Installation, Logging, Zufalls-Secrets.
# Wird von setup.sh gesourct (nicht direkt ausfuehren).

SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '   %s\n' "$*"; }
err()  { printf '!! %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Verzeichnis anlegen (mit sudo-Fallback + Uebernahme der Rechte).
ensure_dir() { local d="$1"; [[ -d "$d" && -w "$d" ]] && return 0
  mkdir -p "$d" 2>/dev/null || { $SUDO mkdir -p "$d"; $SUDO chown "$(id -u):$(id -g)" "$d"; }; }
# Rekursiv chownen (Fallback 777, falls chown scheitert).
chown_uid() { $SUDO chown -R "$1" "$2" 2>/dev/null || chmod -R 777 "$2"; }

gen()  { openssl rand -hex 32; }                          # 64 hex chars
genb() { openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-48; }

apt_install() { $SUDO apt-get update -qq && $SUDO apt-get install -y "$@"; }
# ensure_tool CMD PAKET  -> installiert PAKET, falls CMD fehlt (nur apt-Systeme).
ensure_tool() { command -v "$1" >/dev/null 2>&1 && return 0
  if command -v apt-get >/dev/null 2>&1; then log "installiere $2 ..."; apt_install "$2"
  else die "Bitte '$1' manuell installieren."; fi; }
