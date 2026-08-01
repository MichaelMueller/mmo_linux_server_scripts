#!/usr/bin/env bash
# http-monitor.sh - HTTP-Überwachung: URL gegen erwarteten Statuscode prüfen
# Modi:  (ohne Argument) = interaktives Menü
#        --check         = einmaliger Durchlauf aller aktiven Ziele (für cron)
#        --status        = Zielliste auf stdout
#        --uninstall     = Deinstallation
#
# Bewusst ohne 'set -e': der Runner sammelt Fehler und meldet sie am Ende.
set -uo pipefail

# Zahlenformat festnageln. Nicht, weil curl hier falsch läge - es liefert
# %{time_total} auch unter de_DE mit Punkt -, sondern weil die Umrechnung in
# Millisekunden durch awk geht: bekäme awk je ein Komma-Dezimal in die Hand,
# käme lautlos 0 statt der Antwortzeit heraus. Gilt genauso für 'date -d' und
# den englischen Monatsnamen im Zertifikatsdatum.
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/http-monitor.conf"
CRON_FILE=/etc/cron.d/http-monitor

# ---------------------------------------------------------------------------
# Konfiguration laden / Defaults
# ---------------------------------------------------------------------------
# Eigener Unterbaum unter var/: tcp-monitor und disk-monitor teilen sich bereits
# var/, und ein Ziel, das in beiden Modulen denselben Namen trägt, würde sich
# sonst in targets.d/ und state/ gegenseitig überschreiben.
DATA_DIR="$DIR/var/http"
INTERVAL_MIN=5
RETENTION_DAYS=30
DEFAULT_TIMEOUT=10
DEFAULT_EXPECT=200
DEFAULT_MAX_MS=2000
CERT_WARN_DAYS=14
ALERT_WEBHOOK=""
ALERT_MAIL=""

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

TARGETS_DIR="$DATA_DIR/targets.d"
RESULTS_DIR="$DATA_DIR/results"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
ALERT_LOG="$LOG_DIR/alerts.log"
LOCK_FILE="$DATA_DIR/.lock"

# Das Ablaufdatum wird nur alle 12 Stunden neu geholt - ein TLS-Handshake alle
# fünf Minuten wäre reine Last, das Datum ändert sich nur bei einer Erneuerung.
# Die Restlaufzeit in Tagen wird trotzdem bei jedem Lauf neu gerechnet, damit
# die Warnschwelle taggenau anschlägt.
CERT_CHECK_H=12

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

# make_backup <name> <pfad>...   -> <root|HOME>/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p dir
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then dir=/root; else dir="$HOME"; fi
    mkdir -p "$dir" 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="${dir}/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" && -d "$TARGETS_DIR" ]]; }

save_conf() {
    cat > "$CONF" <<EOF
# http-monitor Konfiguration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
RETENTION_DAYS=${RETENTION_DAYS}
DEFAULT_TIMEOUT=${DEFAULT_TIMEOUT}
DEFAULT_EXPECT=${DEFAULT_EXPECT}
DEFAULT_MAX_MS=${DEFAULT_MAX_MS}
CERT_WARN_DAYS=${CERT_WARN_DAYS}
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
ALERT_MAIL="${ALERT_MAIL}"
EOF
    chmod 644 "$CONF"
}

make_dirs() {
    mkdir -p "$TARGETS_DIR" "$RESULTS_DIR" "$STATE_DIR" "$LOG_DIR"
}

