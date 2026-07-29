#!/usr/bin/env bash
# modules/tcp.sh - TCP-Erreichbarkeit von Diensten ueberwachen.
#
# Kern ist eine Zustandsmaschine: fuer jeden Dienst wird der letzte bekannte
# Zustand (up/down) gespeichert. Gemailt wird NUR beim Wechsel:
#   up   -> down   Fehlermeldung
#   down -> down   Stille (kein Nachtreten)
#   down -> up     Entwarnung mit Ausfalldauer
#   neu  -> up     Stille (Erstaufnahme ist kein Vorfall)
#   neu  -> down   Fehlermeldung
#
# Dateien:
#   var/tcp-services   Definitionen  name|host|port      (vom Benutzer gepflegt)
#   var/tcp-state      Zustand       name|up|epoch       (vom Runner geschrieben)
#
# 'check' prueft und zeigt nur an - es aendert den Zustand NICHT und mailt nicht.
# Nur 'run' (der Cron-Runner) fuehrt die Zustandsmaschine und verschickt Mails.

# CRUD fuer die Dienste: add / list / edit / remove  (wie bei caddy den vHosts).
# Die Ueberwachung selbst: install / uninstall  - bewusst NICHT 'remove', damit
# 'tcp remove' eindeutig den Dienst und nicht den Cron-Job meint.
register tcp install   tcp_install   "Ueberwachung einrichten (Cron)"
register tcp add       tcp_add       "Dienst aufnehmen"
register tcp list      tcp_list      "Dienste + letzter Zustand"
register tcp edit      tcp_edit      "Dienst aendern"
register tcp remove    tcp_remove    "Dienst entfernen"
register tcp check     tcp_check     "Jetzt pruefen (ohne Mail, ohne Zustandsaenderung)"
register tcp status    tcp_status    "Status: Cron, Config, letzter Lauf"
register tcp uninstall tcp_uninstall "Ueberwachung abschalten"
register tcp run       tcp_run       "Pruefen + bei Wechsel mailen (Cron-Runner)" 0

TCP_JOB="tcp"
TCP_TOTAL=0; TCP_DOWN=0; TCP_NEW_DOWN=0; TCP_NEW_UP=0; TCP_CHANGES=()

tcp_services_file() { printf '%s/tcp-services' "$DEPLOY_DIR"; }
tcp_state_file()    { printf '%s/tcp-state' "$DEPLOY_DIR"; }

# --- Dateizugriff ----------------------------------------------------------

