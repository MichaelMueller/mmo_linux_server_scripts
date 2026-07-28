#!/usr/bin/env bash
# lib/ui.sh - Interaktion: Bestaetigungen, Abfragen (mit Merk-Defaults).

ASSUME_YES="${ASSUME_YES:-0}"

# confirm "Frage" [Y|N]  -> Default per 2. Arg; mit ASSUME_YES immer ja.
confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local q="$1" def="${2:-N}" ans
  if [[ "$def" == Y ]]; then read -rp "$q [J/n]: " ans || true; [[ ! "$ans" =~ ^[nN] ]]
  else read -rp "$q [j/N]: " ans || true; [[ "$ans" =~ ^[jJyY] ]]; fi
}

# ask VAR "Frage" "Default"  -> merkt bisherigen Wert der Variablen als Default.
ask() { local var="$1" prompt="$2" def="${3:-}" cur="${!1:-}" val
  [[ -n "$cur" ]] && def="$cur"
  read -rp "$prompt [${def}]: " val || true; printf -v "$var" '%s' "${val:-$def}"; }

# ask_secret VAR "Frage"  -> verdeckte Eingabe.
ask_secret() { local var="$1" prompt="$2" val
  read -rsp "$prompt: " val || true; echo; printf -v "$var" '%s' "$val"; }

# yesish "j"  -> wahr bei j/J/y/Y...
yesish() { [[ "${1:-}" =~ ^[jJyY] ]]; }
