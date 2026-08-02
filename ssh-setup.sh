#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ssh-setup.sh - SSH-Härtung über ein Drop-in, mit Schutz gegen Aussperren
# Modi:  (ohne Argument) = interaktives Menü
#        --status        = wirksame Einstellungen auf stdout
#        --uninstall     = Deinstallation
set -euo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

SSHD_CONF=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/99-ssh-setup.conf"
SOCKET_DIR=/etc/systemd/system/ssh.socket.d
SOCKET_DROPIN="$SOCKET_DIR/10-ssh-setup-port.conf"

MARK_BEGIN='# >>> ssh-setup >>>'
MARK_END='# <<< ssh-setup <<<'

pause() { read -rp "Weiter mit Enter..." _; }

# confirm "Frage" [J]   -> Default J statt N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

# make_backup <name> <pfad>...   -> /root/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Umgebung erkennen
# ---------------------------------------------------------------------------
SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)

ssh_unit() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
        echo ssh
    else
        echo sshd
    fi
}

# Ab Ubuntu 22.10 startet sshd per Socket-Aktivierung. Dann ignoriert es die
# Port-Direktive aus sshd_config komplett - der Port muss an ssh.socket gesetzt
# werden. Ohne diese Unterscheidung stellt man die Firewall auf den neuen Port
# um, während sshd weiter auf 22 lauscht: Aussperrung.
socket_activated() {
    systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null
}

sshd_test() { "$SSHD_BIN" -t 2>&1; }

# Ein fehlgeschlagener Neustart darf das Skript nicht kommentarlos beenden -
# der Anwender muss sehen, woran es lag, solange seine Sitzung noch steht.
restart_sshd() {
    local unit; unit=$(ssh_unit)
    if systemctl restart "$unit"; then
        return 0
    fi
    echo "!!! Neustart von ${unit} fehlgeschlagen:"
    systemctl status "$unit" --no-pager -l 2>&1 | head -20 || true
    echo "!!! Die laufende Sitzung NICHT schließen, bevor das behoben ist."
    return 1
}

# Wirksame Einstellung aus 'sshd -T' - die einzige verlässliche Quelle, weil sie
# Drop-ins, Includes und Defaults schon zusammengerechnet hat.
effective() {
    "$SSHD_BIN" -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'
}

is_setup() { [[ -f "$DROPIN" ]]; }

# Bei sshd gewinnt die ZUERST gelesene Direktive. Steht in sshd_config also
# schon 'PasswordAuthentication yes' oberhalb der Include-Zeile, läuft das
# Drop-in ins Leere - und das merkt man sonst erst, wenn es zu spät ist.
effective_matches() {
    local got; got=$(effective "$1")
    [[ "${got,,}" == "${2,,}" ]]
}

# Widersprechende Zeile auskommentieren statt löschen: nachvollziehbar und
# durch die Deinstallation wieder umkehrbar.
neutralize() {
    sed -i -E "s|^([[:space:]]*$1[[:space:]]+.*)$|# von ssh-setup deaktiviert: \1|I" "$SSHD_CONF"
}

listening_port() {
    if command -v ss &>/dev/null; then
        ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' '
    fi
}