write_cron() {
    if [[ $EUID -ne 0 ]]; then
        echo "Cron-Eintrag benötigt root. Manuell eintragen:"
        echo "*/${INTERVAL_MIN} * * * * root ${SELF} --check"
        return
    fi
    cat > "$CRON_FILE" <<EOF
# http-monitor - kontinuierliche HTTP-Prüfung
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# Kürzt lange URLs für die Tabelle. Ungekürzt zerreißt das erste Ziel mit
# Query-String die Spalten, ganz weglassen geht nicht: der Name allein sagt
# nicht, was geprüft wird.
ellipsis() {
    local s=$1 n=$2
    (( ${#s} <= n )) && { printf '%s' "$s"; return; }
    printf '%s...' "${s:0:n-3}"
}

# Setzt URL_SCHEME, URL_HOST, URL_PORT. Reine Parameterexpansion - es geht nur
# um den Autoritätsteil, nicht um eine vollständige URL-Zerlegung nach RFC.
url_parts() {
    local u=$1 rest
    URL_SCHEME=${u%%://*}; [[ "$URL_SCHEME" == "$u" ]] && URL_SCHEME=http
    rest=${u#*://}
    rest=${rest%%/*}; rest=${rest%%\?*}; rest=${rest%%#*}
    rest=${rest##*@}
    if [[ "$rest" == \[* ]]; then
        # IPv6 steht in eckigen Klammern und enthält selbst Doppelpunkte.
        URL_HOST=${rest%%\]*}; URL_HOST=${URL_HOST#\[}
        URL_PORT=${rest##*\]}; URL_PORT=${URL_PORT#:}
    else
        URL_HOST=${rest%%:*}
        URL_PORT=${rest#"$URL_HOST"}; URL_PORT=${URL_PORT#:}
    fi
    if [[ -z "$URL_PORT" ]]; then
        [[ "$URL_SCHEME" == https ]] && URL_PORT=443 || URL_PORT=80
    fi
}

# Die nackte Zahl hilft um drei Uhr nachts niemandem.
curl_reason() {
    case "$1" in
        3)   echo "URL fehlerhaft" ;;
        5|6) echo "DNS-Auflösung fehlgeschlagen" ;;
        7)   echo "Verbindung abgelehnt oder Host nicht erreichbar" ;;
        28)  echo "Timeout nach ${TIMEOUT}s" ;;
        35)  echo "TLS-Handshake fehlgeschlagen" ;;
        47)  echo "zu viele Weiterleitungen" ;;
        51)  echo "Zertifikatsname passt nicht zum Host" ;;
        52)  echo "leere Antwort vom Server" ;;
        56)  echo "Verbindungsabbruch beim Lesen" ;;
        60)  echo "Zertifikat nicht vertrauenswürdig (Kette oder Ablauf)" ;;
        *)   echo "curl-Fehler ${1}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Ziele (CRUD)
# ---------------------------------------------------------------------------
target_file() { echo "$TARGETS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

# Erst alle Felder auf die Defaults setzen, dann die Zieldatei sourcen. Zwei
# Gründe: unter 'set -u' bräche eine Zieldatei aus einer älteren Version ohne
# die neueren Felder beim ersten Zugriff ab - und ohne das Zurücksetzen
# schleppte ein Ziel die Werte des vorher geladenen mit sich herum.
load_target() {
    NAME=""; URL=""; EXPECT="$DEFAULT_EXPECT"; METHOD="GET"
    TIMEOUT="$DEFAULT_TIMEOUT"; MAX_MS="$DEFAULT_MAX_MS"
    FOLLOW="0"; INSECURE="0"; ENABLED="1"; NOTE=""
    # shellcheck disable=SC1090
    . "$1"
}

write_target() {
    local f=$1
    cat > "$f" <<EOF
NAME="${NAME}"
URL="${URL}"
EXPECT="${EXPECT}"
METHOD="${METHOD}"
TIMEOUT="${TIMEOUT}"
MAX_MS="${MAX_MS}"
FOLLOW="${FOLLOW}"
INSECURE="${INSECURE}"
ENABLED="${ENABLED}"
NOTE="${NOTE}"
EOF
}

list_targets() {
    if [[ ! -d "$TARGETS_DIR" ]] || ! ls "$TARGETS_DIR"/*.conf &>/dev/null; then
        echo "(keine Ziele angelegt)"
        return
    fi
    printf "%-14s %-34s %-5s %-6s %-5s %-7s %-6s %s\n" \
        "NAME" "URL" "AKTIV" "STATUS" "CODE" "ZEIT" "ZERT" "LETZTE PRÜFUNG"
    printf "%-14s %-34s %-5s %-6s %-5s %-7s %-6s %s\n" \
        "--------------" "----------------------------------" "-----" \
        "------" "-----" "-------" "------" "-------------------"
    for f in "$TARGETS_DIR"/*.conf; do
        # Subshell: diese Funktion druckt nur, die globalen Ziel-Variablen des
        # Runners dürfen dabei nicht überschrieben werden.
        ( load_target "$f"
          local st="-" ts="-" code="-" ms="-" band="-" cepoch=0 zert="-" zeit="-"
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              IFS='|' read -r st ts code ms band cepoch _ < "$STATE_DIR/${NAME}.state"
          fi
          [[ "$ms" =~ ^[0-9]+$ ]] && zeit="${ms}ms"
          if [[ "${cepoch:-0}" =~ ^[0-9]+$ ]] && (( cepoch > 0 )); then
              zert="$(( (cepoch - $(date +%s)) / 86400 ))d"
              [[ "$band" == "warn" || "$band" == "expired" ]] && zert="${zert}!"
          elif [[ "$band" == "unknown" ]]; then
              zert="?"
          fi
          printf "%-14s %-34s %-5s %-6s %-5s %-7s %-6s %s\n" \
              "$NAME" "$(ellipsis "$URL" 34)" \
              "$([[ "$ENABLED" == "1" ]] && echo ja || echo nein)" \
              "${st:--}" "${code:--}" "$zeit" "$zert" "${ts:--}"
        )
    done
}

create_target() {
    echo "--- Vorhandene Ziele ---"; list_targets; echo
    read -rp "Name: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(target_file "$NAME")" ]]; do
        echo "Ungültig oder bereits vergeben."
        read -rp "Name: " NAME
    done

    read -rp "URL (http:// oder https://): " URL
    while [[ ! "$URL" =~ ^https?:// ]]; do read -rp "  -> vollständige URL erwartet: " URL; done

    read -rp "Erwarteter HTTP-Code [${DEFAULT_EXPECT}]: " EXPECT
    EXPECT=${EXPECT:-$DEFAULT_EXPECT}
    while [[ ! "$EXPECT" =~ ^[1-5][0-9][0-9]$ ]]; do
        read -rp "  -> dreistelliger Statuscode erwartet: " EXPECT
    done

    read -rp "Methode GET/HEAD [GET]: " METHOD; METHOD=${METHOD:-GET}; METHOD=${METHOD^^}
    [[ "$METHOD" == "HEAD" ]] || METHOD="GET"

    read -rp "Timeout in Sekunden [${DEFAULT_TIMEOUT}]: " TIMEOUT
    TIMEOUT=${TIMEOUT:-$DEFAULT_TIMEOUT}
    read -rp "Antwortzeit-Schwelle in ms, 0 = aus [${DEFAULT_MAX_MS}]: " MAX_MS
    MAX_MS=${MAX_MS:-$DEFAULT_MAX_MS}

    echo "Weiterleitungen folgen? Nein heißt: der erwartete Code gilt für die"
    echo "erste Antwort - nur so lässt sich ein 301 selbst überwachen."
    confirm "  Folgen (curl -L)?" && FOLLOW=1 || FOLLOW=0

    if [[ "$URL" == https://* ]]; then
        confirm "Zertifikatsprüfung abschalten (selbstsigniert)?" && INSECURE=1 || INSECURE=0
    else
        INSECURE=0
    fi

    ENABLED=1
    read -rp "Notiz (optional): " NOTE

    local f; f=$(target_file "$NAME")
    write_target "$f"

    echo
    echo "Sofort-Test:"
    # nostate: der Testlauf darf den Zustand nicht fortschreiben. Sonst gälte
    # ein von Anfang an kaputtes Ziel beim ersten Cron-Lauf als "unverändert"
    # und die Erstmeldung fiele aus.
    check_one "$f" verbose nostate
    pause
}

edit_target() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name zum Bearbeiten: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    load_target "$f"
    local V
    read -rp "URL [${URL}]: " V; URL=${V:-$URL}
    read -rp "Erwarteter Code [${EXPECT}]: " V; EXPECT=${V:-$EXPECT}
    read -rp "Methode GET/HEAD [${METHOD}]: " V; METHOD=${V:-$METHOD}
    read -rp "Timeout [${TIMEOUT}]: " V; TIMEOUT=${V:-$TIMEOUT}
    read -rp "Antwortzeit-Schwelle ms, 0 = aus [${MAX_MS}]: " V; MAX_MS=${V:-$MAX_MS}
    read -rp "Weiterleitungen folgen (1/0) [${FOLLOW}]: " V; FOLLOW=${V:-$FOLLOW}
    read -rp "Zertifikatsprüfung aus (1/0) [${INSECURE}]: " V; INSECURE=${V:-$INSECURE}
    read -rp "Aktiv (1/0) [${ENABLED}]: " V; ENABLED=${V:-$ENABLED}
    read -rp "Notiz [${NOTE}]: " V; NOTE=${V:-$NOTE}

    write_target "$f"
    echo "Aktualisiert."
    pause
}

delete_target() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name zum Löschen: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Nicht gefunden."; pause; return; }

    if confirm "'$N' wirklich löschen?"; then
        rm -f "$f" "$STATE_DIR/${N}.state"
        confirm "Auch Messdaten (${RESULTS_DIR}/${N}.csv) löschen?" \
            && rm -f "$RESULTS_DIR/${N}.csv"
        echo "Gelöscht."
    else
        echo "Abgebrochen."
    fi
    pause
}

target_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "=== Ziele verwalten ==="
        list_targets
        echo
        echo "1) Ziel erstellen"
        echo "2) Ziel bearbeiten"
        echo "3) Ziel löschen"
        echo "4) Zurück"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) create_target ;;
            2) edit_target ;;
            3) delete_target ;;
            4) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Prüflogik
# ---------------------------------------------------------------------------
notify() {
    local subject=$1 body=$2
    echo "$(date '+%F %T') ${subject}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":$(printf '%s' "$subject" | sed 's/"/\\"/g; s/^/"/; s/$/"/')}" \
            "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
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

# Setzt P_CODE, P_MS, P_ERR. Statuscode und Antwortzeit kommen aus EINEM Lauf -
# eine zweite Anfrage für die Zeit würde eine andere Antwort messen als die,
# deren Code bewertet wird.
http_probe() {
    local -a args=(
        --silent --show-error
        --output /dev/null
        --write-out '%{http_code}|%{time_total}'
        --max-time "$TIMEOUT"
        --user-agent "http-monitor/1"
    )

    # Bewusst OHNE --fail: das bricht bei 4xx/5xx mit Exitcode 22 ab und liefert
    # keinen Statuscode mehr - genau den Wert, den dieses Modul bewerten soll.
    # Ein 500 ist hier ein Messwert, kein Fehler.
    if [[ "$METHOD" == "HEAD" ]]; then
        # Nicht "-X HEAD": curl schickt dann zwar HEAD, wartet aber auf einen
        # Body, den der Server nie sendet, und läuft in den Timeout.
        args+=(--head)
    fi
    [[ "$FOLLOW"   == "1" ]] && args+=(--location --max-redirs 5)
    [[ "$INSECURE" == "1" ]] && args+=(--insecure)

    local out rc t
    # </dev/null, damit curl unter keinen Umständen an der Standardeingabe
    # zieht - die gehört im Menübetrieb dem 'read' der Menüschleife.
    out=$(curl "${args[@]}" "$URL" 2>/dev/null </dev/null); rc=$?

    IFS='|' read -r P_CODE t <<<"$out"
    P_CODE=${P_CODE:-000}
    # time_total ist eine Fließkommazahl in Sekunden, bash kann damit nicht
    # rechnen. awk statt bc, weil awk ohnehin überall vorhanden ist.
    P_MS=$(awk -v t="${t:-0}" 'BEGIN{printf "%d", t*1000}')

    P_ERR=""
    (( rc != 0 )) && P_ERR=$(curl_reason "$rc")
    return 0
}

# Liefert den Ablaufzeitpunkt als Unix-Zeit auf stdout, oder nichts.
#
# Über openssl statt curl: '--certinfo' ist nicht in jedem Build vorhanden (im
# hier installierten curl 8.18 zum Beispiel nicht), und das Datum wird gerade
# dann gebraucht, wenn die Kette NICHT validiert - bei einem selbstsignierten
# Zertifikat bricht curl vorher ab, s_client liefert es trotzdem.
cert_notafter() {
    local host=$1 port=$2 tmo=$3
    command -v openssl &>/dev/null || return 1

    local raw end epoch
    # </dev/null: s_client läse sonst weiter von der Standardeingabe und käme
    # nicht von selbst zum Ende; timeout ist die zweite Reißleine.
    raw=$(timeout "$tmo" openssl s_client -connect "${host}:${port}" \
              -servername "$host" </dev/null 2>/dev/null)
    [[ -n "$raw" ]] || return 1

    # Erst in eine Variable, dann pipen: 'openssl x509' liest nur das erste
    # Zertifikat und beendet sich. Direkt hinter s_client gehängt bekäme der
    # SIGPIPE, und der Pipeline-Status wäre 141 statt der Aussage, um die es
    # geht - derselbe Fallstrick, der in setup.sh das Menü zerlegt hat.
    end=$(printf '%s\n' "$raw" | openssl x509 -noout -enddate 2>/dev/null)
    end=${end#notAfter=}
    [[ -n "$end" ]] || return 1

    epoch=$(date -d "$end" +%s 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$epoch"
}

# Prüft ein Ziel. Setzt R_STATUS, R_CODE, R_MS, R_REASON, R_BAND, R_DAYS,
# PREV_STATUS, PREV_BAND sowie CERT_EPOCH/CERT_SEEN für die State-Zeile.
#
# Anders als tcp-monitor.sh:302 läuft das NICHT in einer Subshell: der Runner
# sammelt die Meldungen aller Ziele ein und verschickt eine Mail pro Lauf - aus
# einer Subshell käme das Array nicht zurück.
check_one() {
    local f=$1 verbose=${2:-} nostate=${3:-}
    load_target "$f"

    R_STATUS="-"; R_CODE="-"; R_MS="-"; R_REASON=""; R_BAND="-"; R_DAYS="-"
    PREV_STATUS="-"; PREV_BAND="-"; CERT_EPOCH=0; CERT_SEEN=0

    [[ "$ENABLED" == "1" || -n "$verbose" ]] || return 0

    local sf="$STATE_DIR/${NAME}.state"
    if [[ -f "$sf" ]]; then
        IFS='|' read -r PREV_STATUS _ _ _ PREV_BAND CERT_EPOCH CERT_SEEN < "$sf"
        PREV_STATUS=${PREV_STATUS:--}; PREV_BAND=${PREV_BAND:--}
        [[ "${CERT_EPOCH:-}" =~ ^[0-9]+$ ]] || CERT_EPOCH=0
        [[ "${CERT_SEEN:-}"  =~ ^[0-9]+$ ]] || CERT_SEEN=0
    fi

    # --- Erreichbarkeit ---------------------------------------------------
    http_probe
    R_CODE=$P_CODE; R_MS=$P_MS

    if [[ -n "$P_ERR" ]]; then
        R_STATUS=DOWN; R_REASON="$P_ERR"
    elif [[ "$P_CODE" != "$EXPECT" ]]; then
        R_STATUS=DOWN; R_REASON="HTTP ${P_CODE}, erwartet ${EXPECT}"
    elif [[ "$MAX_MS" =~ ^[0-9]+$ ]] && (( MAX_MS > 0 && P_MS > MAX_MS )); then
        # SLOW liegt auf derselben Achse wie UP und DOWN, es ist keine zweite
        # Zustandsmaschine: der Dienst antwortet korrekt, nur zu langsam. Wer
        # erst degradiert und dann ausfällt, soll UP -> SLOW -> DOWN sehen.
        R_STATUS=SLOW; R_REASON="HTTP ${P_CODE}, aber ${P_MS}ms > ${MAX_MS}ms"
    else
        R_STATUS=UP; R_REASON="HTTP ${P_CODE} in ${P_MS}ms"
    fi

    # --- Zertifikat -------------------------------------------------------
    local now_e; now_e=$(date +%s)
    url_parts "$URL"
    if [[ "$URL_SCHEME" == https ]] && (( CERT_WARN_DAYS > 0 )); then
        if (( now_e - CERT_SEEN >= CERT_CHECK_H * 3600 )); then
            local e
            if e=$(cert_notafter "$URL_HOST" "$URL_PORT" "$TIMEOUT"); then
                CERT_EPOCH=$e; CERT_SEEN=$now_e
            fi
            # Schlägt es fehl, bleibt das zuletzt bekannte Datum stehen: ein
            # Ausfall darf die Ablaufüberwachung nicht zurücksetzen.
        fi
        if (( CERT_EPOCH > 0 )); then
            R_DAYS=$(( (CERT_EPOCH - now_e) / 86400 ))
            if   (( R_DAYS <= 0 ));               then R_BAND=expired
            elif (( R_DAYS <= CERT_WARN_DAYS ));  then R_BAND=warn
            else                                       R_BAND=ok
            fi
        else
            R_BAND=unknown
        fi
    fi

    # --- Fortschreiben ----------------------------------------------------
    if [[ -z "$nostate" ]]; then
        local now; now=$(date '+%F %T')
        [[ -f "$RESULTS_DIR/${NAME}.csv" ]] || \
            echo "timestamp,status,http_code,latency_ms,cert_days" > "$RESULTS_DIR/${NAME}.csv"
        printf '%s,%s,%s,%s,%s\n' "$now" "$R_STATUS" "$R_CODE" "$R_MS" "$R_DAYS" \
            >> "$RESULTS_DIR/${NAME}.csv"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$R_STATUS" "$now" "$R_CODE" "$R_MS" \
            "$R_BAND" "$CERT_EPOCH" "$CERT_SEEN" > "$sf"
    fi

    if [[ -n "$verbose" ]]; then
        printf '%-14s %-34s %-6s %s\n' \
            "$NAME" "$(ellipsis "$URL" 34)" "$R_STATUS" "$R_REASON"
    fi
    return 0
}

prune_old() {
    local cutoff f
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    for f in "$RESULTS_DIR"/*.csv; do
        [[ -e "$f" ]] || continue
        awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
}

run_check() {
    local verbose=${1:-}
    is_setup || { echo "Nicht eingerichtet. Erst Setup ausführen." >&2; return 1; }
    make_dirs

    if ! command -v curl &>/dev/null; then
        echo "$(date '+%F %T') !!! curl fehlt - Lauf nicht möglich" >> "$ALERT_LOG"
        echo "curl ist nicht installiert (apt install curl)." >&2
        return 1
    fi

    # Ein Lauf braucht im schlimmsten Fall Ziele x TIMEOUT Sekunden, weil jeder
    # Timeout nacheinander abgesessen wird - das kann das Intervall überholen.
    # Fehlt flock, wird ohne Sperre gearbeitet: lieber ein möglicher Überlapp
    # als gar kein Lauf.
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "Ein Lauf ist noch nicht fertig - übersprungen." >&2
            return 0
        fi
    fi

    local host now f rc=0
    host=$(hostname -f 2>/dev/null || hostname)
    now=$(date '+%F %T')
    local -a changes=()

    for f in "$TARGETS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        check_one "$f" "$verbose"
        [[ "$R_STATUS" == "-" ]] && continue      # deaktiviert
        [[ "$R_STATUS" != "UP" ]] && rc=1

        # Erstaufnahme im Normalzustand ist kein Vorfall - ein Ziel, das schon
        # kaputt angelegt wurde, meldet dagegen sehr wohl.
        if [[ "$PREV_STATUS" == "-" && "$R_STATUS" == "UP" ]]; then
            :
        elif [[ "$PREV_STATUS" != "$R_STATUS" ]]; then
            if [[ "$R_STATUS" == "UP" ]]; then
                changes+=("ENTWARNUNG ${NAME}: wieder erreichbar, ${R_REASON}")
            else
                changes+=("${R_STATUS} ${NAME} (${URL}): ${R_REASON}")
            fi
        fi

        # Zweite Achse. Ein ablaufendes Zertifikat ist kein Ausfall - die Seite
        # liefert weiter ihren Code, sie auf DOWN zu setzen wäre schlicht
        # falsch. "unknown" löst nie aus, weder hinein noch heraus: sonst
        # meldete jeder Ausfall zusätzlich das Zertifikat, weil der Handshake
        # mit ausgefallen ist.
        if [[ "$R_BAND" != "-" && "$R_BAND" != "unknown" && "$PREV_BAND" != "unknown" \
              && "$R_BAND" != "$PREV_BAND" ]] \
           && [[ "$PREV_BAND" != "-" || "$R_BAND" != "ok" ]]; then
            case "$R_BAND" in
                ok)      changes+=("ZERTIFIKAT ${NAME}: wieder unkritisch, noch ${R_DAYS} Tage") ;;
                expired) changes+=("ZERTIFIKAT ${NAME}: ABGELAUFEN seit $(( -1 * R_DAYS )) Tag(en)") ;;
                warn)    changes+=("ZERTIFIKAT ${NAME}: läuft in ${R_DAYS} Tagen ab (${URL})") ;;
            esac
            rc=1
        fi
    done

    if (( ${#changes[@]} > 0 )); then
        # Eine Sammelmail pro Lauf statt einer pro Ziel: fällt der Uplink aus,
        # sind sonst zwanzig Mails unterwegs statt einer.
        local body subject
        subject="[http-monitor] ${host}: ${changes[0]}"
        (( ${#changes[@]} > 1 )) && subject+=" (+$(( ${#changes[@]} - 1 )) weitere)"
        body="HTTP-Überwachung auf ${host}"$'\n'"Stand: ${now}"$'\n\n'"Änderungen:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Aktueller Stand:"$'\n'
        body+=$(list_targets)
        notify "$subject" "$body"
        [[ -n "$verbose" ]] && { echo; printf '%s\n' "$body"; }
    elif [[ -n "$verbose" ]]; then
        echo
        echo "Keine Zustandsänderung - es würde keine Mail verschickt."
    fi

    prune_old
    return $rc
}

# ---------------------------------------------------------------------------
# Anzeige
# ---------------------------------------------------------------------------
show_results() {
    echo "--- Ziele ---"; list_targets; echo
    read -rp "Name (leer = alle Alerts anzeigen): " N
    if [[ -z "$N" ]]; then
        echo
        echo "--- Letzte Statuswechsel ---"
        tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(keine)"
        pause
        return
    fi

    local csv="$RESULTS_DIR/${N}.csv"
    [[ -f "$csv" ]] || { echo "Keine Messdaten."; pause; return; }

    local total up slow down
    total=$(( $(wc -l < "$csv") - 1 ))
    up=$(grep -c ',UP,'   "$csv" || true)
    slow=$(grep -c ',SLOW,' "$csv" || true)
    down=$(grep -c ',DOWN,' "$csv" || true)

    echo
    echo "Messungen: $total   UP: $up   SLOW: $slow   DOWN: $down"
    if (( total > 0 )); then
        echo "Verfügbarkeit (UP+SLOW): $(awk -v u="$(( up + slow ))" -v t="$total" \
            'BEGIN{printf "%.2f%%", (u/t)*100}')"
        echo "Ø Antwortzeit:  $(awk -F, '$2=="UP"||$2=="SLOW"{s+=$4;n++} END{if(n)printf "%.1f ms", s/n; else print "-"}' "$csv")"
        echo "Max Antwortzeit: $(awk -F, '$2=="UP"||$2=="SLOW"{if($4>m)m=$4} END{if(m)printf "%d ms", m; else print "-"}' "$csv")"
        echo -n "Codes: "
        awk -F, 'NR>1{c[$3]++} END{for(k in c) printf "%s (%d)  ", k, c[k]; print ""}' "$csv"
    fi
    echo
    echo "--- Letzte 20 Messungen ---"
    tail -n 20 "$csv"
    pause
}

# ---------------------------------------------------------------------------
# Einrichtung
# ---------------------------------------------------------------------------
setup() {
    echo ">>> Ersteinrichtung http-monitor"
    echo

    read -rp "Datenverzeichnis [${DATA_DIR}]: " D
    DATA_DIR=${D:-$DATA_DIR}

    read -rp "Prüfintervall in Minuten [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    read -rp "Standard-Timeout pro Anfrage in Sekunden [${DEFAULT_TIMEOUT}]: " T
    DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}

    read -rp "Standard-Statuscode [${DEFAULT_EXPECT}]: " E
    DEFAULT_EXPECT=${E:-$DEFAULT_EXPECT}

    read -rp "Standard-Antwortzeitschwelle in ms, 0 = aus [${DEFAULT_MAX_MS}]: " M
    DEFAULT_MAX_MS=${M:-$DEFAULT_MAX_MS}

    read -rp "TLS-Warnung ab Resttagen, 0 = aus [${CERT_WARN_DAYS}]: " C
    CERT_WARN_DAYS=${C:-$CERT_WARN_DAYS}

    read -rp "Aufbewahrung der Messdaten in Tagen [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    read -rp "Webhook-URL bei Zustandswechsel (leer = keine): " ALERT_WEBHOOK
    read -rp "E-Mail-Adresse bei Zustandswechsel (leer = keine, benötigt 'mail'): " ALERT_MAIL

    TARGETS_DIR="$DATA_DIR/targets.d"
    RESULTS_DIR="$DATA_DIR/results"
    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    ALERT_LOG="$LOG_DIR/alerts.log"
    LOCK_FILE="$DATA_DIR/.lock"

    make_dirs
    save_conf
    write_cron

    command -v curl    &>/dev/null || echo "!!! curl fehlt - ohne curl läuft keine Prüfung."
    command -v openssl &>/dev/null || echo "!!! openssl fehlt - keine Zertifikatsüberwachung."

    echo
    echo "Datenverzeichnis: $DATA_DIR"
    echo "Cron:             */${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Einrichtung abgeschlossen."
    pause
}

edit_settings() {
    echo "--- Aktuelle Einstellungen ---"
    echo "Datenverzeichnis:   $DATA_DIR"
    echo "Intervall:          ${INTERVAL_MIN} min"
    echo "Timeout (default):  ${DEFAULT_TIMEOUT}s"
    echo "Code (default):     ${DEFAULT_EXPECT}"
    echo "Zeitschwelle:       ${DEFAULT_MAX_MS} ms"
    echo "TLS-Warnung ab:     ${CERT_WARN_DAYS} Tagen"
    echo "Aufbewahrung:       ${RETENTION_DAYS} Tage"
    echo "Webhook:            ${ALERT_WEBHOOK:-(keiner)}"
    echo "E-Mail:             ${ALERT_MAIL:-(keine)}"
    echo

    local V
    read -rp "Intervall in Minuten [${INTERVAL_MIN}]: " V; INTERVAL_MIN=${V:-$INTERVAL_MIN}
    read -rp "Standard-Timeout [${DEFAULT_TIMEOUT}]: " V; DEFAULT_TIMEOUT=${V:-$DEFAULT_TIMEOUT}
    read -rp "Standard-Code [${DEFAULT_EXPECT}]: " V; DEFAULT_EXPECT=${V:-$DEFAULT_EXPECT}
    read -rp "Zeitschwelle ms [${DEFAULT_MAX_MS}]: " V; DEFAULT_MAX_MS=${V:-$DEFAULT_MAX_MS}
    read -rp "TLS-Warnung ab Tagen [${CERT_WARN_DAYS}]: " V; CERT_WARN_DAYS=${V:-$CERT_WARN_DAYS}
    read -rp "Aufbewahrung Tage [${RETENTION_DAYS}]: " V; RETENTION_DAYS=${V:-$RETENTION_DAYS}
    read -rp "Webhook-URL [${ALERT_WEBHOOK}]: " V; ALERT_WEBHOOK=${V:-$ALERT_WEBHOOK}
    read -rp "E-Mail [${ALERT_MAIL}]: " V; ALERT_MAIL=${V:-$ALERT_MAIL}

    save_conf
    write_cron
    echo "Gespeichert."
    pause
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation http-monitor"
    echo

    local n=0
    [[ -d "$TARGETS_DIR" ]] && n=$(find "$TARGETS_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "Folgendes wird entfernt:"
    [[ -f "$CRON_FILE" ]] && echo "  - Cron-Eintrag $CRON_FILE (alle ${INTERVAL_MIN} min)" || true
    [[ -f "$CONF" ]]      && echo "  - Konfiguration $CONF" || true
    [[ -d "$DATA_DIR" ]]  && echo "  - Datenverzeichnis $DATA_DIR (${n} Ziele, Messdaten, Alert-Log)   [Rückfrage]" || true
    echo
    echo "Es wurden keine Pakete installiert, es bleibt nichts zurück."
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup http-monitor "$CONF" "$DATA_DIR" || { pause; return; }

    if [[ -f "$CRON_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo "!!! Kein root - Cron-Eintrag bitte manuell entfernen:"
            echo "    rm -f $CRON_FILE"
        else
            rm -f "$CRON_FILE"
            echo "Cron-Eintrag entfernt."
        fi
    fi

    rm -f "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Ziele und Messdaten in $DATA_DIR ebenfalls löschen?"; then
        rm -rf "$DATA_DIR"
        echo "Datenverzeichnis gelöscht."
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
        clear 2>/dev/null || true
        echo "==========================================="
        echo " HTTP-Monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Daten:  $DATA_DIR"
            echo "Cron:   $([[ -f "$CRON_FILE" ]] && echo "alle ${INTERVAL_MIN} min" || echo "nicht installiert")"
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        is_setup && { list_targets; echo; }
        echo "1) Ziele verwalten"
        echo "2) Jetzt alle Ziele prüfen"
        echo "3) Ergebnisse / Statistik"
        echo "4) Einstellungen (Intervall, Schwellen, Alerts, Aufbewahrung)"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) is_setup || setup; target_menu ;;
            2) is_setup || setup; echo; run_check verbose; echo; pause ;;
            3) is_setup || setup; show_results ;;
            4) is_setup || setup; edit_settings ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --check)     run_check ;;
    --status)    is_setup && list_targets ;;
    --uninstall) uninstall ;;
    "")          is_setup || setup; main_menu ;;
    *)           echo "Verwendung: $0 [--check|--status|--uninstall]"; exit 1 ;;
esac