_tcp_lines() {
  local f; f="$(tcp_services_file)"
  [[ -r "$f" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

_tcp_count() { _tcp_lines | wc -l | tr -d ' '; }

# _tcp_find NAME -> gibt die Zeile aus, 1 wenn es den Dienst nicht gibt
_tcp_find() {
  local line
  line="$(_tcp_lines | grep -m1 "^$1|" || true)"
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

_tcp_services_write() { # stdin = neuer Inhalt
  local f tmp; f="$(tcp_services_file)"; tmp="$(mktemp)"
  cat > "$tmp"
  umask 077; ensure_dir "$DEPLOY_DIR" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f" || { rm -f "$tmp"; err "Kann $f nicht schreiben."; return 1; }
  rm -f "$tmp"; chmod 644 "$f"
}

# Der Zustand wird vom Cron-Runner als root geschrieben. Erst direkt versuchen
# (manueller Lauf im eigenen var/), dann per sudo.
_tcp_state_write() { # $1 = Quelldatei
  local f="$(tcp_state_file)"
  cp "$1" "$f" 2>/dev/null || $SUDO install -m 644 "$1" "$f"
}

# _tcp_state_get NAME -> "zustand epoch" (Default "unknown 0")
_tcp_state_get() {
  local f line; f="$(tcp_state_file)"
  if [[ -r "$f" ]]; then line="$(grep -m1 "^$1|" "$f" 2>/dev/null || true)"
  elif $SUDO test -f "$f"; then line="$($SUDO grep -m1 "^$1|" "$f" 2>/dev/null || true)"
  fi
  # Zeilenumbruch am Ende ist Pflicht: ohne ihn gibt das lesende 'read' EOF
  # zurueck (Exit 1) und reisst unter 'set -e' den Aufrufer mit.
  if [[ -z "${line:-}" ]]; then printf 'unknown 0\n'; return 0; fi
  local IFS='|'; local -a p=(); read -ra p <<< "$line"
  printf '%s %s\n' "${p[1]:-unknown}" "${p[2]:-0}"
}

# --- Pruefung --------------------------------------------------------------

# Ein TCP-Connect. Bevorzugt bash /dev/tcp (keine Abhaengigkeit); scheitert das
# und es gibt nc, wird damit gegengeprueft - so fuehrt ein bash ohne
# Netz-Redirections nicht zu falschen DOWN-Meldungen.
_tcp_connect() {
  local host="$1" port="$2" t="${TCP_TIMEOUT:-3}"
  if timeout "$t" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$host" "$port" 2>/dev/null; then
    return 0
  fi
  if have nc; then nc -z -w "$t" "$host" "$port" >/dev/null 2>&1 && return 0; fi
  return 1
}

# Mit Wiederholungen, damit ein einzelnes verlorenes Paket keinen Alarm macht.
_tcp_probe() {
  local host="$1" port="$2" i n="${TCP_RETRIES:-2}"
  for (( i=1; i<=n; i++ )); do
    _tcp_connect "$host" "$port" && return 0
    [[ $i -lt $n ]] && sleep 1
  done
  return 1
}

_tcp_dur() {
  local s="${1:-0}" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60))
  if   (( d > 0 )); then printf '%dd %dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  else                   printf '%dm' "$m"; fi
}

# --- Scan ------------------------------------------------------------------
# _tcp_scan APPLY   APPLY=1 -> Zustand fortschreiben und Wechsel sammeln.
# Ergebnisse in TCP_TOTAL / TCP_DOWN / TCP_NEW_DOWN / TCP_NEW_UP / TCP_CHANGES.
_tcp_scan() {
  local apply="${1:-0}" now sf tmp
  TCP_TOTAL=0; TCP_DOWN=0; TCP_NEW_DOWN=0; TCP_NEW_UP=0; TCP_CHANGES=()
  now="$(date +%s)"; sf="$(tcp_services_file)"
  tmp="$(mktemp)"

  local name host port old since state dur
  while IFS='|' read -r name host port; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    TCP_TOTAL=$((TCP_TOTAL+1))
    read -r old since < <(_tcp_state_get "$name")

    if _tcp_probe "$host" "$port"; then state=up; else state=down; TCP_DOWN=$((TCP_DOWN+1)); fi

    if [[ "$state" == "$old" ]]; then
      rlog "$(printf '   %-4s %-18s %s:%s   seit %s' \
        "$([[ $state == up ]] && echo ok || echo DOWN)" "$name" "$host" "$port" "$(_tcp_dur $((now-since)))")"
      printf '%s|%s|%s\n' "$name" "$state" "$since" >> "$tmp"
      continue
    fi

    # Zustandswechsel
    printf '%s|%s|%s\n' "$name" "$state" "$now" >> "$tmp"
    dur="$(_tcp_dur $((now-since)))"
    if [[ "$old" == unknown ]]; then
      if [[ "$state" == down ]]; then
        TCP_NEW_DOWN=$((TCP_NEW_DOWN+1))
        TCP_CHANGES+=("DOWN   $name ($host:$port) - neu aufgenommen und nicht erreichbar")
        rlog "$(printf '   %-4s %-18s %s:%s   NEU, nicht erreichbar' DOWN "$name" "$host" "$port")"
      else
        # Erstaufnahme im Normalzustand ist kein Vorfall -> keine Mail
        rlog "$(printf '   %-4s %-18s %s:%s   neu aufgenommen' ok "$name" "$host" "$port")"
      fi
    elif [[ "$state" == down ]]; then
      TCP_NEW_DOWN=$((TCP_NEW_DOWN+1))
      TCP_CHANGES+=("DOWN   $name ($host:$port) - war $dur erreichbar")
      rlog "$(printf '   %-4s %-18s %s:%s   NEU AUSGEFALLEN' DOWN "$name" "$host" "$port")"
    else
      TCP_NEW_UP=$((TCP_NEW_UP+1))
      TCP_CHANGES+=("OK     $name ($host:$port) - wieder erreichbar nach $dur Ausfall")
      rlog "$(printf '   %-4s %-18s %s:%s   WIEDER DA (Ausfall %s)' ok "$name" "$host" "$port" "$dur")"
    fi
  done < <(_tcp_lines)

  if [[ "$apply" == 1 ]]; then
    _tcp_state_write "$tmp" || err "Zustand konnte nicht gespeichert werden - naechster Lauf mailt erneut."
  fi
  rm -f "$tmp"
  return 0
}

# --- Verben ----------------------------------------------------------------

# tcp add [NAME] [HOST] [PORT]
tcp_add() {
  conf_load "$(conf_file tcp)"
  local name="${1:-}" host="${2:-}" port="${3:-}"
  [[ -n "$name" ]] || read -rp "Kurzname (z.B. nextcloud): " name
  name="$(trim "$name")"
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "Name darf nur Buchstaben, Ziffern, Punkt, Bindestrich und _ enthalten: '$name'"; return 1
  fi
  if _tcp_find "$name" >/dev/null; then
    err "Dienst '$name' existiert schon."
    warn "Aendern mit: ./setup.sh tcp edit $name"; return 1
  fi
  [[ -n "$host" ]] || read -rp "Host oder IP: " host
  host="$(trim "$host")"
  if [[ ! "$host" =~ ^[A-Za-z0-9._:-]+$ ]]; then err "Ungueltiger Host: '$host'"; return 1; fi
  if [[ -z "$port" ]]; then ask_port port "Port" "443" || return 1; fi
  is_port "$port" || { err "Ungueltiger Port: '$port'"; return 1; }

  { _tcp_lines; printf '%s|%s|%s\n' "$name" "$host" "$port"; } | _tcp_services_write || return 1
  log "Aufgenommen: $name -> $host:$port"

  printf '    pruefe ... '
  if _tcp_probe "$host" "$port"; then echo "erreichbar."
  else echo "NICHT erreichbar."
       warn "Der naechste Cron-Lauf meldet das per Mail (Erstaufnahme im Fehlerzustand)."; fi
  cron_has "$TCP_JOB" || warn "Noch keine Ueberwachung aktiv: ./setup.sh tcp install"
}

tcp_list() {
  local n; n="$(_tcp_count)"
  if [[ "${n:-0}" -eq 0 ]]; then
    echo "(keine Dienste eingetragen: $(tcp_services_file))"
    echo "Aufnehmen mit: ./setup.sh tcp add <name> <host> <port>"
    return 0
  fi
  local now; now="$(date +%s)"
  printf '%-18s %-28s %-6s %s\n' "NAME" "ZIEL" "STAND" "SEIT"
  hr
  local name host port state since
  while IFS='|' read -r name host port; do
    [[ -z "${name:-}" ]] && continue
    read -r state since < <(_tcp_state_get "$name")
    case "$state" in
      up)   state="ok" ;;
      down) state="DOWN" ;;
      *)    state="neu" ;;
    esac
    if [[ "${since:-0}" -gt 0 ]]; then since="$(_tcp_dur $((now-since)))"; else since="-"; fi
    printf '%-18s %-28s %-6s %s\n' "$name" "$host:$port" "$state" "$since"
  done < <(_tcp_lines)
  hr
  printf '%s Dienst(e). Stand aus dem letzten "tcp run".\n' "$n"
}

