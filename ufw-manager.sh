#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ufw-manager.sh - Firewall-Regeln verwalten (CRUD auf ufw)
# Modi:  (ohne Argument) = interaktives Menü
#        --status        = Regeln auf stdout
#        --uninstall     = Deinstallation
set -euo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

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
# Grundlagen
# ---------------------------------------------------------------------------
ensure_ufw() {
    command -v ufw &>/dev/null && return 0
    echo "ufw ist nicht installiert."
    confirm "Jetzt installieren?" J || return 1
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >/dev/null
    command -v ufw &>/dev/null
}

# Ausgabe von ufw einmal komplett einlesen. Wichtig wegen "set -o pipefail":
# Ein Leser, der vorzeitig aussteigt (head, grep -q, awk exit), schickt dem
# Schreiber SIGPIPE; die Pipeline meldet dann 141, und je nach Stelle bricht das
# Script ab oder eine Prüfung liefert stillschweigend das falsche Ergebnis.
ufw_status() { ufw status 2>/dev/null || true; }

is_active() { [[ "$(ufw_status | awk 'NR==1 {print $2}')" == "active" ]]; }

# Der Port, über den die aktuelle Sitzung läuft - der darf nie zugemauert werden.
ssh_port() {
    local p=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    fi
    if [[ -z "$p" ]] && command -v sshd &>/dev/null; then
        p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}' || true)
    fi
    echo "${p:-22}"
}

on_ssh() { [[ -n "${SSH_CONNECTION:-}" ]]; }

ssh_rule_exists() {
    local p=$1 st
    st=$(ufw_status)
    grep -Eq "(^|[^0-9])${p}(/tcp)?[[:space:]]+(ALLOW|LIMIT)" <<<"$st" && return 0
    # Das Anwendungsprofil deckt SSH ebenfalls ab, nennt aber keinen Port.
    grep -Eq "^OpenSSH[[:space:]]+(ALLOW|LIMIT)" <<<"$st"
}

list_rules() {
    if ! is_active; then
        echo "(ufw ist nicht aktiv)"
        echo
    fi
    ufw status numbered 2>/dev/null || echo "(keine Ausgabe von ufw)"
}

# Text einer nummerierten Regel, z.B. rule_text 3 -> "22/tcp   ALLOW IN  Anywhere"
rule_text() {
    ufw status numbered 2>/dev/null \
        | sed -n "s/^\[[[:space:]]*$1\][[:space:]]*//p" \
        | awk 'NR==1' || true
}

rule_count() {
    ufw status numbered 2>/dev/null | grep -c '^\[' || true
}

# ---------------------------------------------------------------------------
# Regel anlegen
# ---------------------------------------------------------------------------
# Baut das ufw-Kommando zusammen und gibt es über die globale Variable RULE_CMD
# zurück. Ausgeführt wird erst nach Anzeige und Bestätigung.
declare -a RULE_CMD=()

