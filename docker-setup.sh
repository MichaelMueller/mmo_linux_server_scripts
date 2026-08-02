#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# docker-setup.sh - Docker aus dem offiziellen Repo installieren und einstellen
# Modi:  (ohne Argument) = interaktives Menü
#        --prune         = Aufräumlauf (für cron)
#        --status        = Status auf stdout
#        --uninstall     = Deinstallation
set -uo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/docker-setup.conf"

DAEMON_JSON=/etc/docker/daemon.json
REPO_LIST=/etc/apt/sources.list.d/docker.list
REPO_KEY=/etc/apt/keyrings/docker.asc
CRON_FILE=/etc/cron.d/docker-prune

# ---------------------------------------------------------------------------
# Einstellungen
# ---------------------------------------------------------------------------
LOG_MAX_SIZE="10m"
LOG_MAX_FILE=3
BIND_LOCALHOST=1        # veröffentlichte Ports nur an 127.0.0.1 binden
LIVE_RESTORE=1
PRUNE_ENABLED=0
PRUNE_HOUR=4
PRUNE_ALL_IMAGES=0
PRUNE_UNTIL_H=168       # 7 Tage

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

pause() { read -rp "Weiter mit Enter..." _; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nichts zu sichern)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

installed() { command -v docker &>/dev/null; }