tcp_edit() {
  local name="${1:-}" line old_host old_port new_name host port
  if [[ -z "$name" ]]; then tcp_list; echo; read -rp "Zu aendernder Dienst: " name; fi
  name="$(trim "$name")"
  line="$(_tcp_find "$name")" || { err "Kein Dienst mit dem Namen '$name'."; return 1; }
  IFS='|' read -r _ old_host old_port <<< "$line"

  new_name="$name"; ask new_name "Name" "$name"
  new_name="$(trim "$new_name")"
  if [[ "$new_name" != "$name" ]]; then
    [[ "$new_name" =~ ^[A-Za-z0-9._-]+$ ]] || { err "Ungueltiger Name: '$new_name'"; return 1; }
    _tcp_find "$new_name" >/dev/null && { err "Dienst '$new_name' existiert schon."; return 1; }
  fi
  host="$old_host"; ask host "Host oder IP" "$old_host"
  host="$(trim "$host")"
  [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || { err "Ungueltiger Host: '$host'"; return 1; }
  port="$old_port"; ask_port port "Port" "$old_port" || return 1

  # Zeile ersetzen, Reihenfolge bleibt erhalten.
  _tcp_lines | awk -v old="$name" -v repl="$new_name|$host|$port" -F'|' \
    '{ if ($1==old) print repl; else print }' | _tcp_services_write || return 1
  log "Geaendert: $name -> $new_name ($host:$port)"
  [[ "$new_name" != "$name" ]] && warn "Zustand wird beim naechsten Lauf neu ermittelt (Name geaendert)."
  printf '    pruefe ... '
  conf_load "$(conf_file tcp)"
  if _tcp_probe "$host" "$port"; then echo "erreichbar."; else echo "NICHT erreichbar."; fi
}

tcp_remove() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then tcp_list; echo; read -rp "Zu entfernender Dienst: " name; fi
  name="$(trim "$name")"
  _tcp_find "$name" >/dev/null || { err "Kein Dienst mit dem Namen '$name'."; return 1; }
  confirm "Dienst '$name' aus der Ueberwachung nehmen?" Y || { echo "Abbruch."; return 0; }
  # '|| true': war es der letzte Dienst, gibt grep -v nichts aus und liefert 1 -
  # mit 'set -o pipefail' wuerde das als Fehler durchschlagen.
  _tcp_lines | { grep -v "^$name|" || true; } | _tcp_services_write || return 1
  log "Entfernt: $name"
  warn "Der Zustandseintrag verschwindet beim naechsten 'tcp run' automatisch."
}

