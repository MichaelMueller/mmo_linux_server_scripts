#!/usr/bin/env bash
# modules/server.sh - Server-Haertung: SSH + ufw + fail2ban in EINEM Durchlauf.
#
# ACHTUNG: Fehler hier sperren dich aus. Deshalb:
#   - erst alle Fragen, dann eine Zusammenfassung, dann eine einzige Bestaetigung
#   - Reihenfolge ufw -> sshd -> fail2ban: der neue SSH-Port ist offen, BEVOR
#     sshd dorthin wechselt
#   - Port 22 bleibt zunaechst zusaetzlich offen (Sicherheitsnetz)
#   - SSH-Aenderungen nur als Drop-in, 'sshd -t' davor, Rollback bei Fehler
#   - Passwort-Login wird nur abgeschaltet, wenn ein authorized_keys existiert
#   - ssh.socket wird erkannt (siehe _ssh_socket_enabled)

register server install srv_install "Haertung einrichten (SSH + ufw + fail2ban)"
register server status  srv_status  "Status anzeigen (SSH / ufw / fail2ban)"
register server remove  srv_remove  "Haertung zuruecknehmen"

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-${APP_NAME}.conf"
SSH_SOCKET_DIR="/etc/systemd/system/ssh.socket.d"
SSH_SOCKET_DROPIN="$SSH_SOCKET_DIR/10-${APP_NAME}-port.conf"
F2B_JAIL="/etc/fail2ban/jail.d/${APP_NAME}-sshd.local"

# Auf Ubuntu >= 22.10 wird sshd per Socket-Aktivierung gestartet. Dann IGNORIERT
# sshd die Port-Direktive aus sshd_config komplett - der Port steht in ssh.socket.
# Ohne diese Erkennung wuerde die Firewall auf den neuen Port umgestellt, waehrend
# sshd weiter auf 22 lauscht: Aussperrung.
_ssh_socket_enabled() { unit_exists ssh.socket && unit_enabled ssh.socket; }

_ssh_unit() {
  local u
  for u in ssh sshd; do unit_exists "$u.service" && { printf '%s' "$u"; return 0; }; done
  printf 'ssh'
}

# Gibt es irgendwo einen hinterlegten Public Key? (Schutz vor Aussperrung)
_has_authorized_key() {
  local f
  for f in "$HOME/.ssh/authorized_keys" /root/.ssh/authorized_keys \
           "/home/${SUDO_USER:-$USER}/.ssh/authorized_keys"; do
    [[ -s "$f" ]] && return 0
    $SUDO test -s "$f" 2>/dev/null && return 0
  done
  return 1
}