build_rule() {
    RULE_CMD=()

    echo "Aktion:"
    echo "  1) allow   erlauben"
    echo "  2) deny    verwerfen (stillschweigend)"
    echo "  3) reject  ablehnen (mit Fehlermeldung an den Absender)"
    echo "  4) limit   erlauben, aber Brute-Force bremsen (max. 6 Verbindungen/30s)"
    local A ACTION
    read -rp "Auswahl [1]: " A
    case "${A:-1}" in
        2) ACTION=deny ;;
        3) ACTION=reject ;;
        4) ACTION=limit ;;
        *) ACTION=allow ;;
    esac

    echo
    echo "Richtung:"
    echo "  1) eingehend (in)"
    echo "  2) ausgehend (out)"
    local D DIR
    read -rp "Auswahl [1]: " D
    [[ "${D:-1}" == "2" ]] && DIR=out || DIR=in

    echo
    echo "Schnittstellen: $(ip -br link show 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    local IFACE
    read -rp "Nur auf einer Schnittstelle (z.B. wg0, leer = alle): " IFACE

    echo
    echo "Ziel der Regel:"
    echo "  1) Port oder Portbereich"
    echo "  2) Anwendungsprofil (ufw app list)"
    echo "  3) alles (jeder Port)"
    local T
    read -rp "Auswahl [1]: " T; T=${T:-1}

    local PORT="" PROTO="" APP=""
    case "$T" in
        2)
            echo
            ufw app list 2>/dev/null || true
            echo
            read -rp "Profilname (genau wie oben, z.B. 'OpenSSH'): " APP
            while [[ -z "$APP" ]]; do read -rp "  -> Pflichtfeld: " APP; done
            ;;
        3) ;;
        *)
            read -rp "Port oder Bereich (z.B. 443 oder 6000:6010): " PORT
            while [[ ! "$PORT" =~ ^[0-9]+(:[0-9]+)?$ ]]; do
                read -rp "  -> Port oder von:bis: " PORT
            done
            echo "  1) tcp   2) udp   3) beide"
            local P
            read -rp "Protokoll [1]: " P
            case "${P:-1}" in
                2) PROTO=udp ;;
                3) PROTO="" ;;
                *) PROTO=tcp ;;
            esac
            # Portbereiche verlangt ufw immer mit Protokoll.
            if [[ "$PORT" == *:* && -z "$PROTO" ]]; then
                echo "  (Portbereich braucht ein Protokoll - es wird tcp genommen)"
                PROTO=tcp
            fi
            ;;
    esac

    echo
    local SRC DST CMT
    read -rp "Quelle (IP oder CIDR, leer = von überall): " SRC
    read -rp "Ziel-IP auf diesem Host (leer = alle Adressen): " DST
    read -rp "Kommentar (optional, taucht in 'ufw status' auf): " CMT

    # --- Kommando zusammensetzen
    RULE_CMD=(ufw "$ACTION")

    if [[ -n "$IFACE" ]]; then
        # Mit Schnittstelle versteht ufw nur die ausführliche Form.
        RULE_CMD+=("$DIR" on "$IFACE")
        if [[ -n "$APP" ]]; then
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" app "$APP")
        elif [[ -z "$PORT" ]]; then
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}")
        else
            RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" port "$PORT")
            [[ -n "$PROTO" ]] && RULE_CMD+=(proto "$PROTO")
        fi
        [[ -n "$CMT" ]] && RULE_CMD+=(comment "$CMT")
        return 0
    fi

    [[ "$DIR" == "out" ]] && RULE_CMD+=(out)

    if [[ -n "$APP" ]]; then
        if [[ -n "$SRC" ]]; then
            RULE_CMD+=(from "$SRC" to "${DST:-any}" app "$APP")
        else
            RULE_CMD+=("$APP")
        fi
    elif [[ -z "$PORT" ]]; then
        RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}")
    elif [[ -z "$SRC" && -z "$DST" ]]; then
        # Kurzform, wie man sie von Hand schreiben würde
        if [[ -n "$PROTO" ]]; then RULE_CMD+=("${PORT}/${PROTO}"); else RULE_CMD+=("$PORT"); fi
    else
        RULE_CMD+=(from "${SRC:-any}" to "${DST:-any}" port "$PORT")
        [[ -n "$PROTO" ]] && RULE_CMD+=(proto "$PROTO")
    fi

    [[ -n "$CMT" ]] && RULE_CMD+=(comment "$CMT")
    return 0
}

