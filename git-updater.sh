#!/usr/bin/env bash
# git-updater.sh - Git-Arbeitskopien per Cron aktuell halten
# Modi:  (ohne Argument) = interaktives Menü
#        --run           = einmaliger Durchlauf über alle Repos (für cron)
#        --status        = Kurzstatus auf stdout
#        --uninstall     = Deinstallation
#
# Bewusst ohne 'set -e': der Runner sammelt Fehler und meldet sie am Ende,
# statt beim ersten kaputten Repo abzubrechen.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/git-updater.conf"
CRON_FILE=/etc/cron.d/git-updater

# ---------------------------------------------------------------------------
# Konfiguration laden / Defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5
TIMEOUT=120              # Sekunden je git-Aufruf
RETENTION_DAYS=30
MAIL_ON_UPDATE=1         # Mail, wenn neue Commits geholt wurden
MAIL_ON_ERROR=1          # Mail, wenn ein Repo nicht aktualisiert werden konnte
MAIL_ON_NOOP=0           # Mail auch, wenn es nichts zu tun gab
ALERT_MAIL=""
ALERT_WEBHOOK=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

REPOS_DIR="$DATA_DIR/repos.d"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
ALERT_LOG="$LOG_DIR/alerts.log"
RUN_LOG="$LOG_DIR/git-updater.log"
LOCK_FILE="$DATA_DIR/.lock"

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
    local ts tgz p dir
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nichts zu sichern)"; return 0; fi
    if [[ $EUID -eq 0 ]]; then dir=/root; else dir="$HOME"; fi
    mkdir -p "$dir" 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="${dir}/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" && -d "$REPOS_DIR" ]]; }

make_dirs() { mkdir -p "$REPOS_DIR" "$STATE_DIR" "$LOG_DIR"; }

save_conf() {
    cat > "$CONF" <<EOF
# git-updater Konfiguration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
TIMEOUT=${TIMEOUT}
RETENTION_DAYS=${RETENTION_DAYS}
MAIL_ON_UPDATE=${MAIL_ON_UPDATE}
MAIL_ON_ERROR=${MAIL_ON_ERROR}
MAIL_ON_NOOP=${MAIL_ON_NOOP}
ALERT_MAIL="${ALERT_MAIL}"
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
EOF
    chmod 644 "$CONF"
}