srv_install() {
  local cf; cf="$(conf_file server)"; conf_load "$cf"

  echo; hr
  printf ' Server-Haertung: SSH -> ufw -> fail2ban\n'
  hr
  warn "Halte eine ZWEITE SSH-Sitzung offen, bis der neue Zugang bestaetigt ist."
  warn "Angewandt wird erst nach der Zusammenfassung - vorher passiert nichts."

  # ---------------------------------------------------------------- 1) SSH ---
  echo; echo " 1) SSH"
  ask_port SSH_PORT "    SSH-Port" "${SSH_PORT:-22}" || return 1
  ask_choice SSH_PERMIT_ROOT "    Root-Login" "${SSH_PERMIT_ROOT:-prohibit-password}" \
             yes no prohibit-password

  local addkey akf
  echo "    (Public Key jetzt hinterlegen, falls noch keiner da ist - leer = ueberspringen)"
  read -rp "    Public Key: " addkey || true
  if [[ -n "$addkey" ]]; then
    if [[ ! "$addkey" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-) ]]; then
      err "Das sieht nicht wie ein SSH-Public-Key aus - nicht hinterlegt."
    else
      akf="$HOME/.ssh/authorized_keys"
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      printf '%s\n' "$addkey" >> "$akf"; chmod 600 "$akf"
      log "Key ergaenzt: $akf"
    fi
  fi

  ask_choice SSH_PASSWORD_AUTH "    Passwort-Login erlauben" "${SSH_PASSWORD_AUTH:-yes}" yes no
  if [[ "$SSH_PASSWORD_AUTH" == "no" ]] && ! _has_authorized_key; then
    err "Kein authorized_keys gefunden (weder fuer root noch fuer $USER)."
    warn "Passwort-Login bleibt AN - sonst kommst du nicht mehr rein."
    SSH_PASSWORD_AUTH="yes"
  fi

  # ---------------------------------------------------------------- 2) ufw ---
  echo; echo " 2) Firewall (ufw)"
  echo "    Der SSH-Port $SSH_PORT wird automatisch freigegeben."
  ask UFW_PORTS "    Weitere Ports (Komma, z.B. 80/tcp,443/tcp,443/udp)" \
      "${UFW_PORTS:-80/tcp,443/tcp,443/udp}"

  # ----------------------------------------------------------- 3) fail2ban ---
  echo; echo " 3) fail2ban (SSH-Brute-Force-Schutz)"
  ask F2B_MAXRETRY "    maxretry (Fehlversuche bis Bann)" "${F2B_MAXRETRY:-5}"
  ask F2B_FINDTIME "    findtime (Zeitfenster)"           "${F2B_FINDTIME:-10m}"
  ask F2B_BANTIME  "    bantime (Bann-Dauer)"             "${F2B_BANTIME:-1h}"

  # ------------------------------------------------- Zusammenfassung + OK ---
  echo; hr
  printf ' SSH-Port           %s%s\n' "$SSH_PORT" \
    "$([[ "$SSH_PORT" != 22 ]] && printf ' (22 bleibt vorerst zusaetzlich offen)' || true)"
  printf ' Root-Login         %s\n' "$SSH_PERMIT_ROOT"
  printf ' Passwort-Login     %s\n' "$SSH_PASSWORD_AUTH"
  printf ' ufw erlaubt        %s/tcp%s\n' "$SSH_PORT" "${UFW_PORTS:+, $UFW_PORTS}"
  printf ' ufw Default        deny incoming / allow outgoing\n'
  printf ' fail2ban [sshd]    maxretry=%s findtime=%s bantime=%s\n' \
    "$F2B_MAXRETRY" "$F2B_FINDTIME" "$F2B_BANTIME"
  if _ssh_socket_enabled; then
    printf ' Hinweis            ssh.socket ist aktiv -> Port wird dort gesetzt\n'
  fi
  hr
  confirm "So anwenden?" Y || { echo "Abbruch - nichts geaendert."; return 0; }

  # --- ufw ZUERST: neuer Port offen, bevor sshd dorthin wechselt -------------
  echo; log "ufw ..."
  ensure_tool ufw ufw
  $SUDO ufw allow "$SSH_PORT/tcp" >/dev/null
  if [[ "$SSH_PORT" != "22" ]]; then
    $SUDO ufw allow 22/tcp >/dev/null
    warn "Port 22 bleibt offen, bis du den neuen Zugang bestaetigt hast."
  fi
  local p; local -a ports=()
  IFS=',' read -ra ports <<< "${UFW_PORTS:-}"
  for p in "${ports[@]}"; do
    p="$(trim "$p")"; [[ -n "$p" ]] || continue
    $SUDO ufw allow "$p" >/dev/null || warn "ufw: '$p' wurde nicht akzeptiert."
  done
  $SUDO ufw default deny incoming >/dev/null
  $SUDO ufw default allow outgoing >/dev/null
  $SUDO ufw --force enable >/dev/null
  log "ufw aktiv."

  # --- sshd -----------------------------------------------------------------
  echo; log "sshd ..."
  local tmp; tmp="$(mktemp)"
  {
    printf '# %s - erzeugt von setup.sh (server install).\n' "$APP_NAME"
    printf '# Die Hauptdatei /etc/ssh/sshd_config bleibt unberuehrt.\n'
    printf 'Port %s\n' "$SSH_PORT"
    printf 'PermitRootLogin %s\n' "$SSH_PERMIT_ROOT"
    printf 'PasswordAuthentication %s\n' "$SSH_PASSWORD_AUTH"
    printf 'KbdInteractiveAuthentication %s\n' "$SSH_PASSWORD_AUTH"
    printf 'PubkeyAuthentication yes\n'
    printf 'X11Forwarding no\n'
    printf 'MaxAuthTries 4\n'
  } > "$tmp"
  $SUDO mkdir -p "$(dirname "$SSHD_DROPIN")"
  $SUDO install -m 644 -o root -g root "$tmp" "$SSHD_DROPIN"; rm -f "$tmp"

  if ! $SUDO sshd -t; then
    err "'sshd -t' meldet einen Fehler -> Drop-in wird entfernt, sshd bleibt unveraendert."
    $SUDO rm -f "$SSHD_DROPIN"
    return 1
  fi

  if _ssh_socket_enabled; then
    # Socket-Aktivierung: der Port MUSS an ssh.socket gesetzt werden, die
    # Port-Direktive im Drop-in ist hier wirkungslos.
    warn "ssh.socket ist aktiv - Port wird dort gesetzt (sshd_config-Port waere wirkungslos)."
    tmp="$(mktemp)"
    {
      printf '# %s - Port fuer socket-aktiviertes sshd.\n' "$APP_NAME"
      printf '[Socket]\n'
      printf 'ListenStream=\n'
      printf 'ListenStream=%s\n' "$SSH_PORT"
    } > "$tmp"
    $SUDO mkdir -p "$SSH_SOCKET_DIR"
    $SUDO install -m 644 -o root -g root "$tmp" "$SSH_SOCKET_DROPIN"; rm -f "$tmp"
    $SUDO systemctl daemon-reload
    if $SUDO systemctl restart ssh.socket; then
      log "ssh.socket lauscht auf Port $SSH_PORT (bestehende Sitzungen bleiben)."
    else
      err "ssh.socket konnte nicht neu gestartet werden - PRUEFEN, bevor du die Sitzung schliesst!"
    fi
  else
    local unit; unit="$(_ssh_unit)"
    $SUDO systemctl reload "$unit" 2>/dev/null \
      || $SUDO systemctl restart "$unit" 2>/dev/null \
      || $SUDO service ssh reload 2>/dev/null \
      || warn "sshd-Reload fehlgeschlagen - pruefe: systemctl status $unit"
    log "sshd neu geladen."
  fi

  # --- fail2ban -------------------------------------------------------------
  echo; log "fail2ban ..."
  ensure_tool fail2ban-client fail2ban
  tmp="$(mktemp)"
  {
    printf '# %s - erzeugt von setup.sh (server install).\n' "$APP_NAME"
    printf '[sshd]\n'
    printf 'enabled  = true\n'
    printf 'port     = %s\n' "$SSH_PORT"
    printf 'backend  = systemd\n'
    printf 'maxretry = %s\n' "$F2B_MAXRETRY"
    printf 'findtime = %s\n' "$F2B_FINDTIME"
    printf 'bantime  = %s\n' "$F2B_BANTIME"
  } > "$tmp"
  $SUDO mkdir -p "$(dirname "$F2B_JAIL")"
  $SUDO install -m 644 -o root -g root "$tmp" "$F2B_JAIL"; rm -f "$tmp"
  $SUDO systemctl enable fail2ban >/dev/null 2>&1 || true
  if $SUDO systemctl restart fail2ban 2>/dev/null; then
    log "fail2ban [sshd] aktiv (Port $SSH_PORT)."
  else
    err "fail2ban startet nicht. Bei 'backend = systemd' fehlt oft python3-systemd:"
    warn "sudo apt-get install -y python3-systemd && sudo systemctl restart fail2ban"
  fi

  conf_save "$cf" SSH_PORT SSH_PERMIT_ROOT SSH_PASSWORD_AUTH UFW_PORTS \
                  F2B_MAXRETRY F2B_FINDTIME F2B_BANTIME

  echo; hr
  log "Haertung eingerichtet."
  warn "JETZT in einer NEUEN Sitzung testen:  ssh -p $SSH_PORT <user>@<host>"
  if [[ "$SSH_PORT" != "22" ]]; then
    warn "Erst danach Port 22 schliessen:        sudo ufw delete allow 22/tcp"
  fi
  hr
}