tcp_check() {
  local n; n="$(_tcp_count)"
  [[ "${n:-0}" -gt 0 ]] || { echo "(keine Dienste eingetragen)"; return 0; }
  conf_load "$(conf_file tcp)"
  : "${TCP_TIMEOUT:=3}"; : "${TCP_RETRIES:=2}"
  report_init
  rlog "$APP_NAME TCP-Check   $(date '+%F %T')   auf $(hostname 2>/dev/null || echo host)"
  rlog ""
  _tcp_scan 0
  rlog ""
  rlog "Ergebnis: $TCP_DOWN von $TCP_TOTAL nicht erreichbar."
  warn "(nur Anzeige - Zustand und Mailversand bleiben unberuehrt)"
  return 0
}

tcp_install() {
  local cf logf; cf="$(conf_file tcp)"; conf_load "$cf"
  echo
  echo "Laufende TCP-Ueberwachung einrichten. Gemailt wird nur bei Zustandswechsel:"
  echo "einmal beim Ausfall, einmal bei der Rueckkehr - dazwischen Stille."
  echo
  ask TCP_TIMEOUT "Timeout je Verbindungsversuch in Sekunden" "${TCP_TIMEOUT:-3}"
  ask TCP_RETRIES "Versuche, bevor 'down' gilt"               "${TCP_RETRIES:-2}"
  ask TCP_SCHED   "Cron-Zeitplan"                             "${TCP_SCHED:-17 * * * *}"

  conf_save "$cf" TCP_TIMEOUT TCP_RETRIES TCP_SCHED || return 1
  logf="$(log_prepare "$TCP_JOB")"
  cron_install "$TCP_JOB" "$TCP_SCHED" "$SETUP_SH tcp run >> $logf 2>&1" root "tcp uninstall" || return 1

  if mailer_ready; then log "Mailer erkannt: Meldungen gehen raus."
  else warn "Kein Mailer - ohne SMTP nur Log. Einrichten: ./setup.sh smtp install"; fi
  [[ "$(_tcp_count)" -eq 0 ]] && warn "Noch keine Dienste: ./setup.sh tcp add <name> <host> <port>"
  log "Testlauf: ./setup.sh tcp check"
}