save_conf() {
    cat > "$CONF" <<EOF
# docker-setup Konfiguration
LOG_MAX_SIZE="${LOG_MAX_SIZE}"
LOG_MAX_FILE=${LOG_MAX_FILE}
BIND_LOCALHOST=${BIND_LOCALHOST}
LIVE_RESTORE=${LIVE_RESTORE}
PRUNE_ENABLED=${PRUNE_ENABLED}
PRUNE_HOUR=${PRUNE_HOUR}
PRUNE_ALL_IMAGES=${PRUNE_ALL_IMAGES}
PRUNE_UNTIL_H=${PRUNE_UNTIL_H}
EOF
    chmod 644 "$CONF"
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
# Die Distributionspakete (docker.io) hinken meist mehrere Versionen hinterher
# und bringen das compose-Plugin nicht mit. Deshalb das offizielle Repo.
install_docker() {
    if installed; then
        echo "Docker ist bereits installiert: $(docker --version)"
        return 0
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local id=${ID:-debian} code=${VERSION_CODENAME:-}

    # Ableitungen wie Linux Mint tragen einen eigenen Codenamen, für den es kein
    # Docker-Repo gibt - dort steht der der Basisdistribution daneben.
    if [[ "$id" != "debian" && "$id" != "ubuntu" ]]; then
        if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
            id=ubuntu; code="$UBUNTU_CODENAME"
        elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
            id=debian; code="$DEBIAN_CODENAME"
        else
            echo "Distribution '$id' ist kein Docker-Repo bekannt."
            read -rp "Basis (debian/ubuntu): " id
            read -rp "Codename (z.B. bookworm, noble): " code
        fi
    fi
    [[ -n "$code" ]] || { read -rp "Codename der Distribution: " code; }

    # Alte oder konkurrierende Pakete stören die Installation.
    local -a old=() p
    for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        dpkg -s "$p" &>/dev/null && old+=("$p")
    done
    if (( ${#old[@]} > 0 )); then
        echo "Diese Pakete stehen der offiziellen Installation im Weg:"
        printf '    %s\n' "${old[@]}"
        echo "Container und Daten unter /var/lib/docker bleiben beim Entfernen erhalten."
        confirm "Jetzt entfernen?" J || { echo "Abgebrochen."; return 1; }
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "${old[@]}" >/dev/null || true
    fi

    echo ">>> Repo einrichten (${id}/${code})..."
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl >/dev/null

    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "https://download.docker.com/linux/${id}/gpg" -o "$REPO_KEY"; then
        echo "!!! Schlüssel nicht abrufbar."
        return 1
    fi
    chmod a+r "$REPO_KEY"

    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$REPO_KEY" "$id" "$code" > "$REPO_LIST"

    echo ">>> Installiere Docker..."
    apt-get update -qq
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null; then
        echo "!!! Installation fehlgeschlagen."
        return 1
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    echo ">>> $(docker --version)"
    echo ">>> $(docker compose version 2>/dev/null || echo 'compose-Plugin nicht gefunden')"
}

# ---------------------------------------------------------------------------
# daemon.json
# ---------------------------------------------------------------------------
write_daemon_json() {
    mkdir -p /etc/docker

    # Eine fremde Datei wird nicht überschrieben, sondern zur Seite gelegt -
    # JSON von Hand zusammenzuführen wäre in bash nur geraten.
    if [[ -f "$DAEMON_JSON" ]] && ! grep -q 'docker-setup.sh' "$DAEMON_JSON"; then
        local bak="${DAEMON_JSON}.orig.$(date +%s)"
        cp "$DAEMON_JSON" "$bak"
        echo "Vorhandene $DAEMON_JSON nach $bak gesichert."
        echo "Eigene Einstellungen daraus müssen von Hand übernommen werden:"
        sed 's/^/    /' "$bak"
        confirm "Fortfahren und neu schreiben?" || return 1
    fi

    {
        echo '{'
        echo '  "_comment": "erzeugt von docker-setup.sh",'
        echo '  "log-driver": "json-file",'
        echo '  "log-opts": {'
        echo "    \"max-size\": \"${LOG_MAX_SIZE}\","
        echo "    \"max-file\": \"${LOG_MAX_FILE}\""
        echo '  },'
        (( LIVE_RESTORE == 1 ))   && echo '  "live-restore": true,'
        (( BIND_LOCALHOST == 1 )) && echo '  "ip": "127.0.0.1",'
        echo '  "userland-proxy": true'
        echo '}'
    } > "$DAEMON_JSON"
    chmod 644 "$DAEMON_JSON"

    if installed && systemctl is-active docker &>/dev/null; then
        if systemctl restart docker; then
            echo "$DAEMON_JSON geschrieben, Docker neu gestartet."
        else
            echo "!!! Docker startet mit der neuen Konfiguration nicht:"
            journalctl -u docker -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
            return 1
        fi
    else
        echo "$DAEMON_JSON geschrieben."
    fi
}

settings() {
    echo "--- Aktuelle Einstellungen ---"
    echo "  Log-Rotation:      max ${LOG_MAX_SIZE} × ${LOG_MAX_FILE} je Container"
    echo "  Ports binden an:   $( ((BIND_LOCALHOST==1)) && echo '127.0.0.1 (nur lokal)' || echo '0.0.0.0 (alle Adressen)')"
    echo "  live-restore:      $( ((LIVE_RESTORE==1)) && echo an || echo aus)"
    echo

    local S F
    echo "Ohne Rotation wächst /var/lib/docker/containers unbegrenzt - das ist die"
    echo "häufigste Ursache für eine volle Platte auf einem Docker-Host."
    read -rp "Maximale Größe je Logdatei [${LOG_MAX_SIZE}]: " S; LOG_MAX_SIZE=${S:-$LOG_MAX_SIZE}
    read -rp "Anzahl Dateien je Container [${LOG_MAX_FILE}]: " F; LOG_MAX_FILE=${F:-$LOG_MAX_FILE}

    echo
    echo "Veröffentlichte Ports (-p 8080:80) hängt Docker per iptables DIREKT ins"
    echo "Netz - an ufw vorbei. Eine ufw-Regel schützt sie nicht."
    echo "Bindet man sie standardmäßig an 127.0.0.1, sind sie nur noch lokal und"
    echo "über einen Reverse Proxy (Caddy/nginx) erreichbar."
    confirm "Ports standardmäßig nur an 127.0.0.1 binden?" \
        "$( ((BIND_LOCALHOST==1)) && echo J || echo N)" && BIND_LOCALHOST=1 || BIND_LOCALHOST=0

    echo
    echo "live-restore lässt Container weiterlaufen, während der Docker-Dienst"
    echo "neu startet - etwa bei einem Paket-Update."
    confirm "live-restore aktivieren?" "$( ((LIVE_RESTORE==1)) && echo J || echo N)" \
        && LIVE_RESTORE=1 || LIVE_RESTORE=0

    save_conf
    write_daemon_json || true
    pause
}

# ---------------------------------------------------------------------------
# docker-Gruppe
# ---------------------------------------------------------------------------
add_user() {
    echo "!!! Wer in der Gruppe 'docker' ist, kann über einen Container jede Datei"
    echo "!!! des Systems als root lesen und schreiben. Das ist gleichbedeutend mit"
    echo "!!! root-Rechten, nur ohne sudo-Protokoll."
    echo
    echo "Aktuell in der Gruppe: $(getent group docker | cut -d: -f4 | tr ',' ' ' || echo '(niemand)')"
    echo
    local u
    read -rp "Benutzer (leer = abbrechen): " u
    [[ -n "$u" ]] || return
    if ! id "$u" &>/dev/null; then echo "Benutzer '$u' gibt es nicht."; pause; return; fi

    confirm "'$u' wirklich in die Gruppe docker aufnehmen?" || { echo "Abgebrochen."; pause; return; }
    usermod -aG docker "$u"
    echo "Aufgenommen. Wirksam nach der nächsten Anmeldung von '$u'."
    pause
}

# ---------------------------------------------------------------------------
# Aufräumen
# ---------------------------------------------------------------------------
write_prune_cron() {
    if (( PRUNE_ENABLED == 0 )); then
        rm -f "$CRON_FILE"
        return 0
    fi
    cat > "$CRON_FILE" <<EOF
# docker-prune - räumt ungenutzte Images, Container und Netze weg
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 ${PRUNE_HOUR} * * 0 root ${SELF} --prune >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# Volumes werden NIE automatisch entfernt - dort liegen die Daten, und ein
# Volume ohne laufenden Container ist noch lange kein überflüssiges Volume.
do_prune() {
    installed || { echo "Docker ist nicht installiert." >&2; return 1; }
    local -a args=(system prune -f --filter "until=${PRUNE_UNTIL_H}h")
    (( PRUNE_ALL_IMAGES == 1 )) && args=(system prune -af --filter "until=${PRUNE_UNTIL_H}h")
    docker "${args[@]}"
}

cleanup_menu() {
    installed || { echo "Docker ist nicht installiert."; pause; return; }
    while true; do
        clear
        echo "=== Aufräumen ==="
        docker system df 2>/dev/null || echo "(docker system df nicht verfügbar)"
        echo
        echo "Automatik: $( ((PRUNE_ENABLED==1)) && echo "sonntags ${PRUNE_HOUR}:00, älter als ${PRUNE_UNTIL_H}h$( ((PRUNE_ALL_IMAGES==1)) && echo ', auch ungenutzte Images')" || echo 'aus')"
        echo
        echo "1) Jetzt aufräumen"
        echo "2) Automatik einstellen"
        echo "3) Ungenutzte Volumes anzeigen (löscht nichts)"
        echo "4) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) echo; do_prune; echo; pause ;;
            2)
                confirm "Wöchentlich automatisch aufräumen?" \
                    "$( ((PRUNE_ENABLED==1)) && echo J || echo N)" && PRUNE_ENABLED=1 || PRUNE_ENABLED=0
                if (( PRUNE_ENABLED == 1 )); then
                    local H U
                    read -rp "Stunde (0-23) [${PRUNE_HOUR}]: " H; PRUNE_HOUR=${H:-$PRUNE_HOUR}
                    read -rp "Nur entfernen, was älter ist als (Stunden) [${PRUNE_UNTIL_H}]: " U
                    PRUNE_UNTIL_H=${U:-$PRUNE_UNTIL_H}
                    echo
                    echo "Ohne '-a' fliegen nur Images ohne Tag raus. Mit '-a' auch getaggte"
                    echo "Images, die gerade kein Container benutzt - die müssen dann beim"
                    echo "nächsten Start neu geladen werden."
                    confirm "Auch ungenutzte getaggte Images entfernen (-a)?" \
                        "$( ((PRUNE_ALL_IMAGES==1)) && echo J || echo N)" \
                        && PRUNE_ALL_IMAGES=1 || PRUNE_ALL_IMAGES=0
                fi
                save_conf; write_prune_cron
                echo "Gespeichert."; pause
                ;;
            3)
                echo
                echo "Volumes ohne Container (werden vom Aufräumen NICHT angefasst):"
                docker volume ls -qf dangling=true 2>/dev/null | sed 's/^/  /' || true
                echo
                echo "Einzeln entfernen mit: docker volume rm <name>"
                pause
                ;;
            *) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    if ! installed; then echo "Docker ist nicht installiert."; return; fi
    echo "--- Version ---"
    docker --version 2>/dev/null | sed 's/^/  /'
    docker compose version 2>/dev/null | sed 's/^/  /'
    echo
    echo "--- Dienst ---"
    printf '  docker: %s\n' "$(systemctl is-active docker 2>/dev/null || echo '-')"
    echo
    echo "--- Einstellungen aus $DAEMON_JSON ---"
    if [[ -f "$DAEMON_JSON" ]]; then sed 's/^/  /' "$DAEMON_JSON"; else echo "  (keine)"; fi
    echo
    echo "--- Container ---"
    docker ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "  (keine Ausgabe)"
    echo
    echo "--- Speicherbedarf ---"
    docker system df 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "--- Gruppe docker ---"
    echo "  $(getent group docker | cut -d: -f4 || echo '(niemand)')"

    # Veröffentlichte Ports, die tatsächlich nach außen offen sind
    local exposed
    exposed=$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
              | grep -E '^\s*0\.0\.0\.0:|^\s*:::' | sed 's/^ *//' | sort -u)
    if [[ -n "$exposed" ]]; then
        echo
        echo "!!! Diese Ports sind an ALLE Adressen gebunden und damit an ufw vorbei"
        echo "!!! aus dem Netz erreichbar:"
        printf '  %s\n' "$exposed"
    fi
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation docker-setup"
    echo
    echo "Folgendes wird entfernt:"
    [[ -f "$DAEMON_JSON" ]] && echo "  - $DAEMON_JSON (eine gesicherte Fassung wird zurückgeholt, falls vorhanden)"
    [[ -f "$CONF" ]]        && echo "  - $CONF"
    [[ -f "$CRON_FILE" ]]   && echo "  - $CRON_FILE (automatisches Aufräumen)"
    echo
    echo "Nicht angetastet werden: Docker selbst, laufende Container, Images und"
    echo "vor allem die Volumes unter /var/lib/docker. Vollständig entfernen:"
    echo "    apt purge docker-ce docker-ce-cli containerd.io \\"
    echo "        docker-buildx-plugin docker-compose-plugin"
    echo "    rm -rf /var/lib/docker /var/lib/containerd"
    echo "    rm -f ${REPO_LIST} ${REPO_KEY}"
    echo "  (das löscht auch alle Volumes und damit die Daten der Container)"
    echo
    if installed && [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
        echo "!!! Es laufen gerade $(docker ps -q | wc -l) Container. Sie laufen weiter."
        echo
    fi

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup docker-setup "$DAEMON_JSON" "$CONF" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    local orig
    orig=$(ls -1t "${DAEMON_JSON}".orig.* 2>/dev/null | head -1 || true)
    if [[ -n "$orig" ]]; then
        mv "$orig" "$DAEMON_JSON"
        echo "$DAEMON_JSON aus $orig wiederhergestellt."
    elif [[ -f "$DAEMON_JSON" ]] && grep -q 'docker-setup.sh' "$DAEMON_JSON"; then
        rm -f "$DAEMON_JSON"
        echo "$DAEMON_JSON entfernt."
    fi

    if installed && systemctl is-active docker &>/dev/null; then
        if confirm "Docker jetzt neu starten, damit die Änderung greift?" J; then
            systemctl restart docker || echo "!!! Neustart fehlgeschlagen."
        fi
    fi

    echo
    echo "Entfernt. Ohne Log-Rotation wachsen Container-Logs wieder unbegrenzt -"
    echo "das im Blick behalten (disk-monitor.sh hilft dabei)."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Docker"
        echo "==========================================="
        if installed; then
            echo "Version:  $(docker --version 2>/dev/null | sed 's/Docker version //')"
            echo "Dienst:   $(systemctl is-active docker 2>/dev/null || echo '-')"
            echo "Container: $(docker ps -q 2>/dev/null | wc -l) laufend, $(docker ps -aq 2>/dev/null | wc -l) insgesamt"
            echo "Ports:    $( ((BIND_LOCALHOST==1)) && echo 'standardmäßig nur 127.0.0.1' || echo 'alle Adressen')"
        else
            echo "Status: nicht installiert"
        fi
        echo
        echo "1) Installieren"
        echo "2) Status anzeigen"
        echo "3) Einstellungen (Log-Rotation, Port-Bindung, live-restore)"
        echo "4) Benutzer zur Gruppe docker hinzufügen"
        echo "5) Aufräumen"
        echo "6) Deinstallieren"
        echo "7) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) install_docker && { save_conf; write_daemon_json || true; }; pause ;;
            2) show_status; pause ;;
            3) settings ;;
            4) installed && add_user || { echo "Docker ist nicht installiert."; pause; } ;;
            5) cleanup_menu ;;
            6) uninstall ;;
            7) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --prune)     do_prune ;;
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Verwendung: $0 [--prune|--status|--uninstall|--version]"; exit 1 ;;
esac