srv_status() {
  echo "== Konfiguration =="
  conf_show "$(conf_file server)"

  echo; echo "== SSH =="
  if $SUDO test -f "$SSHD_DROPIN"; then
    printf '    Drop-in %s:\n' "$SSHD_DROPIN"
    $SUDO grep -vE '^\s*(#|$)' "$SSHD_DROPIN" | indent
  else
    printf '    (kein Drop-in: %s)\n' "$SSHD_DROPIN"
  fi
  printf '    effektiv laut sshd -T:\n'
  if $SUDO sshd -T >/dev/null 2>&1; then
    $SUDO sshd -T 2>/dev/null \
      | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries) ' \
      | indent
  else
    printf '    (sshd -T nicht verfuegbar)\n'
  fi
  printf '    Dienst %s: %s\n' "$(_ssh_unit).service" "$(unit_state "$(_ssh_unit).service")"
  if _ssh_socket_enabled; then
    printf '    ssh.socket ist aktiv und BESTIMMT den Port:\n'
    $SUDO systemctl show -p Listen --value ssh.socket | indent
  fi

  echo; echo "== ufw =="
  if have ufw; then $SUDO ufw status verbose | indent; else printf '    (ufw nicht installiert)\n'; fi

  echo; echo "== fail2ban =="
  if have fail2ban-client; then
    printf '    Dienst: %s\n' "$(unit_state fail2ban.service)"
    $SUDO fail2ban-client status sshd 2>/dev/null | indent \
      || printf '    (Jail "sshd" nicht aktiv)\n'
  else
    printf '    (fail2ban nicht installiert)\n'
  fi
}

