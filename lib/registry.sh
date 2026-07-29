#!/usr/bin/env bash
# lib/registry.sh - Modul-Registry: Menue, CLI-Dispatch und Hilfe entstehen aus
# den register()-Aufrufen der Module. Keine hartcodierten Menuenummern.

declare -A CAT_TITLE=(); CAT_ORDER=()
declare -A CMD_FN=(); declare -A CMD_LABEL=(); declare -A CMD_MENU=()
declare -A MOD_VERBS=()

# category SCHLUESSEL "Titel"  -> Kategorie anlegen und Menue-Reihenfolge festhalten.
category() {
  local k="$1" t="$2"
  [[ -n "${CAT_TITLE[$k]:-}" ]] || CAT_ORDER+=("$k")
  CAT_TITLE[$k]="$t"
}

# register MODUL VERB FUNKTION "Label" [menu]   menu=0 -> nur CLI, nicht im Menue.
register() {
  local m="$1" v="$2" fn="$3" label="$4" menu="${5:-1}" key="$1 $2"
  [[ -n "${CMD_FN[$key]:-}" ]] && { err "register: '$key' ist doppelt belegt."; return 1; }
  CMD_FN[$key]="$fn"; CMD_LABEL[$key]="$label"; CMD_MENU[$key]="$menu"
  if [[ -z "${MOD_VERBS[$m]:-}" ]]; then MOD_VERBS[$m]="$v"
  else MOD_VERBS[$m]="${MOD_VERBS[$m]} $v"; fi
}

module_help() {
  local m="$1" v
  if [[ -z "${MOD_VERBS[$m]:-}" ]]; then
    err "Unbekanntes Modul: $m"
    warn "Bekannt sind: ${CAT_ORDER[*]}"
    warn "Alle Befehle: ./setup.sh --help"
    return 2
  fi
  printf '\n%s   [%s]\n' "${CAT_TITLE[$m]:-$m}" "$m"
  for v in ${MOD_VERBS[$m]}; do printf '  %-9s %s\n' "$v" "${CMD_LABEL[$m $v]}"; done
  echo
}

show_help() {
  local k v
  cat <<H
setup.sh - Server-Steuerung. Ohne Argument startet das interaktive Menue.

  ./setup.sh                       interaktives Menue
  ./setup.sh <modul> <verb> [...]  Befehl direkt ausfuehren
  ./setup.sh <modul>               Verben eines Moduls anzeigen

  -y, --yes    keine Rueckfragen (Defaults uebernehmen)
  --           alles danach unveraendert an das Verb durchreichen

H
  for k in "${CAT_ORDER[@]}"; do
    [[ -n "${MOD_VERBS[$k]:-}" ]] || continue
    printf '%s   [%s]\n' "${CAT_TITLE[$k]}" "$k"
    for v in ${MOD_VERBS[$k]}; do printf '  %-9s %s\n' "$v" "${CMD_LABEL[$k $v]}"; done
    echo
  done
}

# dispatch MODUL [VERB] [args...]
dispatch() {
  local m="${1:-}"; shift || true
  [[ -z "$m" ]] && { menu; return; }
  case "$m" in
    menu)             menu; return ;;
    help|-h|--help)   show_help; return ;;
  esac
  local v="${1:-}"
  [[ -z "$v" ]] && { module_help "$m"; return; }
  shift || true
  local fn="${CMD_FN[$m $v]:-}"
  if [[ -z "$fn" ]]; then
    err "Unbekannter Befehl: $m $v"
    module_help "$m" || true
    return 2
  fi
  "$fn" "$@"
}

menu() {
  local sel k v n
  while true; do
    local -a IDX=(); n=0
    printf '\n=== %s ===\n' "$APP_NAME"
    for k in "${CAT_ORDER[@]}"; do
      [[ -n "${MOD_VERBS[$k]:-}" ]] || continue
      local -a vis=()
      for v in ${MOD_VERBS[$k]}; do
        [[ "${CMD_MENU[$k $v]:-1}" == 1 ]] && vis+=("$v")
      done
      [[ ${#vis[@]} -eq 0 ]] && continue
      printf '\n %s\n' "${CAT_TITLE[$k]}"
      for v in "${vis[@]}"; do
        n=$((n+1)); IDX[$n]="$k $v"
        printf '  %2d) %s\n' "$n" "${CMD_LABEL[$k $v]}"
      done
    done
    printf '\n   q) Beenden\n'
    read -rp "Auswahl: " sel || break
    case "$sel" in
      q|Q|quit|exit) break ;;
      "")            continue ;;
      *[!0-9]*)      echo "Ungueltige Auswahl: $sel"; continue ;;
    esac
    local pick="${IDX[$sel]:-}"
    [[ -z "$pick" ]] && { echo "Ungueltige Auswahl: $sel"; continue; }
    echo
    # pick ist immer "modul verb" - bewusst gesplittet.
    local -a call=(); read -ra call <<< "$pick"
    dispatch "${call[@]}" || echo "    (abgebrochen - siehe Meldung oben)"
    echo; read -rp "Weiter mit [Enter] ..." _ || break
  done
}
