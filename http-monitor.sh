#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# http-monitor.sh - HTTP monitoring: check a URL against an expected status code
# Modes: (no argument) = interactive menu
#        --check       = one run over all active targets (for cron)
#        --status      = target list on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.2.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

# Pin the number format. Not because curl would be wrong here - it returns
# %{time_total} with a dot even under de_DE - but because the conversion to
# milliseconds goes through awk: hand awk a comma decimal and it silently
# produces 0 instead of the response time. The same goes for 'date -d' and the
# English month name in the certificate date.
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/http-monitor.conf"
CRON_FILE=/etc/cron.d/http-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
# Its own subtree under var/: tcp-monitor and disk-monitor already share var/,
# and a target carrying the same name in two modules would otherwise overwrite
# itself in targets.d/ and state/.
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

# A relative data directory would be created wherever the caller happens to
# stand - and cron stands somewhere else than you do, so state would be written
# in one place and looked for in another. Therefore: resolve against the
# script's directory, never against $PWD.
resolve_data_dir() {
    local d=${1%/}
    case "$d" in
        /*) printf '%s' "$d" ;;
        "") printf '%s' "$DIR/var/http" ;;
        .)  printf '%s' "$DIR" ;;
        *)  printf '%s' "$DIR/${d#./}" ;;
    esac
}
DATA_DIR=$(resolve_data_dir "$DATA_DIR")

TARGETS_DIR="$DATA_DIR/targets.d"
RESULTS_DIR="$DATA_DIR/results"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
ALERT_LOG="$LOG_DIR/alerts.log"
LOCK_FILE="$DATA_DIR/.lock"

# The expiry date is only fetched again every 12 hours - a TLS handshake every
# five minutes would be pure load, and the date only changes on a renewal. The
# remaining days are still recalculated on every run, so the warning threshold
# fires on the right day.
CERT_CHECK_H=12

pause() { read -rp "Press Enter to continue..." _; }

# confirm "Question" [Y]   -> default Y instead of N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

# make_backup <name> <path>...   -> <root|HOME>/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p dir
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nothing to back up)"
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
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" && -d "$TARGETS_DIR" ]]; }

save_conf() {
    cat > "$CONF" <<EOF
# http-monitor configuration
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
        echo "The cron entry needs root. Add it manually:"
        echo "*/${INTERVAL_MIN} * * * * root ${SELF} --check"
        return
    fi
    cat > "$CRON_FILE" <<EOF
# http-monitor - continuous HTTP checks
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# Shortens long URLs for the table. Unshortened, the first target with a query
# string tears the columns apart; leaving it out entirely is no good either:
# the name alone does not say what is being checked.
ellipsis() {
    local s=$1 n=$2
    (( ${#s} <= n )) && { printf '%s' "$s"; return; }
    printf '%s...' "${s:0:n-3}"
}

# Sets URL_SCHEME, URL_HOST, URL_PORT. Pure parameter expansion - this is only
# about the authority part, not a full RFC URL decomposition.
url_parts() {
    local u=$1 rest
    URL_SCHEME=${u%%://*}; [[ "$URL_SCHEME" == "$u" ]] && URL_SCHEME=http
    rest=${u#*://}
    rest=${rest%%/*}; rest=${rest%%\?*}; rest=${rest%%#*}
    rest=${rest##*@}
    if [[ "$rest" == \[* ]]; then
        # IPv6 sits in square brackets and contains colons itself.
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

# The bare number helps nobody at three in the morning.
curl_reason() {
    case "$1" in
        3)   echo "malformed URL" ;;
        5|6) echo "DNS resolution failed" ;;
        7)   echo "connection refused or host unreachable" ;;
        28)  echo "timeout after ${TIMEOUT}s" ;;
        35)  echo "TLS handshake failed" ;;
        47)  echo "too many redirects" ;;
        51)  echo "certificate name does not match the host" ;;
        52)  echo "empty reply from the server" ;;
        56)  echo "connection reset while reading" ;;
        60)  echo "certificate not trusted (chain or expiry)" ;;
        *)   echo "curl error ${1}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Targets (CRUD)
# ---------------------------------------------------------------------------
target_file() { echo "$TARGETS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

# First set all fields to their defaults, then source the target file. Two
# reasons: under 'set -u' a target file from an older version without the newer
# fields would break on first access - and without the reset a target would
# carry over the values of the previously loaded one.
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
        echo "(no targets created)"
        return
    fi
    printf "%-14s %-34s %-6s %-6s %-5s %-7s %-6s %s\n" \
        "NAME" "URL" "ACTIVE" "STATUS" "CODE" "TIME" "CERT" "LAST CHECK"
    printf "%-14s %-34s %-6s %-6s %-5s %-7s %-6s %s\n" \
        "--------------" "----------------------------------" "------" \
        "------" "-----" "-------" "------" "-------------------"
    for f in "$TARGETS_DIR"/*.conf; do
        # Subshell: this function only prints, the runner's global target
        # variables must not be overwritten in the process.
        ( load_target "$f"
          local st="-" ts="-" code="-" ms="-" band="-" cepoch=0 cert_col="-" time_col="-"
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              IFS='|' read -r st ts code ms band cepoch _ < "$STATE_DIR/${NAME}.state"
          fi
          [[ "$ms" =~ ^[0-9]+$ ]] && time_col="${ms}ms"
          if [[ "${cepoch:-0}" =~ ^[0-9]+$ ]] && (( cepoch > 0 )); then
              cert_col="$(( (cepoch - $(date +%s)) / 86400 ))d"
              [[ "$band" == "warn" || "$band" == "expired" ]] && cert_col="${cert_col}!"
          elif [[ "$band" == "unknown" ]]; then
              cert_col="?"
          fi
          printf "%-14s %-34s %-6s %-6s %-5s %-7s %-6s %s\n" \
              "$NAME" "$(ellipsis "$URL" 34)" \
              "$([[ "$ENABLED" == "1" ]] && echo yes || echo no)" \
              "${st:--}" "${code:--}" "$time_col" "$cert_col" "${ts:--}"
        )
    done
}

create_target() {
    echo "--- Existing targets ---"; list_targets; echo
    read -rp "Name: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(target_file "$NAME")" ]]; do
        echo "Invalid or already taken."
        read -rp "Name: " NAME
    done

    read -rp "URL (http:// or https://): " URL
    while [[ ! "$URL" =~ ^https?:// ]]; do read -rp "  -> a complete URL is expected: " URL; done

    read -rp "Expected HTTP code [${DEFAULT_EXPECT}]: " EXPECT
    EXPECT=${EXPECT:-$DEFAULT_EXPECT}
    while [[ ! "$EXPECT" =~ ^[1-5][0-9][0-9]$ ]]; do
        read -rp "  -> a three-digit status code is expected: " EXPECT
    done

    read -rp "Method GET/HEAD [GET]: " METHOD; METHOD=${METHOD:-GET}; METHOD=${METHOD^^}
    [[ "$METHOD" == "HEAD" ]] || METHOD="GET"

    read -rp "Timeout in seconds [${DEFAULT_TIMEOUT}]: " TIMEOUT
    TIMEOUT=${TIMEOUT:-$DEFAULT_TIMEOUT}
    read -rp "Response-time threshold in ms, 0 = off [${DEFAULT_MAX_MS}]: " MAX_MS
    MAX_MS=${MAX_MS:-$DEFAULT_MAX_MS}

    echo "Follow redirects? No means: the expected code applies to the first"
    echo "response - only that way can a 301 be monitored in its own right."
    confirm "  Follow (curl -L)?" && FOLLOW=1 || FOLLOW=0

    if [[ "$URL" == https://* ]]; then
        confirm "Switch off certificate verification (self-signed)?" && INSECURE=1 || INSECURE=0
    else
        INSECURE=0
    fi

    ENABLED=1
    read -rp "Note (optional): " NOTE

    local f; f=$(target_file "$NAME")
    write_target "$f"

    echo
    echo "Immediate test:"
    # nostate: the test run must not carry the state forward. Otherwise a target
    # that was broken from the start would count as "unchanged" on the first
    # cron run and the initial alert would never go out.
    check_one "$f" verbose nostate
    pause
}

edit_target() {
    echo "--- Targets ---"; list_targets; echo
    read -rp "Name to edit: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    load_target "$f"
    local V
    read -rp "URL [${URL}]: " V; URL=${V:-$URL}
    read -rp "Expected code [${EXPECT}]: " V; EXPECT=${V:-$EXPECT}
    read -rp "Method GET/HEAD [${METHOD}]: " V; METHOD=${V:-$METHOD}
    read -rp "Timeout [${TIMEOUT}]: " V; TIMEOUT=${V:-$TIMEOUT}
    read -rp "Response-time threshold ms, 0 = off [${MAX_MS}]: " V; MAX_MS=${V:-$MAX_MS}
    read -rp "Follow redirects (1/0) [${FOLLOW}]: " V; FOLLOW=${V:-$FOLLOW}
    read -rp "Certificate verification off (1/0) [${INSECURE}]: " V; INSECURE=${V:-$INSECURE}
    read -rp "Active (1/0) [${ENABLED}]: " V; ENABLED=${V:-$ENABLED}
    read -rp "Note [${NOTE}]: " V; NOTE=${V:-$NOTE}

    write_target "$f"
    echo "Updated."
    pause
}

delete_target() {
    echo "--- Targets ---"; list_targets; echo
    read -rp "Name to delete: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    if confirm "Really delete '$N'?"; then
        rm -f "$f" "$STATE_DIR/${N}.state"
        confirm "Delete the samples (${RESULTS_DIR}/${N}.csv) as well?" \
            && rm -f "$RESULTS_DIR/${N}.csv"
        echo "Deleted."
    else
        echo "Cancelled."
    fi
    pause
}

target_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "=== Manage targets ==="
        list_targets
        echo
        echo "1) Create a target"
        echo "2) Edit a target"
        echo "3) Delete a target"
        echo "4) Back"
        read -rp "Choice: " CH
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
# Check logic
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
                || echo "$(date '+%F %T') !!! sending mail failed" >> "$ALERT_LOG"
        else
            echo "$(date '+%F %T') !!! 'mail' missing - nothing sent" >> "$ALERT_LOG"
        fi
    fi
}

# Sets P_CODE, P_MS, P_ERR. Status code and response time come from ONE run - a
# second request for the time would measure a different response than the one
# whose code is being judged.
http_probe() {
    local -a args=(
        --silent --show-error
        --output /dev/null
        --write-out '%{http_code}|%{time_total}'
        --max-time "$TIMEOUT"
        --user-agent "http-monitor/1"
    )

    # Deliberately WITHOUT --fail: that aborts on 4xx/5xx with exit code 22 and
    # returns no status code any more - exactly the value this module is meant
    # to judge. A 500 is a measurement here, not an error.
    if [[ "$METHOD" == "HEAD" ]]; then
        # Not "-X HEAD": curl then does send HEAD, but waits for a body the
        # server never sends, and runs into the timeout.
        args+=(--head)
    fi
    [[ "$FOLLOW"   == "1" ]] && args+=(--location --max-redirs 5)
    [[ "$INSECURE" == "1" ]] && args+=(--insecure)

    local out rc t
    # </dev/null so that curl cannot under any circumstances read from standard
    # input - in menu mode that belongs to the 'read' of the menu loop.
    out=$(curl "${args[@]}" "$URL" 2>/dev/null </dev/null); rc=$?

    IFS='|' read -r P_CODE t <<<"$out"
    P_CODE=${P_CODE:-000}
    # time_total is a floating point number in seconds, bash cannot compute
    # with it. awk instead of bc, because awk is present everywhere anyway.
    P_MS=$(awk -v t="${t:-0}" 'BEGIN{printf "%d", t*1000}')

    P_ERR=""
    (( rc != 0 )) && P_ERR=$(curl_reason "$rc")
    return 0
}

# Returns the expiry as unix time on stdout, or nothing.
#
# Through openssl rather than curl: '--certinfo' is not present in every build
# (not in the curl 8.18 installed here, for example), and the date is needed
# precisely when the chain does NOT validate - with a self-signed certificate
# curl aborts beforehand, s_client still delivers it.
cert_notafter() {
    local host=$1 port=$2 tmo=$3
    command -v openssl &>/dev/null || return 1

    local raw end epoch
    # </dev/null: s_client would otherwise keep reading from standard input and
    # never finish on its own; timeout is the second safety line.
    raw=$(timeout "$tmo" openssl s_client -connect "${host}:${port}" \
              -servername "$host" </dev/null 2>/dev/null)
    [[ -n "$raw" ]] || return 1

    # First into a variable, then pipe: 'openssl x509' reads only the first
    # certificate and exits. Hung directly behind s_client it would get SIGPIPE,
    # and the pipeline status would be 141 instead of the answer we are after -
    # the same trap that once tore setup.sh's menu apart.
    end=$(printf '%s\n' "$raw" | openssl x509 -noout -enddate 2>/dev/null)
    end=${end#notAfter=}
    [[ -n "$end" ]] || return 1

    epoch=$(date -d "$end" +%s 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$epoch"
}

# Checks one target. Sets R_STATUS, R_CODE, R_MS, R_REASON, R_BAND, R_DAYS,
# PREV_STATUS, PREV_BAND as well as CERT_EPOCH/CERT_SEEN for the state line.
#
# Unlike tcp-monitor.sh this does NOT run in a subshell: the runner collects the
# messages of all targets and sends one mail per run - out of a subshell the
# array would never come back.
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

    # --- Reachability -----------------------------------------------------
    http_probe
    R_CODE=$P_CODE; R_MS=$P_MS

    if [[ -n "$P_ERR" ]]; then
        R_STATUS=DOWN; R_REASON="$P_ERR"
    elif [[ "$P_CODE" != "$EXPECT" ]]; then
        R_STATUS=DOWN; R_REASON="HTTP ${P_CODE}, expected ${EXPECT}"
    elif [[ "$MAX_MS" =~ ^[0-9]+$ ]] && (( MAX_MS > 0 && P_MS > MAX_MS )); then
        # SLOW sits on the same axis as UP and DOWN, it is not a second state
        # machine: the service answers correctly, only too slowly. Anyone who
        # first degrades and then fails should see UP -> SLOW -> DOWN.
        R_STATUS=SLOW; R_REASON="HTTP ${P_CODE}, but ${P_MS}ms > ${MAX_MS}ms"
    else
        R_STATUS=UP; R_REASON="HTTP ${P_CODE} in ${P_MS}ms"
    fi

    # --- Certificate ------------------------------------------------------
    local now_e; now_e=$(date +%s)
    url_parts "$URL"
    if [[ "$URL_SCHEME" == https ]] && (( CERT_WARN_DAYS > 0 )); then
        if (( now_e - CERT_SEEN >= CERT_CHECK_H * 3600 )); then
            local e
            if e=$(cert_notafter "$URL_HOST" "$URL_PORT" "$TIMEOUT"); then
                CERT_EPOCH=$e; CERT_SEEN=$now_e
            fi
            # If it fails, the last known date stays: an outage must not reset
            # the expiry monitoring.
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

    # --- Carry the state forward ------------------------------------------
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
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    make_dirs

    if ! command -v curl &>/dev/null; then
        echo "$(date '+%F %T') !!! curl missing - no run possible" >> "$ALERT_LOG"
        echo "curl is not installed (apt install curl)." >&2
        return 1
    fi

    # In the worst case a run takes targets x TIMEOUT seconds, because every
    # timeout is sat out one after another - that can overtake the interval.
    # If flock is missing, work goes on without a lock: better a possible
    # overlap than no run at all.
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "A run is not finished yet - skipped." >&2
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
        [[ "$R_STATUS" == "-" ]] && continue      # disabled
        [[ "$R_STATUS" != "UP" ]] && rc=1

        # A first reading in the normal state is not an incident - a target that
        # was created broken, on the other hand, very much reports.
        if [[ "$PREV_STATUS" == "-" && "$R_STATUS" == "UP" ]]; then
            :
        elif [[ "$PREV_STATUS" != "$R_STATUS" ]]; then
            if [[ "$R_STATUS" == "UP" ]]; then
                changes+=("RECOVERED ${NAME}: reachable again, ${R_REASON}")
            else
                changes+=("${R_STATUS} ${NAME} (${URL}): ${R_REASON}")
            fi
        fi

        # Second axis. An expiring certificate is not an outage - the site keeps
        # returning its code, and putting it on DOWN would simply be wrong.
        # "unknown" never fires, neither into it nor out of it: otherwise every
        # outage would additionally report the certificate, because the
        # handshake failed along with it.
        if [[ "$R_BAND" != "-" && "$R_BAND" != "unknown" && "$PREV_BAND" != "unknown" \
              && "$R_BAND" != "$PREV_BAND" ]] \
           && [[ "$PREV_BAND" != "-" || "$R_BAND" != "ok" ]]; then
            case "$R_BAND" in
                ok)      changes+=("CERTIFICATE ${NAME}: uncritical again, ${R_DAYS} days left") ;;
                expired) changes+=("CERTIFICATE ${NAME}: EXPIRED $(( -1 * R_DAYS )) day(s) ago") ;;
                warn)    changes+=("CERTIFICATE ${NAME}: expires in ${R_DAYS} days (${URL})") ;;
            esac
            rc=1
        fi
    done

    if (( ${#changes[@]} > 0 )); then
        # One collected mail per run instead of one per target: if the uplink
        # goes down, otherwise twenty mails are on their way instead of one.
        local body subject
        subject="[http-monitor] ${host}: ${changes[0]}"
        (( ${#changes[@]} > 1 )) && subject+=" (+$(( ${#changes[@]} - 1 )) more)"
        body="HTTP monitoring on ${host}"$'\n'"As of: ${now}"$'\n\n'"Changes:"$'\n'
        body+=$(printf '  - %s\n' "${changes[@]}")
        body+=$'\n\n'"Current state:"$'\n'
        body+=$(list_targets)
        notify "$subject" "$body"
        [[ -n "$verbose" ]] && { echo; printf '%s\n' "$body"; }
    elif [[ -n "$verbose" ]]; then
        echo
        echo "No state change - no mail would be sent."
    fi

    prune_old
    return $rc
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------
show_results() {
    echo "--- Targets ---"; list_targets; echo
    read -rp "Name (empty = show all alerts): " N
    if [[ -z "$N" ]]; then
        echo
        echo "--- Last state changes ---"
        tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(none)"
        pause
        return
    fi

    local csv="$RESULTS_DIR/${N}.csv"
    [[ -f "$csv" ]] || { echo "No samples."; pause; return; }

    local total up slow down
    total=$(( $(wc -l < "$csv") - 1 ))
    up=$(grep -c ',UP,'   "$csv" || true)
    slow=$(grep -c ',SLOW,' "$csv" || true)
    down=$(grep -c ',DOWN,' "$csv" || true)

    echo
    echo "Samples: $total   UP: $up   SLOW: $slow   DOWN: $down"
    if (( total > 0 )); then
        echo "Availability (UP+SLOW): $(awk -v u="$(( up + slow ))" -v t="$total" \
            'BEGIN{printf "%.2f%%", (u/t)*100}')"
        echo "Mean response time: $(awk -F, '$2=="UP"||$2=="SLOW"{s+=$4;n++} END{if(n)printf "%.1f ms", s/n; else print "-"}' "$csv")"
        echo "Max response time:  $(awk -F, '$2=="UP"||$2=="SLOW"{if($4>m)m=$4} END{if(m)printf "%d ms", m; else print "-"}' "$csv")"
        echo -n "Codes: "
        awk -F, 'NR>1{c[$3]++} END{for(k in c) printf "%s (%d)  ", k, c[k]; print ""}' "$csv"
    fi
    echo
    echo "--- Last 20 samples ---"
    tail -n 20 "$csv"
    pause
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
setup() {
    echo ">>> First-time setup for http-monitor"
    echo

    local OLD_DATA_DIR=$DATA_DIR
    echo "A relative data directory is taken relative to the script, not to"
    echo "where you are standing."
    read -rp "Data directory [${DATA_DIR}]: " D
    DATA_DIR=$(resolve_data_dir "${D:-$DATA_DIR}")
    [[ -n "$D" && "$DATA_DIR" != "$D" ]] && echo "  -> ${DATA_DIR}"

    read -rp "Check interval in minutes [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    read -rp "Default timeout per request in seconds [${DEFAULT_TIMEOUT}]: " T
    DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}

    read -rp "Default status code [${DEFAULT_EXPECT}]: " E
    DEFAULT_EXPECT=${E:-$DEFAULT_EXPECT}

    read -rp "Default response-time threshold in ms, 0 = off [${DEFAULT_MAX_MS}]: " M
    DEFAULT_MAX_MS=${M:-$DEFAULT_MAX_MS}

    read -rp "TLS warning from this many days left, 0 = off [${CERT_WARN_DAYS}]: " C
    CERT_WARN_DAYS=${C:-$CERT_WARN_DAYS}

    read -rp "Retention of the samples in days [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    read -rp "Webhook URL on a state change (empty = none): " ALERT_WEBHOOK
    read -rp "Mail address on a state change (empty = none, needs 'mail'): " ALERT_MAIL

    TARGETS_DIR="$DATA_DIR/targets.d"
    RESULTS_DIR="$DATA_DIR/results"
    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    ALERT_LOG="$LOG_DIR/alerts.log"
    LOCK_FILE="$DATA_DIR/.lock"

    # Without this the targets stay behind in the old directory and are simply
    # never read again - the overview is empty and nothing says why.
    if [[ "$DATA_DIR" != "$OLD_DATA_DIR" && -d "$OLD_DATA_DIR/targets.d" ]]; then
        echo
        echo "So far the data lives in ${OLD_DATA_DIR}."
        if confirm "Move targets, results, state and log to ${DATA_DIR}?" Y; then
            mkdir -p "$DATA_DIR"
            local sub
            for sub in targets.d results state log; do
                [[ -d "$OLD_DATA_DIR/$sub" ]] || continue
                if [[ -d "$DATA_DIR/$sub" ]]; then
                    cp -a "$OLD_DATA_DIR/$sub/." "$DATA_DIR/$sub/" && rm -rf "$OLD_DATA_DIR/$sub"
                else
                    mv "$OLD_DATA_DIR/$sub" "$DATA_DIR/$sub"
                fi
            done
            rm -f "$OLD_DATA_DIR/.lock"
            echo "Moved."
        else
            echo "Careful: the targets stay in ${OLD_DATA_DIR} and are not read any more."
        fi
    fi

    make_dirs
    save_conf
    write_cron

    command -v curl    &>/dev/null || echo "!!! curl missing - no check runs without curl."
    command -v openssl &>/dev/null || echo "!!! openssl missing - no certificate monitoring."

    echo
    echo "Data directory: $DATA_DIR"
    echo "Cron:           */${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Setup complete."
    pause
}

edit_settings() {
    echo "--- Current settings ---"
    echo "Data directory:     $DATA_DIR"
    echo "Interval:           ${INTERVAL_MIN} min"
    echo "Timeout (default):  ${DEFAULT_TIMEOUT}s"
    echo "Code (default):     ${DEFAULT_EXPECT}"
    echo "Time threshold:     ${DEFAULT_MAX_MS} ms"
    echo "TLS warning from:   ${CERT_WARN_DAYS} days"
    echo "Retention:          ${RETENTION_DAYS} days"
    echo "Webhook:            ${ALERT_WEBHOOK:-(none)}"
    echo "Mail:               ${ALERT_MAIL:-(none)}"
    echo

    local V
    read -rp "Interval in minutes [${INTERVAL_MIN}]: " V; INTERVAL_MIN=${V:-$INTERVAL_MIN}
    read -rp "Default timeout [${DEFAULT_TIMEOUT}]: " V; DEFAULT_TIMEOUT=${V:-$DEFAULT_TIMEOUT}
    read -rp "Default code [${DEFAULT_EXPECT}]: " V; DEFAULT_EXPECT=${V:-$DEFAULT_EXPECT}
    read -rp "Time threshold ms [${DEFAULT_MAX_MS}]: " V; DEFAULT_MAX_MS=${V:-$DEFAULT_MAX_MS}
    read -rp "TLS warning from days [${CERT_WARN_DAYS}]: " V; CERT_WARN_DAYS=${V:-$CERT_WARN_DAYS}
    read -rp "Retention in days [${RETENTION_DAYS}]: " V; RETENTION_DAYS=${V:-$RETENTION_DAYS}
    read -rp "Webhook URL [${ALERT_WEBHOOK}]: " V; ALERT_WEBHOOK=${V:-$ALERT_WEBHOOK}
    read -rp "Mail [${ALERT_MAIL}]: " V; ALERT_MAIL=${V:-$ALERT_MAIL}

    save_conf
    write_cron
    echo "Saved."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall http-monitor"
    echo

    local n=0
    [[ -d "$TARGETS_DIR" ]] && n=$(find "$TARGETS_DIR" -name '*.conf' 2>/dev/null | wc -l) || true

    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (every ${INTERVAL_MIN} min)" || true
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF" || true
    [[ -d "$DATA_DIR" ]]  && echo "  - data directory $DATA_DIR (${n} targets, samples, alert log)   [asked]" || true
    echo
    echo "No packages were installed, nothing is left behind."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup http-monitor "$CONF" "$DATA_DIR" || { pause; return; }

    if [[ -f "$CRON_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo "!!! Not root - please remove the cron entry manually:"
            echo "    rm -f $CRON_FILE"
        else
            rm -f "$CRON_FILE"
            echo "Cron entry removed."
        fi
    fi

    rm -f "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Delete targets and samples in $DATA_DIR as well?"; then
        rm -rf "$DATA_DIR"
        echo "Data directory deleted."
    fi

    echo
    echo "Removed."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " HTTP monitoring"
        echo "==========================================="
        if is_setup; then
            echo "Data:   $DATA_DIR"
            echo "Cron:   $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo "not installed")"
        else
            echo "Status: not set up"
        fi
        echo
        is_setup && { list_targets; echo; }
        echo "1) Manage targets"
        echo "2) Check all targets now"
        echo "3) Results / statistics"
        echo "4) Settings (interval, thresholds, alerts, retention)"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
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
    *)           echo "Usage: $0 [--check|--status|--uninstall|--version]"; exit 1 ;;
esac