add_rule() {
    echo "--- Vorhandene Regeln ---"; list_rules; echo
    build_rule

    echo
    echo "Folgendes Kommando wird ausgeführt:"
    printf '    %q ' "${RULE_CMD[@]}"; echo
    echo
    confirm "Ausführen?" J || { echo "Abgebrochen."; pause; return; }

    if "${RULE_CMD[@]}"; then
        echo "Angelegt."
    else
        echo "!!! ufw hat die Regel abgelehnt."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Regel löschen
# ---------------------------------------------------------------------------
delete_rule() {
    echo "--- Regeln ---"; list_rules; echo
    (( $(rule_count) > 0 )) || { echo "Keine Regeln vorhanden."; pause; return; }

    local N
    read -rp "Nummer der Regel zum Löschen (leer = abbrechen): " N
    [[ -n "$N" ]] || return
    while [[ ! "$N" =~ ^[0-9]+$ ]]; do read -rp "  -> Zahl erwartet: " N; done

    local txt; txt=$(rule_text "$N")
    [[ -n "$txt" ]] || { echo "Es gibt keine Regel mit der Nummer $N."; pause; return; }

    echo
    echo "Regel [$N]: $txt"

    local sp; sp=$(ssh_port)
    if on_ssh && grep -qE "(^|[^0-9])${sp}(/tcp)?[[:space:]]" <<<"$txt"; then
        echo
        echo "!!! Diese Regel betrifft Port ${sp} - darüber läuft deine aktuelle"
        echo "!!! SSH-Sitzung. Löschen sperrt dich beim nächsten Verbindungsversuch aus."
    fi
    echo

    confirm "Wirklich löschen?" || { echo "Abgebrochen."; pause; return; }

    # Zwischen Anzeige und Löschen kann sich die Nummerierung geändert haben
    # (paralleles Fenster, v6-Einträge). Deshalb vor dem Löschen gegenprüfen.
    if [[ "$(rule_text "$N")" != "$txt" ]]; then
        echo "!!! Die Nummerierung hat sich geändert - nichts gelöscht. Bitte neu ansehen."
        pause; return
    fi

    ufw --force delete "$N" || echo "!!! Löschen fehlgeschlagen."
    pause
}

# ---------------------------------------------------------------------------
# Regel bearbeiten = neue anlegen, dann alte löschen
# ---------------------------------------------------------------------------
edit_rule() {
    echo "--- Regeln ---"; list_rules; echo
    (( $(rule_count) > 0 )) || { echo "Keine Regeln vorhanden."; pause; return; }

    echo "ufw kann Regeln nicht ändern. Bearbeiten heißt deshalb: neue Regel"
    echo "anlegen, dann die alte löschen - in dieser Reihenfolge, damit nie eine"
    echo "Lücke entsteht."
    echo
    local N
    read -rp "Nummer der Regel zum Ersetzen (leer = abbrechen): " N
    [[ -n "$N" ]] || return
    while [[ ! "$N" =~ ^[0-9]+$ ]]; do read -rp "  -> Zahl erwartet: " N; done

    local txt; txt=$(rule_text "$N")
    [[ -n "$txt" ]] || { echo "Es gibt keine Regel mit der Nummer $N."; pause; return; }

    echo
    echo "Wird ersetzt: [$N] $txt"
    echo
    build_rule

    echo
    echo "Neue Regel:"
    printf '    %q ' "${RULE_CMD[@]}"; echo
    echo "Danach wird gelöscht: $txt"
    echo
    confirm "Ausführen?" J || { echo "Abgebrochen."; pause; return; }

    if ! "${RULE_CMD[@]}"; then
        echo "!!! Neue Regel abgelehnt - die alte bleibt unverändert."
        pause; return
    fi

    # Nummer neu auflösen: durch die neue Regel kann sie sich verschoben haben.
    local i newnum=""
    for (( i=1; i<=$(rule_count); i++ )); do
        if [[ "$(rule_text "$i")" == "$txt" ]]; then newnum=$i; break; fi
    done

    if [[ -z "$newnum" ]]; then
        echo "!!! Die alte Regel ist nicht mehr auffindbar (identisch zur neuen?)."
        echo "    Es wurde nichts gelöscht - bitte die Liste prüfen."
    else
        ufw --force delete "$newnum" || echo "!!! Löschen der alten Regel fehlgeschlagen."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Rezept: SSH nur noch über den WireGuard-Tunnel
# ---------------------------------------------------------------------------
# Zwei Stufen, wie beim Portwechsel in ssh-setup: erst die enge Regel dazu,
# testen, und erst danach die offene Regel weg. Eine einzelne Regel wäre schnell
# geschrieben - die Reihenfolge ist das, was einen nicht aussperrt.
wg_listen_port() {
    local f
    for f in /etc/wireguard/wg0-interface.conf /etc/wireguard/wg0.conf; do
        [[ -f "$f" ]] || continue
        awk -F'= *' '/^ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "$f"
        return 0
    done
}

wg_rule_text() {
    local sp=$1 iface=$2
    ufw_status | grep -E "on ${iface}" | grep -E "(^|[^0-9])${sp}(/tcp)?[[:space:]]" | awk 'NR==1' || true
}

ssh_via_wireguard() {
    local sp iface wgport
    sp=$(ssh_port)

    read -rp "WireGuard-Schnittstelle [wg0]: " iface; iface=${iface:-wg0}
    echo

    if ! ip link show "$iface" &>/dev/null; then
        echo "!!! Die Schnittstelle '$iface' gibt es nicht. Erst WireGuard einrichten."
        pause; return
    fi

    # --- Stufe 2: die enge Regel steht schon, jetzt darf die offene weg
    if [[ -n "$(wg_rule_text "$sp" "$iface")" ]]; then
        echo "Die Regel für SSH über ${iface} existiert bereits:"
        echo "    $(wg_rule_text "$sp" "$iface")"
        echo
        echo "Zweiter Schritt: die offene SSH-Regel entfernen, damit Port ${sp} von"
        echo "außen dicht ist."
        echo
        echo "!!! Nur machen, wenn die Anmeldung ÜBER DEN TUNNEL nachweislich"
        echo "!!! funktioniert hat. Danach ist SSH ohne Tunnel nicht mehr erreichbar."
        echo
        list_rules
        echo
        confirm "Offene SSH-Regel jetzt heraussuchen und löschen?" \
            || { echo "Abgebrochen."; pause; return; }
        echo
        echo "Die Nummer der Regel wählen, die Port ${sp} von 'Anywhere' erlaubt"
        echo "(NICHT die mit '${iface}'):"
        delete_rule
        return
    fi

    # --- Stufe 1: enge Regel anlegen, offene stehen lassen
    echo "SSH-Port: ${sp}   Schnittstelle: ${iface}"
    wgport=$(wg_listen_port)
    echo "WireGuard-Port: ${wgport:-unbekannt}"
    echo

    # Ohne offenen UDP-Port kommt der Tunnel nicht hoch - und dann kommt man
    # auch über ihn nicht mehr rein. Das ist der klassische Fehlgriff.
    if [[ -n "${wgport:-}" ]]; then
        if grep -qE "(^|[^0-9])${wgport}/udp[[:space:]]+(ALLOW|LIMIT)" <<<"$(ufw_status)"; then
            echo "  [x] ${wgport}/udp ist offen - der Tunnel kann aufgebaut werden."
        else
            echo "  [ ] !!! Für ${wgport}/udp gibt es keine Regel. Ohne die kommt der"
            echo "          Tunnel nicht zustande, und mit ihm nichts mehr."
            if confirm "      Regel 'ufw allow ${wgport}/udp' jetzt anlegen?" J; then
                ufw allow "${wgport}/udp" comment 'WireGuard' || true
            else
                echo "      Abgebrochen - ohne offenen WireGuard-Port wäre das fahrlässig."
                pause; return
            fi
        fi
    else
        echo "  [ ] WireGuard-Port nicht ermittelbar - bitte selbst prüfen, dass er offen ist."
    fi

    if command -v wg &>/dev/null && [[ -n "$(wg show "$iface" peers 2>/dev/null)" ]]; then
        echo "  [x] Der Tunnel hat konfigurierte Peers."
    else
        echo "  [ ] Kein Peer auf ${iface} - es könnte also niemand über den Tunnel rein."
    fi

    echo
    echo "Angelegt wird:"
    echo "    ufw allow in on ${iface} to any port ${sp} proto tcp comment 'SSH via WireGuard'"
    echo
    echo "Die bestehende offene SSH-Regel bleibt zunächst erhalten. Erst testen,"
    echo "dann diesen Menüpunkt erneut aufrufen - er bietet dann das Aufräumen an."
    echo

    confirm "Anlegen?" J || { echo "Abgebrochen."; pause; return; }

    if ufw allow in on "$iface" to any port "$sp" proto tcp comment 'SSH via WireGuard'; then
        echo
        echo "Angelegt. Jetzt den Tunnel aufbauen und testen:"
        echo "    ssh -p ${sp} <benutzer>@<tunnel-ip-dieses-servers>"
    else
        echo "!!! ufw hat die Regel abgelehnt."
    fi
    pause
}

# ---------------------------------------------------------------------------
# Firewall ein/aus, Defaults, Logging
# ---------------------------------------------------------------------------
toggle_ufw() {
    if is_active; then
        echo "ufw ist aktiv."
        echo
        echo "!!! Ohne Firewall ist jeder lauschende Dienst aus dem Netz erreichbar."
        confirm "Wirklich deaktivieren?" || { echo "Abgebrochen."; pause; return; }
        ufw disable
        pause
        return
    fi

    echo "ufw ist nicht aktiv."
    local sp; sp=$(ssh_port)

    if ! ssh_rule_exists "$sp"; then
        echo
        echo "!!! Für Port ${sp} (SSH) gibt es keine ALLOW-Regel. Mit der Default-"
        echo "!!! Politik 'deny incoming' bist du nach dem Einschalten ausgesperrt."
        echo
        if confirm "Regel 'ufw limit ${sp}/tcp' vorher anlegen?" J; then
            ufw limit "${sp}/tcp" comment 'SSH' || true
        elif on_ssh; then
            echo
            echo "Du bist über SSH verbunden und es gibt keine passende Regel."
            confirm "Trotzdem einschalten und dich damit aussperren?" \
                || { echo "Abgebrochen."; pause; return; }
        fi
    fi

    ufw --force enable
    pause
}

set_defaults() {
    echo "--- Aktuelle Vorgaben ---"
    grep -E '^DEFAULT_(INPUT|OUTPUT|FORWARD)_POLICY' /etc/default/ufw 2>/dev/null || true
    echo
    echo "Eingehend:"
    echo "  1) deny   (Standard und empfohlen)"
    echo "  2) reject"
    echo "  3) allow  (alles offen - nur mit gutem Grund)"
    local I
    read -rp "Auswahl [1]: " I
    case "${I:-1}" in
        2) ufw default reject incoming ;;
        3) confirm "Wirklich ALLES eingehend erlauben?" && ufw default allow incoming || true ;;
        *) ufw default deny incoming ;;
    esac

    echo
    echo "Ausgehend:"
    echo "  1) allow  (Standard)"
    echo "  2) deny"
    local O
    read -rp "Auswahl [1]: " O
    case "${O:-1}" in
        2) ufw default deny outgoing ;;
        *) ufw default allow outgoing ;;
    esac
    pause
}

