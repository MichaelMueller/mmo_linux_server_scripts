#!/usr/bin/env bash
# lib/ui.sh - Interaktion: Bestaetigen, Fragen, verdeckte Eingabe, Validierung.
# Mit -y / --yes (ASSUME_YES=1) wird nichts gefragt: confirm sagt ja, ask nimmt
# den Default. Das ist die Voraussetzung dafuer, dass Cron-Verben nie blockieren.

ASSUME_YES="${ASSUME_YES:-0}"

# confirm "Frage" [Y|N]   Default per 2. Argument (Gross Y = Default ja).
confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local q="$1" def="${2:-N}" ans
  if [[ "$def" == Y ]]; then
    read -rp "$q [J/n]: " ans || true
    [[ ! "$ans" =~ ^[nN] ]]
  else
    read -rp "$q [j/N]: " ans || true
    [[ "$ans" =~ ^[jJyY] ]]
  fi
}

# ask VAR "Frage" ["Default"]  -> ein bereits gesetzter Wert der Variablen
# gewinnt als Default (damit ein erneuter Durchlauf die alte Config vorschlaegt).
ask() {
  local var="$1" prompt="$2" def="${3:-}" cur="${!1:-}" val
  [[ -n "$cur" ]] && def="$cur"
  if [[ "$ASSUME_YES" == 1 ]]; then printf -v "$var" '%s' "$def"; return 0; fi
  read -rp "$prompt [$def]: " val || true
  printf -v "$var" '%s' "${val:-$def}"
}

# ask_choice VAR "Frage" "Default" OPT...  -> akzeptiert nur die genannten Werte.
ask_choice() {
  local var="$1" prompt="$2" def="$3"; shift 3
  local -a opts=("$@"); local o val list
  list="$(IFS=/; printf '%s' "${opts[*]}")"
  while true; do
    ask "$var" "$prompt ($list)" "$def"
    val="${!var}"
    for o in "${opts[@]}"; do [[ "$val" == "$o" ]] && return 0; done
    err "Bitte einen dieser Werte angeben: ${opts[*]}"
    [[ "$ASSUME_YES" == 1 ]] && { printf -v "$var" '%s' "$def"; return 0; }
    printf -v "$var" '%s' ''   # sonst wird die Falscheingabe zum neuen Default
  done
}

# ask_port VAR "Frage" "Default"  -> erzwingt 1-65535.
ask_port() {
  local var="$1" prompt="$2" def="$3"
  while true; do
    ask "$var" "$prompt" "$def"
    is_port "${!var}" && return 0
    err "Ungueltiger Port: ${!var}"
    [[ "$ASSUME_YES" == 1 ]] && return 1
    printf -v "$var" '%s' ''
  done
}

# ask_secret VAR "Frage"  -> verdeckte Eingabe (kein Echo, keine Historie).
ask_secret() {
  local var="$1" prompt="$2" val
  read -rsp "$prompt: " val || true; echo
  printf -v "$var" '%s' "$val"
}

yesish()  { [[ "${1:-}" =~ ^[jJyY] ]]; }
is_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