# Nutzer mit hinterlegtem Schlüssel - ohne einen davon darf die
# Passwort-Anmeldung nicht abgeschaltet werden.
users_with_keys() {
    local d u
    for d in /root /home/*; do
        [[ -d "$d" ]] || continue
        [[ -s "$d/.ssh/authorized_keys" ]] || continue
        [[ "$d" == /root ]] && u=root || u=$(basename "$d")
        echo "$u"
    done
}

# Ältere Distributionen haben die Include-Zeile nicht. Ohne sie wäre das
# Drop-in wirkungslos - und das fällt erst auf, wenn man ausgesperrt ist.
ensure_include() {
    grep -qE "^[[:space:]]*Include[[:space:]]+${DROPIN_DIR}/\*\.conf" "$SSHD_CONF" && return 0

    echo ">>> $SSHD_CONF kennt noch kein Include für $DROPIN_DIR - wird ergänzt."
    cp "$SSHD_CONF" "$SSHD_CONF.ssh-setup.bak"
    # Muss ganz nach oben: bei sshd gewinnt die zuerst gelesene Direktive.
    {
        echo "$MARK_BEGIN"
        echo "Include ${DROPIN_DIR}/*.conf"
        echo "$MARK_END"
        cat "$SSHD_CONF.ssh-setup.bak"
    } > "$SSHD_CONF"
}

# ---------------------------------------------------------------------------
# Öffentliche Schlüssel
# ---------------------------------------------------------------------------
add_key() {
    local u
    read -rp "Für welchen Benutzer? [root]: " u; u=${u:-root}
    if ! id "$u" &>/dev/null; then
        echo "Benutzer '$u' gibt es nicht."; pause; return
    fi

    local home
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || { echo "Kein Home-Verzeichnis für '$u'."; pause; return; }

    echo "Öffentlichen Schlüssel einfügen (eine Zeile, beginnt mit ssh-ed25519 / ssh-rsa / ecdsa-):"
    local key; read -r key
    if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        echo "Das sieht nicht nach einem öffentlichen Schlüssel aus. Abgebrochen."
        pause; return
    fi

    mkdir -p "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if grep -qxF "$key" "$home/.ssh/authorized_keys"; then
        echo "Schlüssel ist bereits hinterlegt."
    else
        echo "$key" >> "$home/.ssh/authorized_keys"
        echo "Hinterlegt in $home/.ssh/authorized_keys"
    fi
    chmod 700 "$home/.ssh"
    chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$u": "$home/.ssh"
    pause
}

# ---------------------------------------------------------------------------
# Härtung
# ---------------------------------------------------------------------------
configure() {
    local cur_port cur_root cur_pass cur_tries cur_grace
    cur_port=$(effective port);                 cur_port=${cur_port:-22}
    cur_root=$(effective permitrootlogin);      cur_root=${cur_root:-prohibit-password}
    cur_pass=$(effective passwordauthentication); cur_pass=${cur_pass:-yes}
    cur_tries=$(effective maxauthtries);        cur_tries=${cur_tries:-6}
    cur_grace=$(effective logingracetime);      cur_grace=${cur_grace:-120}

    local -a keyusers=()
    mapfile -t keyusers < <(users_with_keys)

    echo ">>> SSH-Härtung"
    echo
    echo "Es wird erst alles gefragt, dann eine Zusammenfassung gezeigt und dann"
    echo "einmal bestätigt. Vorher wird nichts angefasst."
    echo
    if (( ${#keyusers[@]} > 0 )); then
        echo "Schlüssel hinterlegt für: ${keyusers[*]}"
    else
        echo "!!! Für keinen Benutzer ist ein authorized_keys hinterlegt."
    fi
    socket_activated && echo "Hinweis: sshd läuft über Socket-Aktivierung (ssh.socket)." || true
    echo

    # --- Port
    local PORT
    read -rp "SSH-Port [${cur_port}]: " PORT; PORT=${PORT:-$cur_port}
    while [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); do
        read -rp "  -> Zahl zwischen 1 und 65535: " PORT
    done

    # --- Root-Login
    echo
    echo "Root-Anmeldung:"
    echo "  1) nur mit Schlüssel (prohibit-password)"
    echo "  2) ganz verbieten (no)"
    echo "  3) auch mit Passwort erlauben (yes)"
    local R ROOTLOGIN
    read -rp "Auswahl [1]: " R
    case "${R:-1}" in
        2) ROOTLOGIN="no" ;;
        3) ROOTLOGIN="yes" ;;
        *) ROOTLOGIN="prohibit-password" ;;
    esac

    # --- Passwort-Anmeldung
    echo
    local PASSAUTH="yes"
    if (( ${#keyusers[@]} == 0 )); then
        echo "Passwort-Anmeldung bleibt an - ohne hinterlegten Schlüssel wäre das"
        echo "Abschalten eine sichere Aussperrung. Erst Menüpunkt 3 benutzen."
    else
        if confirm "Passwort-Anmeldung abschalten (nur noch Schlüssel)?" J; then
            PASSAUTH="no"
        fi
    fi

    if [[ "$ROOTLOGIN" == "no" && "$PASSAUTH" == "no" ]]; then
        local -a nonroot=()
        local u
        for u in "${keyusers[@]}"; do [[ "$u" != root ]] && nonroot+=("$u"); done
        if (( ${#nonroot[@]} == 0 )); then
            echo
            echo "!!! Root-Login verboten und Passwort aus, aber nur root hat einen"
            echo "!!! Schlüssel - damit käme niemand mehr rein. Root-Login wird auf"
            echo "!!! 'prohibit-password' gesetzt."
            ROOTLOGIN="prohibit-password"
        fi
    fi

    # --- Kleinkram
    echo
    local TRIES GRACE
    read -rp "MaxAuthTries [${cur_tries}]: " TRIES; TRIES=${TRIES:-$cur_tries}
    read -rp "LoginGraceTime in Sekunden [${cur_grace}]: " GRACE; GRACE=${GRACE:-$cur_grace}

    local X11="no" KEEPALIVE="yes"
    confirm "X11-Weiterleitung erlauben?" N && X11="yes" || true
    confirm "Tote Sitzungen nach ~10 min trennen (ClientAlive)?" J || KEEPALIVE="no"

    # --- Zusammenfassung
    echo
    echo "==================== Zusammenfassung ===================="
    printf '  %-24s %s\n' "Port"                 "$PORT$( [[ "$PORT" != "$cur_port" ]] && echo "   (bisher $cur_port)" )"
    printf '  %-24s %s\n' "PermitRootLogin"      "$ROOTLOGIN"
    printf '  %-24s %s\n' "PasswordAuthentication" "$PASSAUTH"
    printf '  %-24s %s\n' "PubkeyAuthentication" "yes"
    printf '  %-24s %s\n' "MaxAuthTries"         "$TRIES"
    printf '  %-24s %s\n' "LoginGraceTime"       "$GRACE"
    printf '  %-24s %s\n' "X11Forwarding"        "$X11"
    printf '  %-24s %s\n' "ClientAlive"          "$KEEPALIVE"
    echo "  Datei:                 $DROPIN"
    socket_activated && echo "  zusätzlich:            $SOCKET_DROPIN" || true
    echo "========================================================="
    echo
    echo "Reihenfolge: erst wird der neue Port in ufw geöffnet, dann wechselt"
    echo "sshd dorthin. Port 22 bleibt zunächst zusätzlich offen."
    echo
    echo "!!! Jetzt eine zweite SSH-Sitzung offen halten und erst schließen,"
    echo "!!! wenn die Anmeldung über den neuen Port funktioniert hat."
    echo

    confirm "So anwenden?" || { echo "Abgebrochen, nichts geändert."; pause; return; }

    # --- Anwenden
    ensure_include
    mkdir -p "$DROPIN_DIR"

    # ufw zuerst: der neue Port muss offen sein, BEVOR sshd dorthin wechselt.
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ">>> ufw: Port ${PORT}/tcp öffnen (22 bleibt vorerst offen)"
        ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow 22/tcp        >/dev/null 2>&1 || true
    fi

    local had_dropin=0
    if [[ -f "$DROPIN" ]]; then had_dropin=1; cp "$DROPIN" "$DROPIN.prev"; fi

    {
        echo "# erzeugt von ssh-setup.sh am $(date '+%F %T')"
        echo "Port ${PORT}"
        echo "PermitRootLogin ${ROOTLOGIN}"
        echo "PasswordAuthentication ${PASSAUTH}"
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo "MaxAuthTries ${TRIES}"
        echo "LoginGraceTime ${GRACE}"
        echo "X11Forwarding ${X11}"
        if [[ "$KEEPALIVE" == "yes" ]]; then
            echo "ClientAliveInterval 300"
            echo "ClientAliveCountMax 2"
        fi
    } > "$DROPIN"
    chmod 644 "$DROPIN"

    if ! sshd_test >/dev/null; then
        echo "!!! sshd lehnt die Konfiguration ab:"
        sshd_test || true
        if (( had_dropin == 1 )); then mv "$DROPIN.prev" "$DROPIN"; else rm -f "$DROPIN"; fi
        echo "Zurückgerollt, es wurde nichts übernommen."
        pause; return
    fi
    rm -f "$DROPIN.prev"

    # Kommt das Drop-in überhaupt an?
    local -a mismatch=()
    effective_matches port "$PORT"                    || mismatch+=(Port)
    effective_matches permitrootlogin "$ROOTLOGIN"    || mismatch+=(PermitRootLogin)
    effective_matches passwordauthentication "$PASSAUTH" || mismatch+=(PasswordAuthentication)

    if (( ${#mismatch[@]} > 0 )); then
        echo
        echo "!!! Diese Einstellungen kommen nicht an: ${mismatch[*]}"
        echo "!!! In $SSHD_CONF steht die Direktive oberhalb der Include-Zeile,"
        echo "!!! und bei sshd gewinnt die zuerst gelesene."
        echo
        if confirm "Die widersprechenden Zeilen dort auskommentieren?" J; then
            cp "$SSHD_CONF" "$SSHD_CONF.ssh-setup.bak"
            local k
            for k in "${mismatch[@]}"; do neutralize "$k"; done
            if ! sshd_test >/dev/null; then
                echo "!!! sshd lehnt das Ergebnis ab - zurückgerollt."
                sshd_test || true
                mv "$SSHD_CONF.ssh-setup.bak" "$SSHD_CONF"
            else
                echo "Erledigt."
            fi
        else
            echo "Die Härtung bleibt damit unvollständig."
        fi
    fi

    if socket_activated; then
        mkdir -p "$SOCKET_DIR"
        {
            echo "# erzeugt von ssh-setup.sh"
            echo "[Socket]"
            echo "ListenStream="
            echo "ListenStream=${PORT}"
        } > "$SOCKET_DROPIN"
        systemctl daemon-reload
        systemctl restart ssh.socket || true
    fi

    restart_sshd || true

    echo
    echo ">>> Übernommen. Offene Ports laut ss: $(listening_port)"
    echo
    echo "Jetzt in einem ZWEITEN Terminal testen:"
    echo "    ssh -p ${PORT} <benutzer>@<dieser-server>"
    echo
    echo "Erst wenn das klappt, Port 22 schließen - Menüpunkt 4 erledigt das."
    pause
}

close_22() {
    echo "Schließt Port 22 in ufw. Das ist erst richtig, wenn die Anmeldung über"
    echo "den neuen Port nachweislich funktioniert."
    echo
    local p; p=$(effective port); p=${p:-22}
    if [[ "$p" == "22" ]]; then
        echo "sshd lauscht selbst auf 22 - Schließen würde dich aussperren. Abbruch."
        pause; return
    fi
    echo "sshd lauscht auf Port ${p}."
    if ! command -v ufw &>/dev/null || ! ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw ist nicht aktiv, es gibt nichts zu schließen."
        pause; return
    fi
    confirm "Port 22/tcp jetzt schließen?" || { echo "Abgebrochen."; pause; return; }
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    echo "Geschlossen."
    pause
}

show_status() {
    echo "--- Wirksame Einstellungen (sshd -T) ---"
    local k
    for k in port permitrootlogin passwordauthentication pubkeyauthentication \
             kbdinteractiveauthentication maxauthtries logingracetime x11forwarding; do
        printf '  %-30s %s\n' "$k" "$(effective "$k")"
    done
    echo
    echo "--- Drop-in ---"
    if [[ -f "$DROPIN" ]]; then
        sed 's/^/  /' "$DROPIN"
    else
        echo "  (keins - die Werte oben sind Distributions-Default)"
    fi
    echo
    echo "--- Socket-Aktivierung ---"
    if socket_activated; then
        echo "  ja (ssh.socket)"
        [[ -f "$SOCKET_DROPIN" ]] && sed 's/^/  /' "$SOCKET_DROPIN" || echo "  (kein Port-Drop-in)"
    else
        echo "  nein"
    fi
    echo
    echo "--- Schlüssel hinterlegt für ---"
    local -a ku=(); mapfile -t ku < <(users_with_keys)
    if (( ${#ku[@]} == 0 )); then echo "  (niemanden)"; else printf '  %s\n' "${ku[@]}"; fi
    echo
    echo "--- Lauschende Ports ---"
    echo "  $(listening_port)"
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation SSH-Härtung"
    echo

    local p; p=$(effective port); p=${p:-22}

    echo "Folgendes wird entfernt:"
    [[ -f "$DROPIN" ]]        && echo "  - $DROPIN"                                  || true
    [[ -f "$SOCKET_DROPIN" ]] && echo "  - $SOCKET_DROPIN (Port an ssh.socket)"      || true
    grep -qF "$MARK_BEGIN" "$SSHD_CONF" 2>/dev/null \
        && echo "  - die ergänzte Include-Zeile in $SSHD_CONF"                       || true
    grep -q '^# von ssh-setup deaktiviert: ' "$SSHD_CONF" 2>/dev/null \
        && echo "  - auskommentierte Zeilen in $SSHD_CONF werden reaktiviert"        || true
    echo
    echo "Danach gilt wieder der Distributions-Default: Port 22, Passwort-Anmeldung"
    echo "in der Regel erlaubt. Die hinterlegten Schlüssel bleiben unangetastet."
    echo
    echo "Reihenfolge: Port 22 wird in ufw geöffnet, BEVOR sshd dorthin zurückfällt."
    [[ "$p" != "22" ]] && echo "Die Regel für den aktuellen Port ${p}/tcp bleibt bestehen." || true
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup ssh-setup "$DROPIN" "$SOCKET_DROPIN" "$SSHD_CONF" || { pause; return; }

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        echo "ufw: 22/tcp geöffnet."
    fi

    local restore=""
    if [[ -f "$DROPIN" ]]; then cp "$DROPIN" "$DROPIN.prev"; restore="$DROPIN.prev"; fi
    rm -f "$DROPIN"

    if grep -qF "$MARK_BEGIN" "$SSHD_CONF" 2>/dev/null; then
        sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$SSHD_CONF"
    fi
    sed -i -E 's|^# von ssh-setup deaktiviert: ||' "$SSHD_CONF"

    if ! sshd_test >/dev/null; then
        echo "!!! sshd lehnt die Konfiguration nach dem Entfernen ab:"
        sshd_test || true
        [[ -n "$restore" ]] && mv "$restore" "$DROPIN"
        echo "Zurückgerollt, es wurde nichts entfernt."
        pause; return
    fi
    rm -f "$restore"

    if [[ -f "$SOCKET_DROPIN" ]]; then
        rm -f "$SOCKET_DROPIN"
        rmdir "$SOCKET_DIR" 2>/dev/null || true
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
    fi

    restart_sshd || true

    echo
    echo "Entfernt. sshd lauscht jetzt auf: $(listening_port)"
    echo "Verbindung über Port 22 testen, bevor du die laufende Sitzung schließt."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " SSH-Härtung"
        echo "==========================================="
        echo "Port:            $(effective port)"
        echo "Root-Login:      $(effective permitrootlogin)"
        echo "Passwort-Login:  $(effective passwordauthentication)"
        echo "Drop-in:         $([[ -f "$DROPIN" ]] && echo "$DROPIN" || echo "(keins)")"
        socket_activated && echo "Socket-Aktivierung: ja" || true
        echo
        echo "1) Einrichten / Einstellungen ändern"
        echo "2) Status anzeigen"
        echo "3) Öffentlichen Schlüssel hinterlegen"
        echo "4) Port 22 in ufw schließen (nach erfolgreichem Test)"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) configure ;;
            2) show_status; pause ;;
            3) add_key ;;
            4) close_22 ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Verwendung: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