set_logging() {
    echo "Protokollierung:"
    echo "  1) off      2) low (Standard)   3) medium   4) high"
    local L
    read -rp "Auswahl [2]: " L
    case "${L:-2}" in
        1) ufw logging off ;;
        3) ufw logging medium ;;
        4) ufw logging high ;;
        *) ufw logging low ;;
    esac
    echo "Die Einträge landen in /var/log/ufw.log."
    pause
}

show_apps() {
    echo "--- Anwendungsprofile ---"
    ufw app list 2>/dev/null || true
    echo
    read -rp "Profil für Details (leer = zurück): " A
    [[ -n "$A" ]] || return
    ufw app info "$A" 2>/dev/null || echo "Unbekanntes Profil."
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation Firewall-Verwaltung"
    echo
    if ! command -v ufw &>/dev/null; then
        echo "ufw ist gar nicht installiert - nichts zu tun."
        pause; return
    fi
    echo "Dieses Tool legt nichts eigenes an - es verwaltet ufw. Zu entfernen gibt"
    echo "es deshalb nur den Zustand von ufw selbst:"
    echo
    echo "  - alle Regeln zurücksetzen (ufw reset)                  [Rückfrage]"
    echo "  - ufw deaktivieren                                      [Rückfrage]"
    echo
    echo "Das Paket ufw bleibt installiert. Manuell: apt purge ufw"
    echo
    echo "!!! Ohne Firewall ist jeder lauschende Dienst offen erreichbar. Wenn nur"
    echo "!!! einzelne Regeln weg sollen, ist Menüpunkt 3 der richtige Weg."
    echo

    confirm "Fortfahren?" || { echo "Abgebrochen."; pause; return; }

    make_backup ufw /etc/ufw /etc/default/ufw || { pause; return; }

    if confirm "Alle Regeln zurücksetzen?"; then
        # 'ufw reset' schaltet ufw dabei selbst ab und legt in /etc/ufw
        # zusätzlich datierte Kopien der bisherigen Regeln an.
        ufw --force reset
        echo "Regeln zurückgesetzt."
    fi

    if is_active && confirm "ufw deaktivieren?"; then
        ufw disable
    fi

    echo
    echo "Fertig. Aktueller Stand:"
    ufw status verbose 2>/dev/null | head -5 || true
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Firewall (ufw)"
        echo "==========================================="
        if is_active; then
            echo "Status: aktiv   |   Regeln: $(rule_count)   |   SSH-Port: $(ssh_port)"
        else
            echo "Status: NICHT aktiv   |   SSH-Port: $(ssh_port)"
        fi
        echo
        list_rules
        echo
        echo " 1) Regel anlegen"
        echo " 2) Regel bearbeiten (ersetzen)"
        echo " 3) Regel löschen"
        echo " 4) SSH nur über WireGuard erreichbar machen"
        echo " 5) Anwendungsprofile ansehen"
        echo " 6) Firewall $(is_active && echo deaktivieren || echo aktivieren)"
        echo " 7) Vorgaben (default incoming/outgoing)"
        echo " 8) Protokollierung"
        echo " 9) Deinstallieren"
        echo "10) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1)  add_rule ;;
            2)  edit_rule ;;
            3)  delete_rule ;;
            4)  ssh_via_wireguard ;;
            5)  show_apps ;;
            6)  toggle_ufw ;;
            7)  set_defaults ;;
            8)  set_logging ;;
            9)  uninstall ;;
            10) exit 0 ;;
            *)  sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    command -v ufw &>/dev/null && ufw status verbose || echo "ufw ist nicht installiert." ;;
    --uninstall) uninstall ;;
    "")          ensure_ufw || { echo "Ohne ufw geht hier nichts."; exit 1; }
                 main_menu ;;
    *)           echo "Verwendung: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