write_cron() {
    if [[ $EUID -ne 0 ]]; then
        echo "Cron-Eintrag braucht root. Manuell eintragen:"
        echo "*/${INTERVAL_MIN} * * * * root ${SELF} --run"
        return
    fi
    cat > "$CRON_FILE" <<EOF
# git-updater - hält Arbeitskopien aktuell
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --run >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# git-Aufruf im Namen des Eigentümers
# ---------------------------------------------------------------------------
# Ein Repo gehört selten root. Läuft git als der Eigentümer, greifen dessen
# SSH-Schlüssel und Credential-Helper, und gits Schutz gegen fremde
# Verzeichnisse ("detected dubious ownership") kommt gar nicht erst zum Tragen.
#
# BatchMode/GIT_TERMINAL_PROMPT sind Pflicht: ein Cron-Lauf, der auf eine
# Passphrase oder eine Host-Key-Bestätigung wartet, hängt sonst bis zum Timeout
# und beim nächsten Mal wieder.
gitrun() {
    local u=$1 p=$2; shift 2
    local -a genv=(
        GIT_TERMINAL_PROMPT=0
        GIT_SSH_COMMAND='ssh -o BatchMode=yes'
    )
    if [[ "$u" == "$(id -un)" ]]; then
        env "${genv[@]}" timeout "$TIMEOUT" git -C "$p" "$@"
    else
        sudo -n -u "$u" env "${genv[@]}" timeout "$TIMEOUT" git -C "$p" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Repos (CRUD)
# ---------------------------------------------------------------------------
repo_file() { echo "$REPOS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

list_repos() {
    if [[ ! -d "$REPOS_DIR" ]] || ! ls "$REPOS_DIR"/*.conf &>/dev/null; then
        echo "(keine Repositories eingetragen)"
        return
    fi
    printf "%-16s %-34s %-12s %-9s %-7s %s\n" \
        "NAME" "VERZEICHNIS" "BRANCH" "BENUTZER" "AKTIV" "STAND"
    printf "%-16s %-34s %-12s %-9s %-7s %s\n" \
        "----------------" "----------------------------------" "------------" \
        "---------" "-------" "--------------------"
    local f
    for f in "$REPOS_DIR"/*.conf; do
        ( . "$f"
          local st="-" ts="-"
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              st=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
              ts=$(cut -d'|' -f2 "$STATE_DIR/${NAME}.state")
          fi
          printf "%-16s %-34s %-12s %-9s %-7s %s %s\n" \
              "$NAME" "$REPO_PATH" "${BRANCH:-(aktueller)}" "$RUN_USER" \
              "$([[ "$ENABLED" == "1" ]] && echo ja || echo nein)" "$st" "$ts"
        )
    done
}

create_repo() {
    echo "--- Vorhandene Einträge ---"; list_repos; echo

    local NAME REPO_PATH BRANCH RUN_USER POST_CMD NOTE
    read -rp "Name: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(repo_file "$NAME")" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Name: " NAME
    done

    read -rp "Verzeichnis der Arbeitskopie: " REPO_PATH
    while [[ ! -d "$REPO_PATH/.git" ]]; do
        echo "  -> Dort liegt kein Git-Repository (.git fehlt)."
        read -rp "  Verzeichnis: " REPO_PATH
        [[ -z "$REPO_PATH" ]] && { echo "Abgebrochen."; pause; return; }
    done
    REPO_PATH=${REPO_PATH%/}

    # Der Eigentümer des Verzeichnisses ist fast immer der richtige Benutzer.
    local owner; owner=$(stat -c %U "$REPO_PATH" 2>/dev/null || echo root)
    read -rp "Als welcher Benutzer ausführen [${owner}]: " RUN_USER
    RUN_USER=${RUN_USER:-$owner}
    while ! id "$RUN_USER" &>/dev/null; do
        echo "  -> Benutzer gibt es nicht."
        read -rp "  Benutzer: " RUN_USER
    done

    local cur; cur=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)
    read -rp "Branch [${cur:-aktueller}]: " BRANCH

    echo
    echo "Nach einem Update mit neuen Commits kann ein Kommando laufen, z.B."
    echo "'docker compose up -d' oder 'systemctl reload caddy'. Es läuft im"
    echo "Verzeichnis der Arbeitskopie als ${RUN_USER}."
    read -rp "Kommando (leer = keins): " POST_CMD

    read -rp "Notiz (optional): " NOTE

    cat > "$(repo_file "$NAME")" <<EOF
NAME="${NAME}"
REPO_PATH="${REPO_PATH}"
BRANCH="${BRANCH}"
RUN_USER="${RUN_USER}"
POST_CMD="${POST_CMD}"
ENABLED="1"
NOTE="${NOTE}"
EOF

    echo
    echo "Sofort-Test:"
    make_dirs
    update_one "$(repo_file "$NAME")" verbose
    pause
}

edit_repo() {
    echo "--- Einträge ---"; list_repos; echo
    read -rp "Name zum Bearbeiten: " N
    local f; f=$(repo_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    # shellcheck disable=SC1090
    . "$f"
    local P B U C E O
    read -rp "Verzeichnis [${REPO_PATH}]: " P; P=${P:-$REPO_PATH}
    read -rp "Branch [${BRANCH:-(aktueller)}]: " B; B=${B:-$BRANCH}
    read -rp "Benutzer [${RUN_USER}]: " U; U=${U:-$RUN_USER}
    read -rp "Kommando nach Update [${POST_CMD}]: " C; C=${C:-$POST_CMD}
    read -rp "Aktiv (1/0) [${ENABLED}]: " E; E=${E:-$ENABLED}
    read -rp "Notiz [${NOTE}]: " O; O=${O:-$NOTE}

    cat > "$f" <<EOF
NAME="${NAME}"
REPO_PATH="${P%/}"
BRANCH="${B}"
RUN_USER="${U}"
POST_CMD="${C}"
ENABLED="${E}"
NOTE="${O}"
EOF
    echo "Aktualisiert."
    pause
}

delete_repo() {
    echo "--- Einträge ---"; list_repos; echo
    read -rp "Name zum Entfernen: " N
    local f; f=$(repo_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    echo
    echo "Entfernt nur den Eintrag - die Arbeitskopie auf der Platte bleibt."
    confirm "'$N' wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }
    rm -f "$f" "$STATE_DIR/${N}.state"
    echo "Entfernt."
    pause
}

repo_menu() {
    while true; do
        clear
        echo "=== Repositories verwalten ==="
        list_repos
        echo
        echo "1) Eintrag anlegen"
        echo "2) Eintrag bearbeiten"
        echo "3) Eintrag entfernen"
        echo "4) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) create_repo ;;
            2) edit_repo ;;
            3) delete_repo ;;
            4) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Aktualisierung
# ---------------------------------------------------------------------------
notify() {
    local subject=$1 body=$2
    echo "$(date '+%F %T') ${subject}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":\"${subject//\"/\\\"}\"}" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_MAIL" ]]; then
        if command -v mail &>/dev/null; then
            printf '%s\n' "$body" | mail -s "$subject" "$ALERT_MAIL" \
                || echo "$(date '+%F %T') !!! Mailversand fehlgeschlagen" >> "$ALERT_LOG"
        else
            echo "$(date '+%F %T') !!! 'mail' fehlt - kein Versand" >> "$ALERT_LOG"
        fi
    fi
}

# Setzt die globalen RESULT (OK|UPDATED|ERROR), DETAIL und LINE.
update_one() {
    local f=$1 verbose=${2:-}

    # shellcheck disable=SC1090
    . "$f"

    RESULT=OK; DETAIL=""; LINE=""

    if [[ "$ENABLED" != "1" && -z "$verbose" ]]; then RESULT=SKIP; return 0; fi

    if [[ ! -d "$REPO_PATH/.git" ]]; then
        RESULT=ERROR; DETAIL="kein Git-Repository unter ${REPO_PATH}"
    else
        local old new out rc=0
        old=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --short HEAD 2>/dev/null)

        if [[ -z "$old" ]]; then
            RESULT=ERROR; DETAIL="HEAD nicht lesbar (Rechte? Benutzer ${RUN_USER}?)"
        else
            # Lokale Änderungen zuerst prüfen: ein --ff-only scheitert daran
            # ohnehin, aber mit einer viel unklareren Meldung.
            if [[ -n "$(gitrun "$RUN_USER" "$REPO_PATH" status --porcelain 2>/dev/null)" ]]; then
                RESULT=ERROR; DETAIL="lokale Änderungen in der Arbeitskopie"
            else
                if [[ -n "$BRANCH" ]]; then
                    out=$(gitrun "$RUN_USER" "$REPO_PATH" checkout "$BRANCH" 2>&1) || {
                        RESULT=ERROR; DETAIL="Branch '${BRANCH}' nicht auscheckbar: $(head -1 <<<"$out")"
                    }
                fi

                if [[ "$RESULT" != "ERROR" ]]; then
                    # --ff-only: niemals automatisch mergen oder rebasen. Ist die
                    # Arbeitskopie auseinandergelaufen, soll es auffallen und
                    # nicht stillschweigend ein Merge-Commit entstehen.
                    out=$(gitrun "$RUN_USER" "$REPO_PATH" pull --ff-only --quiet 2>&1) || rc=$?
                    if (( rc != 0 )); then
                        RESULT=ERROR
                        case "$out" in
                            *"no tracking information"*|*"no upstream"*)
                                DETAIL="kein Upstream für den Branch gesetzt" ;;
                            *"Not possible to fast-forward"*|*"non-fast-forward"*|*"diverged"*)
                                DETAIL="Arbeitskopie ist auseinandergelaufen (kein Fast-Forward)" ;;
                            *"Permission denied"*|*"Could not read from remote"*)
                                DETAIL="kein Zugriff auf das Remote (SSH-Schlüssel für ${RUN_USER}?)" ;;
                            *)
                                DETAIL=$(head -2 <<<"$out" | tr '\n' ' ') ;;
                        esac
                        (( rc == 124 )) && DETAIL="Zeitüberschreitung nach ${TIMEOUT}s"
                    else
                        new=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --short HEAD 2>/dev/null)
                        if [[ "$old" != "$new" ]]; then
                            RESULT=UPDATED
                            DETAIL="${old} -> ${new}"
                            LINE=$(gitrun "$RUN_USER" "$REPO_PATH" log -1 --pretty='%h %s (%an)' 2>/dev/null)

                            if [[ -n "$POST_CMD" ]]; then
                                local pout prc=0
                                if [[ "$RUN_USER" == "$(id -un)" ]]; then
                                    pout=$(cd "$REPO_PATH" && timeout "$TIMEOUT" bash -c "$POST_CMD" 2>&1) || prc=$?
                                else
                                    pout=$(sudo -n -u "$RUN_USER" bash -c \
                                        "cd $(printf %q "$REPO_PATH") && timeout $TIMEOUT bash -c $(printf %q "$POST_CMD")" 2>&1) || prc=$?
                                fi
                                if (( prc != 0 )); then
                                    RESULT=ERROR
                                    DETAIL="${DETAIL}, aber Kommando fehlgeschlagen: $(head -1 <<<"$pout")"
                                else
                                    DETAIL="${DETAIL}, Kommando ausgeführt"
                                fi
                            fi
                        else
                            DETAIL="unverändert (${old})"
                        fi
                    fi
                fi
            fi
        fi
    fi

    if [[ -n "$verbose" ]]; then
        printf '%-16s %-8s %s\n' "$NAME" "$RESULT" "$DETAIL"
        [[ -n "$LINE" ]] && echo "                 $LINE"
    fi
    return 0
}

run_update() {
    local verbose=${1:-}
    is_setup || { echo "Nicht eingerichtet. Erst Setup ausführen." >&2; return 1; }
    make_dirs

    # Bei 5-Minuten-Takt kann ein langsamer Lauf in den nächsten laufen. Fehlt
    # flock (nicht auf jedem System vorhanden), wird ohne Sperre gearbeitet -
    # lieber ein möglicher Überlapp als gar kein Lauf.
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "Ein Lauf ist noch nicht fertig - übersprungen." >&2
            echo "$(date '+%F %T') Lauf übersprungen (Sperre)" >> "$RUN_LOG"
            return 0
        fi
    fi

    local now host f prev sf
    now=$(date '+%F %T')
    host=$(hostname -f 2>/dev/null || hostname)

    local -a changes=()
    local rc=0 any=0 updated=0 failed=0

    for f in "$REPOS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        # update_one setzt bewusst globale Variablen (keine Subshell), damit
        # RESULT und DETAIL hier ankommen.
        NAME=""; REPO_PATH=""; BRANCH=""; RUN_USER=""; POST_CMD=""; ENABLED=""; NOTE=""
        update_one "$f" "$verbose"
        [[ "$RESULT" == "SKIP" ]] && continue
        any=1

        sf="$STATE_DIR/${NAME}.state"
        prev="-"
        [[ -f "$sf" ]] && prev=$(cut -d'|' -f1 "$sf")
        echo "${RESULT}|${now}|${DETAIL}" > "$sf"

        [[ "$RESULT" == "ERROR" ]] && rc=1

        case "$RESULT" in
            UPDATED)
                changes+=("UPDATE  ${NAME}: ${DETAIL}${LINE:+ | ${LINE}}")
                updated=$(( updated + 1 ))
                ;;
            ERROR)
                # Nicht bei jedem Lauf nachtreten - nur beim Wechsel.
                if [[ "$prev" != "ERROR" ]]; then
                    changes+=("FEHLER  ${NAME}: ${DETAIL}")
                    failed=$(( failed + 1 ))
                fi
                ;;
            OK)
                [[ "$prev" == "ERROR" ]] && changes+=("ERHOLT  ${NAME}: wieder in Ordnung")
                ;;
        esac

        echo "$(date '+%F %T') ${NAME} ${RESULT} ${DETAIL}" >> "$RUN_LOG"
    done

    tail -n 2000 "$RUN_LOG" > "$RUN_LOG.tmp" 2>/dev/null && mv "$RUN_LOG.tmp" "$RUN_LOG"

    local do_mail=0
    (( updated > 0 && MAIL_ON_UPDATE == 1 )) && do_mail=1
    (( failed  > 0 && MAIL_ON_ERROR  == 1 )) && do_mail=1
    (( ${#changes[@]} == 0 && MAIL_ON_NOOP == 1 && any == 1 )) && do_mail=1

    if (( do_mail == 1 )); then
        local body subject
        body="git-updater auf ${host}"$'\n'"Stand: ${now}"$'\n\n'
        if (( ${#changes[@]} > 0 )); then
            body+=$(printf '  %s\n' "${changes[@]}")
        else
            body+="  Keine Änderungen."
        fi
        if (( failed > 0 )); then
            subject="[git] ${host}: ${failed} Repo(s) mit Fehler"
        elif (( updated > 0 )); then
            subject="[git] ${host}: ${updated} Repo(s) aktualisiert"
        else
            subject="[git] ${host}: keine Änderungen"
        fi
        notify "$subject" "$body"
    fi

    if [[ -n "$verbose" ]]; then
        echo
        if (( ${#changes[@]} > 0 )); then
            printf '%s\n' "${changes[@]}"
        else
            echo "Keine Änderungen - es würde keine Mail verschickt."
        fi
    fi

    return $rc
}

show_log() {
    echo "--- Letzte Meldungen ---"
    tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(keine)"
    echo
    echo "--- Letzte Läufe ---"
    tail -n 20 "$RUN_LOG" 2>/dev/null || echo "(keine)"
    pause
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------
configure() {
    echo ">>> Einstellungen git-updater"
    echo

    local D I T
    read -rp "Datenverzeichnis [${DATA_DIR}]: " D; DATA_DIR=${D:-$DATA_DIR}
    read -rp "Prüfintervall in Minuten [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}
    read -rp "Zeitlimit je git-Aufruf in Sekunden [${TIMEOUT}]: " T; TIMEOUT=${T:-$TIMEOUT}

    echo
    echo "--- Benachrichtigung ---"
    local M W
    read -rp "E-Mail-Adresse (leer = keine) [${ALERT_MAIL}]: " M; ALERT_MAIL=${M:-$ALERT_MAIL}
    read -rp "Webhook-URL (leer = keiner) [${ALERT_WEBHOOK}]: " W; ALERT_WEBHOOK=${W:-$ALERT_WEBHOOK}

    if [[ -n "$ALERT_MAIL$ALERT_WEBHOOK" ]]; then
        confirm "Melden, wenn neue Commits geholt wurden?" \
            "$([[ $MAIL_ON_UPDATE -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_UPDATE=1 || MAIL_ON_UPDATE=0
        confirm "Melden, wenn ein Repo nicht aktualisiert werden konnte?" \
            "$([[ $MAIL_ON_ERROR -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_ERROR=1 || MAIL_ON_ERROR=0
        confirm "Auch melden, wenn es nichts zu tun gab?" \
            "$([[ $MAIL_ON_NOOP -eq 1 ]] && echo J || echo N)" \
            && MAIL_ON_NOOP=1 || MAIL_ON_NOOP=0
    fi

    REPOS_DIR="$DATA_DIR/repos.d"
    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    ALERT_LOG="$LOG_DIR/alerts.log"
    RUN_LOG="$LOG_DIR/git-updater.log"
    LOCK_FILE="$DATA_DIR/.lock"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Daten:    $DATA_DIR"
    echo "Cron:     alle ${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Eingerichtet. Jetzt unter 'Repositories verwalten' Einträge anlegen."
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation git-updater"
    echo

    local n=0
    [[ -d "$REPOS_DIR" ]] && n=$(find "$REPOS_DIR" -name '*.conf' 2>/dev/null | wc -l)

    echo "Folgendes wird entfernt:"
    [[ -f "$CRON_FILE" ]] && echo "  - Cron-Eintrag $CRON_FILE (alle ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - Konfiguration $CONF"
    [[ -d "$DATA_DIR" ]]  && echo "  - Datenverzeichnis $DATA_DIR (${n} Einträge, Zustand, Logs)   [Rückfrage]"
    echo
    echo "Die Arbeitskopien selbst werden nicht angefasst - es wird nur nicht"
    echo "mehr automatisch gepullt."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup git-updater "$CONF" "$DATA_DIR" || { pause; return; }

    if [[ -f "$CRON_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo "!!! Kein root - Cron-Eintrag bitte manuell entfernen:"
            echo "    rm -f $CRON_FILE"
        else
            rm -f "$CRON_FILE"
        fi
    fi
    rm -f "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Einträge und Logs in $DATA_DIR ebenfalls löschen?"; then
        rm -rf "$DATA_DIR"
    fi

    echo
    echo "Entfernt."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Git-Arbeitskopien aktuell halten"
        echo "==========================================="
        if is_setup; then
            echo "Daten: $DATA_DIR"
            echo "Cron:  $([[ -f "$CRON_FILE" ]] && echo "alle ${INTERVAL_MIN} min" || echo '!!! nicht installiert')"
            echo "Mail:  ${ALERT_MAIL:-(keine)}"
            echo
            list_repos
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Repositories verwalten"
        echo "2) Jetzt alle aktualisieren"
        echo "3) Einstellungen (Intervall, Benachrichtigung)"
        echo "4) Log anzeigen"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) is_setup || configure; repo_menu ;;
            2) is_setup || configure; echo; run_update verbose; echo; pause ;;
            3) configure ;;
            4) show_log ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --run)       run_update ;;
    --status)    is_setup && list_repos ;;
    --uninstall) uninstall ;;
    "")          is_setup || configure; main_menu ;;
    *)           echo "Verwendung: $0 [--run|--status|--uninstall]"; exit 1 ;;
esac
