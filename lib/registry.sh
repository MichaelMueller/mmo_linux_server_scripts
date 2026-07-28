#!/usr/bin/env bash
# lib/registry.sh - Modul-Registry + Menue/Dispatch/Help.
# Module rufen beim Sourcen category()/register() auf; setup.sh baut daraus
# das nummerierte Menue und die CLI-Dispatch-Tabelle (keine hartcodierten Nummern).

declare -A CAT_TITLE=(); CAT_ORDER=()
declare -A CMD_FN=(); declare -A CMD_LABEL=(); declare -A CMD_MENU=()
declare -A MOD_VERBS=()

# category KEY "Titel"  -> legt Kategorie + Menue-Reihenfolge fest.
category() { local k="$1" t="$2"
  [[ -n "${CAT_TITLE[$k]:-}" ]] || CAT_ORDER+=("$k")
  CAT_TITLE[$k]="$t"; }

# register MODUL VERB FUNKTION "Label" [menu=1]  -> registriert einen Befehl.
register() {
  local m="$1" v="$2" fn="$3" label="$4" menu="${5:-1}" key="$1 $2"
  CMD_FN[$key]="$fn"; CMD_LABEL[$key]="$label"; CMD_MENU[$key]="$menu"
  if [[ -z "${MOD_VERBS[$m]:-}" ]]; then MOD_VERBS[$m]="$v"
  else MOD_VERBS[$m]="${MOD_VERBS[$m]} $v"; fi
}

module_help() { local m="$1" v
  [[ -n "${MOD_VERBS[$m]:-}" ]] || { err "Unbekanntes Modul: $m"; return 2; }
  printf 'Modul "%s" - %s\n' "$m" "${CAT_TITLE[$m]:-}"
  for v in ${MOD_VERBS[$m]}; do printf '  %-14s %s\n' "$v" "${CMD_LABEL[$m $v]}"; done
}

show_help() { local k v
  cat <<'H'
setup.sh - zentrales Server-Steuerungssystem. Ohne Argument: interaktives Menue.

  ./setup.sh                     interaktives Menue
  ./setup.sh <modul> <verb> ...  Befehl direkt   (-y = keine Rueckfragen)
  ./setup.sh <modul>             Befehle des Moduls anzeigen

H
  for k in "${CAT_ORDER[@]}"; do
    [[ -n "${MOD_VERBS[$k]:-}" ]] || continue
    printf '%s  [%s]\n' "${CAT_TITLE[$k]}" "$k"
    for v in ${MOD_VERBS[$k]}; do printf '  %-14s %s\n' "$v" "${CMD_LABEL[$k $v]}"; done
    echo
  done
}

# dispatch MODUL [VERB] [args...]
dispatch() { local m="${1:-}"; shift || true
  [[ -z "$m" ]] && { menu; return; }
  case "$m" in menu) menu; return ;; help|-h|--help) show_help; return ;; esac
  local v="${1:-}"
  [[ -z "$v" ]] && { module_help "$m"; return; }
  shift || true
  local fn="${CMD_FN[$m $v]:-}"
  [[ -n "$fn" ]] || { err "Unbekannt: $m $v"; module_help "$m" || true; return 2; }
  "$fn" "$@"
}

menu() { local sel pick k v n
  while true; do
    local -a IDX=(); n=0
    printf '\n=== home_stack control ===\n'
    for k in "${CAT_ORDER[@]}"; do
      [[ -n "${MOD_VERBS[$k]:-}" ]] || continue
      local -a vis=()
      for v in ${MOD_VERBS[$k]}; do [[ "${CMD_MENU[$k $v]:-1}" == 1 ]] && vis+=("$v"); done
      [[ ${#vis[@]} -eq 0 ]] && continue
      printf ' %s\n' "${CAT_TITLE[$k]}"
      for v in "${vis[@]}"; do n=$((n+1)); IDX[$n]="$k $v"
        printf '  %2d) %s\n' "$n" "${CMD_LABEL[$k $v]}"; done
    done
    printf '   q) Beenden\n'
    read -rp "Auswahl: " sel || break
    case "$sel" in
      q|Q|quit|exit) break ;;
      "") continue ;;
      *[!0-9]*) echo "Ungueltige Auswahl: $sel"; continue ;;
    esac
    pick="${IDX[$sel]:-}"; [[ -z "$pick" ]] && { echo "Ungueltige Auswahl: $sel"; continue; }
    echo
    # shellcheck disable=SC2086
    dispatch $pick || echo "   (abgebrochen - siehe Meldung oben)"
    echo; read -rp "Weiter mit [Enter] ..." _ || break
  done
}