tcp_status() {
  echo "== Cron =="
  cron_show "$TCP_JOB"
  echo; echo "== Konfiguration =="
  conf_show "$(conf_file tcp)"
  echo; echo "== Dienste =="
  tcp_list | indent
  echo; echo "== Mail =="
  if mailer_ready; then printf '    Mailer bereit\n'; else printf '    kein Mailer (./setup.sh smtp install)\n'; fi
  echo; echo "== Letzter Lauf =="
  log_tail "$TCP_JOB" 20
}

tcp_uninstall() {
  confirm "Laufende TCP-Ueberwachung abschalten (Cron-Eintrag loeschen)?" Y || { echo "Abbruch."; return 0; }
  cron_remove "$TCP_JOB"
  warn "Die Dienstliste bleibt erhalten ($(tcp_services_file))."
  if confirm "Auch Config und Zustand loeschen?"; then
    conf_remove "$(conf_file tcp)"
    rm -f "$(tcp_state_file)" 2>/dev/null || $SUDO rm -f "$(tcp_state_file)"
    log "Config und Zustand entfernt."
  fi
}

# --- Cron-Runner -----------------------------------------------------------
tcp_run() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  conf_load "$(conf_file tcp)"
  : "${TCP_TIMEOUT:=3}"; : "${TCP_RETRIES:=2}"

  if [[ "$(_tcp_count)" -eq 0 ]]; then
    echo "$(date '+%F %T') keine Dienste eingetragen - nichts zu tun."
    [[ $_e -eq 1 ]] && set -e; return 0
  fi

  report_init
  local HOST subj rc=0
  HOST="$(hostname 2>/dev/null || echo host)"
  rlog "$APP_NAME TCP-Check   $(date '+%F %T')   auf $HOST"
  rlog ""
  _tcp_scan 1
  rlog ""
  rlog "Ergebnis: $TCP_DOWN von $TCP_TOTAL nicht erreichbar."

  # Mail nur, wenn sich mindestens ein Zustand geaendert hat. Der Report bekommt
  # die Wechsel voran gestellt - das ist der Teil, der Handlung erfordert.
  if [[ ${#TCP_CHANGES[@]} -gt 0 ]]; then
    local body c
    body="$APP_NAME TCP-Ueberwachung auf $HOST   $(date '+%F %T')"$'\n\n'"Zustandswechsel:"$'\n'
    for c in "${TCP_CHANGES[@]}"; do body+="  $c"$'\n'; done
    body+=$'\n'"Vollstaendiger Stand:"$'\n'"$(cat "$REPORT_FILE")"$'\n'
    printf '%s\n' "$body" > "$REPORT_FILE"
    rchanged

    if   [[ $TCP_NEW_DOWN -gt 0 && $TCP_NEW_UP -gt 0 ]]; then
      subj="$APP_NAME TCP: $TCP_NEW_DOWN ausgefallen / $TCP_NEW_UP wieder da: $HOST"
    elif [[ $TCP_NEW_DOWN -gt 0 ]]; then
      subj="$APP_NAME TCP AUSFALL ($TCP_NEW_DOWN): $HOST"
    else
      subj="$APP_NAME TCP wieder erreichbar ($TCP_NEW_UP): $HOST"
    fi
    report_send changes "$subj"
  else
    rlog "(keine Zustandsaenderung - keine Mail)"
  fi

  [[ "$TCP_DOWN" -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e
  return $rc
}