srv_remove() {
  echo "Zuruecknehmen der Haertung:"
  echo "  - SSH-Drop-in entfernen (zurueck zum Distributions-Default, Port 22)"
  echo "  - fail2ban-Jail entfernen (Rueckfrage)"
  echo "  - ufw deaktivieren (Rueckfrage)"
  confirm "Fortfahren?" || { echo "Abbruch."; return 0; }

  # Port 22 oeffnen, BEVOR sshd dorthin zurueckfaellt.
  if have ufw && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
    $SUDO ufw allow 22/tcp >/dev/null || true
    log "Port 22 in ufw freigegeben."
  fi

  if $SUDO test -f "$SSHD_DROPIN"; then $SUDO rm -f "$SSHD_DROPIN"; log "entfernt: $SSHD_DROPIN"; fi
  if $SUDO test -f "$SSH_SOCKET_DROPIN"; then
    $SUDO rm -f "$SSH_SOCKET_DROPIN"; $SUDO systemctl daemon-reload
    $SUDO systemctl restart ssh.socket 2>/dev/null || true
    log "entfernt: $SSH_SOCKET_DROPIN"
  fi
  if $SUDO sshd -t; then
    local unit; unit="$(_ssh_unit)"
    $SUDO systemctl reload "$unit" 2>/dev/null || $SUDO systemctl restart "$unit" 2>/dev/null || true
    log "sshd laeuft wieder mit der Distributions-Konfiguration."
  else
    err "'sshd -t' meldet einen Fehler - sshd NICHT neu geladen. /etc/ssh pruefen!"
  fi

  if $SUDO test -f "$F2B_JAIL" && confirm "fail2ban-Jail entfernen?" Y; then
    $SUDO rm -f "$F2B_JAIL"
    $SUDO systemctl restart fail2ban 2>/dev/null || true
    log "entfernt: $F2B_JAIL"
  fi

  if have ufw && confirm "ufw deaktivieren (Firewall ist danach AUS)?"; then
    $SUDO ufw disable >/dev/null
    warn "ufw ist deaktiviert."
  fi

  conf_remove "$(conf_file server)"
  echo; warn "Zugang jetzt ueber Port 22 pruefen, bevor du die Sitzung schliesst."
}
