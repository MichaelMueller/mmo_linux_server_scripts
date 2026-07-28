#!/usr/bin/env bash
# modules/server-hardening.sh - SSH-Haertung, ufw-Firewall, fail2ban.
# ACHTUNG: kann bei Fehlern aussperren -> Guardrails + Reihenfolge + Bestaetigungen.

register server harden   hd_harden   "Server haerten (SSH + ufw + fail2ban)"
register server ssh      hd_ssh      "SSH haerten (Port / Key-Auth / Root)"
register server firewall hd_firewall "ufw-Firewall einrichten"
register server fail2ban hd_fail2ban "fail2ban (SSH-Brute-Force-Schutz)"

_hardening_save() {
  umask 077; ensure_dir "$DEPLOY_DIR"
  cat > "$DEPLOY_DIR/.hardening.env" <<EOF
SSH_PORT='${SSH_PORT:-22}'
SSH_PERMIT_ROOT='${SSH_PERMIT_ROOT:-prohibit-password}'
SSH_PASSWORD_AUTH='${SSH_PASSWORD_AUTH:-yes}'
EOF
  chmod 600 "$DEPLOY_DIR/.hardening.env"
}

# Existiert irgendwo ein nicht-leeres authorized_keys (Aussperr-Schutz)?
_has_authorized_key() {
  local f
  for f in "$HOME/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
    [[ -s "$f" ]] && return 0
    $SUDO test -s "$f" 2>/dev/null && return 0
  done
  return 1
}

hd_ssh() {
  local envf="$DEPLOY_DIR/.hardening.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  echo; echo "SSH haerten -> Drop-in /etc/ssh/sshd_config.d/99-hardening.conf (Hauptdatei bleibt unberuehrt)."
  ask SSH_PORT        "SSH-Port"                              "${SSH_PORT:-22}"
  ask SSH_PERMIT_ROOT "Root-Login (yes/no/prohibit-password)" "${SSH_PERMIT_ROOT:-prohibit-password}"

  local addkey akf
  read -rp "Public-Key hinzufuegen (leer = nein): " addkey || true
  if [[ -n "$addkey" ]]; then
    akf="$HOME/.ssh/authorized_keys"; mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    printf '%s\n' "$addkey" >> "$akf"; chmod 600 "$akf"; log "Key zu $akf hinzugefuegt."
  fi

  ask SSH_PASSWORD_AUTH "Passwort-Login erlauben? (yes/no)" "${SSH_PASSWORD_AUTH:-yes}"
  if [[ "$SSH_PASSWORD_AUTH" == "no" ]] && ! _has_authorized_key; then
    err "Kein authorized_keys fuer root/aktuellen User gefunden."
    warn "Passwort-Login wird NICHT deaktiviert (sonst Aussperr-Gefahr). Erst einen Key hinterlegen."
    SSH_PASSWORD_AUTH="yes"
  fi

  local dropin="/etc/ssh/sshd_config.d/99-hardening.conf" tmp; tmp="$(mktemp)"
  {
    echo "# Von setup.sh (server ssh) erzeugt."
    echo "Port $SSH_PORT"
    echo "PermitRootLogin $SSH_PERMIT_ROOT"
    echo "PasswordAuthentication $SSH_PASSWORD_AUTH"
    echo "KbdInteractiveAuthentication $SSH_PASSWORD_AUTH"
    echo "PubkeyAuthentication yes"
    echo "X11Forwarding no"
  } > "$tmp"
  echo; echo "--- $dropin ---"; cat "$tmp"; echo "---"
  confirm "So schreiben, validieren und sshd neu laden?" || { echo "Abbruch - nichts geaendert."; rm -f "$tmp"; return 0; }
  $SUDO install -m 644 "$tmp" "$dropin"; rm -f "$tmp"

  if ! $SUDO sshd -t 2>/dev/null; then
    err "sshd -t meldet einen Fehler - Drop-in wird entfernt, nichts wird aktiviert."
    $SUDO rm -f "$dropin"; return 1
  fi

  if [[ "$SSH_PORT" != "22" ]] && command -v ufw >/dev/null 2>&1; then
    $SUDO ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true
    warn "Neuen SSH-Port $SSH_PORT in ufw geoeffnet."
  fi
  _hardening_save
  $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null \
    || $SUDO service ssh reload 2>/dev/null || true
  log "SSH-Drop-in aktiv."
  warn "WICHTIG: JETZT in einer NEUEN Sitzung 'ssh -p $SSH_PORT <user>@host' testen, BEVOR du diese schliesst!"
}

hd_firewall() {
  ensure_tool ufw ufw
  local envf="$DEPLOY_DIR/.hardening.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  local port="${SSH_PORT:-22}"
  echo; echo "ufw: default deny incoming/allow outgoing; SSH ($port) + 80/443 (tcp) + 443/udp (HTTP3) erlauben."
  warn "ACHTUNG: Ohne erlaubten SSH-Port sperrt 'ufw enable' dich aus!"
  confirm "Fortfahren (SSH-Port $port wird ZUERST erlaubt)?" || { echo "Abbruch."; return 0; }
  $SUDO ufw allow "$port"/tcp
  $SUDO ufw default deny incoming
  $SUDO ufw default allow outgoing
  $SUDO ufw allow 80/tcp
  $SUDO ufw allow 443/tcp
  $SUDO ufw allow 443/udp
  $SUDO ufw --force enable
  $SUDO ufw status verbose || true
  log "ufw aktiv."
}

hd_fail2ban() {
  ensure_tool fail2ban-client fail2ban
  local envf="$DEPLOY_DIR/.hardening.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  local port="${SSH_PORT:-ssh}" jail="/etc/fail2ban/jail.d/sshd.local" tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
[sshd]
enabled  = true
port     = $port
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  echo "--- $jail ---"; cat "$tmp"; echo "---"
  confirm "So schreiben und fail2ban neu starten?" || { echo "Abbruch."; rm -f "$tmp"; return 0; }
  $SUDO install -m 644 "$tmp" "$jail"; rm -f "$tmp"
  $SUDO systemctl enable fail2ban >/dev/null 2>&1 || true
  $SUDO systemctl restart fail2ban 2>/dev/null || $SUDO service fail2ban restart 2>/dev/null || true
  $SUDO fail2ban-client status sshd 2>/dev/null || true
  log "fail2ban sshd-Jail aktiv (Port $port)."
}

hd_harden() {
  echo "Server-Haertung in Reihenfolge: SSH -> ufw -> fail2ban."
  warn "Halte eine ZWEITE SSH-Sitzung offen, bis der Zugang bestaetigt ist!"
  hd_ssh
  confirm "Weiter mit ufw-Firewall?" Y && hd_firewall
  confirm "Weiter mit fail2ban?" Y && hd_fail2ban
  log "Haertung abgeschlossen. Zugang jetzt in einer neuen Sitzung testen!"
}
