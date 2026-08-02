#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tcp-monitor.sh - continuous TCP reachability monitoring
# Modes: (no argument) = interactive menu
#        --check       = one run over all active targets (for cron)
#        --status      = short status on stdout
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.0.1"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/tcp-monitor.conf"
CRON_FILE=/etc/cron.d/tcp-monitor

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5
RETENTION_DAYS=30
DEFAULT_TIMEOUT=5
ALERT_WEBHOOK=""
ALERT_MAIL=""

[[ -f "$CONF" ]] && . "$CONF"

TARGETS_DIR="$DATA_DIR/targets.d"
RESULTS_DIR="$DATA_DIR/results"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"
ALERT_LOG="$LOG_DIR/alerts.log"

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
# tcp-monitor configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
RETENTION_DAYS=${RETENTION_DAYS}
DEFAULT_TIMEOUT=${DEFAULT_TIMEOUT}
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
ALERT_MAIL="${ALERT_MAIL}"
EOF
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
# tcp-monitor - continuous TCP checks
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --check >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# First-time setup
# ---------------------------------------------------------------------------
setup() {
    echo ">>> First-time setup for tcp-monitor"
    echo

    read -rp "Data directory [${DATA_DIR}]: " D
    DATA_DIR=${D:-$DATA_DIR}

    read -rp "Check interval in minutes [${INTERVAL_MIN}]: " I
    INTERVAL_MIN=${I:-$INTERVAL_MIN}

    read -rp "Default timeout per connection in seconds [${DEFAULT_TIMEOUT}]: " T
    DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}

    read -rp "Retention of the samples in days [${RETENTION_DAYS}]: " R
    RETENTION_DAYS=${R:-$RETENTION_DAYS}

    read -rp "Webhook URL on a state change (empty = none): " ALERT_WEBHOOK
    read -rp "Mail address on a state change (empty = none, needs 'mail'): " ALERT_MAIL

    TARGETS_DIR="$DATA_DIR/targets.d"
    RESULTS_DIR="$DATA_DIR/results"
    STATE_DIR="$DATA_DIR/state"
    LOG_DIR="$DATA_DIR/log"
    ALERT_LOG="$LOG_DIR/alerts.log"

    make_dirs
    save_conf
    write_cron

    echo
    echo "Data directory: $DATA_DIR"
    echo "Cron:           */${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Setup complete."
    pause
}

edit_settings() {
    echo "--- Current settings ---"
    echo "Data directory:    $DATA_DIR"
    echo "Interval:          ${INTERVAL_MIN} min"
    echo "Timeout (default): ${DEFAULT_TIMEOUT}s"
    echo "Retention:         ${RETENTION_DAYS} days"
    echo "Webhook:           ${ALERT_WEBHOOK:-(none)}"
    echo "Mail:              ${ALERT_MAIL:-(none)}"
    echo

    read -rp "Interval in minutes [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}
    read -rp "Default timeout [${DEFAULT_TIMEOUT}]: " T; DEFAULT_TIMEOUT=${T:-$DEFAULT_TIMEOUT}
    read -rp "Retention in days [${RETENTION_DAYS}]: " R; RETENTION_DAYS=${R:-$RETENTION_DAYS}
    read -rp "Webhook URL [${ALERT_WEBHOOK}]: " W; ALERT_WEBHOOK=${W:-$ALERT_WEBHOOK}
    read -rp "Mail [${ALERT_MAIL}]: " M; ALERT_MAIL=${M:-$ALERT_MAIL}

    save_conf
    write_cron
    echo "Saved."
    pause
}

# ---------------------------------------------------------------------------
# Targets (CRUD)
# ---------------------------------------------------------------------------
target_file() { echo "$TARGETS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

list_targets() {
    if [[ ! -d "$TARGETS_DIR" ]] || ! ls "$TARGETS_DIR"/*.conf &>/dev/null; then
        echo "(no targets created)"
        return
    fi
    printf "%-20s %-28s %-6s %-8s %s\n" "NAME" "TARGET" "ACTIVE" "STATUS" "LAST CHECK"
    printf "%-20s %-28s %-6s %-8s %s\n" "--------------------" "----------------------------" "------" "--------" "--------------------"
    for f in "$TARGETS_DIR"/*.conf; do
        ( . "$f"
          local st ts
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              st=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
              ts=$(cut -d'|' -f2 "$STATE_DIR/${NAME}.state")
          else
              st="-"; ts="-"
          fi
          printf "%-20s %-28s %-6s %-8s %s\n" \
              "$NAME" "${HOST}:${PORT}" \
              "$([[ "$ENABLED" == "1" ]] && echo yes || echo no)" \
              "$st" "$ts"
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

    read -rp "Host/IP: " HOST
    while [[ -z "$HOST" ]]; do read -rp "  -> required: " HOST; done

    read -rp "Port: " PORT
    while [[ ! "$PORT" =~ ^[0-9]+$ ]]; do read -rp "  -> a number is expected: " PORT; done

    read -rp "Timeout in seconds [${DEFAULT_TIMEOUT}]: " TMO; TMO=${TMO:-$DEFAULT_TIMEOUT}
    read -rp "Note (optional): " NOTE

    cat > "$(target_file "$NAME")" <<EOF
NAME="${NAME}"
HOST="${HOST}"
PORT="${PORT}"
TIMEOUT="${TMO}"
ENABLED="1"
NOTE="${NOTE}"
EOF

    echo
    echo "Immediate test:"
    check_one "$(target_file "$NAME")" verbose
    pause
}

edit_target() {
    echo "--- Targets ---"; list_targets; echo
    read -rp "Name to edit: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    . "$f"
    read -rp "Host [${HOST}]: " H; H=${H:-$HOST}
    read -rp "Port [${PORT}]: " P; P=${P:-$PORT}
    read -rp "Timeout [${TIMEOUT}]: " T; T=${T:-$TIMEOUT}
    read -rp "Active (1/0) [${ENABLED}]: " E; E=${E:-$ENABLED}
    read -rp "Note [${NOTE}]: " O; O=${O:-$NOTE}

    cat > "$f" <<EOF
NAME="${NAME}"
HOST="${H}"
PORT="${P}"
TIMEOUT="${T}"
ENABLED="${E}"
NOTE="${O}"
EOF
    echo "Updated."
    pause
}

delete_target() {
    echo "--- Targets ---"; list_targets; echo
    read -rp "Name to delete: " N
    local f; f=$(target_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    read -rp "Really delete '$N'? [y/N]: " C
    if [[ "$C" =~ ^[YyJj]$ ]]; then
        rm -f "$f" "$STATE_DIR/${N}.state"
        read -rp "Delete the samples (${RESULTS_DIR}/${N}.csv) as well? [y/N]: " D
        [[ "$D" =~ ^[YyJj]$ ]] && rm -f "$RESULTS_DIR/${N}.csv"
        echo "Deleted."
    else
        echo "Cancelled."
    fi
    pause
}

target_menu() {
    while true; do
        clear
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
    local name=$1 old=$2 new=$3 detail=$4
    local msg="[tcp-monitor] ${name}: ${old} -> ${new} (${detail})"
    echo "$(date '+%F %T') ${msg}" >> "$ALERT_LOG"

    if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl &>/dev/null; then
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"text\":\"${msg}\"}" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ALERT_MAIL" ]] && command -v mail &>/dev/null; then
        echo "$msg" | mail -s "tcp-monitor: ${name} ${new}" "$ALERT_MAIL" || true
    fi
}

check_one() {
    local f=$1 verbose=${2:-}
    # shellcheck disable=SC1090
    ( . "$f"

      [[ "$ENABLED" == "1" || -n "$verbose" ]] || exit 0

      local start end ms status detail
      start=$(date +%s%N)
      if timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
          end=$(date +%s%N)
          ms=$(( (end - start) / 1000000 ))
          status="UP"; detail="${ms}ms"
      else
          end=$(date +%s%N)
          ms=$(( (end - start) / 1000000 ))
          status="DOWN"; detail="timeout/refused after ${ms}ms"
      fi

      local now; now=$(date '+%F %T')
      mkdir -p "$RESULTS_DIR" "$STATE_DIR"
      [[ -f "$RESULTS_DIR/${NAME}.csv" ]] || echo "timestamp,status,latency_ms" > "$RESULTS_DIR/${NAME}.csv"
      echo "${now},${status},${ms}" >> "$RESULTS_DIR/${NAME}.csv"

      local prev="-"
      [[ -f "$STATE_DIR/${NAME}.state" ]] && prev=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
      echo "${status}|${now}|${ms}" > "$STATE_DIR/${NAME}.state"

      if [[ "$prev" != "-" && "$prev" != "$status" ]]; then
          notify "$NAME" "$prev" "$status" "$detail"
      fi

      [[ -n "$verbose" ]] && printf "%-20s %-24s %-6s %s\n" "$NAME" "${HOST}:${PORT}" "$status" "$detail"
      exit 0
    )
}

prune_old() {
    local cutoff
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%F' 2>/dev/null) || return 0
    for f in "$RESULTS_DIR"/*.csv; do
        [[ -e "$f" ]] || continue
        awk -F, -v c="$cutoff" 'NR==1 || $1 >= c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
}

run_check() {
    is_setup || { echo "Not set up. Run the setup first." >&2; exit 1; }
    make_dirs
    for f in "$TARGETS_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        check_one "$f" "${1:-}"
    done
    prune_old
}

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

    local total up
    total=$(( $(wc -l < "$csv") - 1 ))
    up=$(grep -c ',UP,' "$csv" || true)
    echo
    echo "Samples: $total   of those UP: $up"
    if (( total > 0 )); then
        awk -F, -v t="$total" 'BEGIN{OFS=""} END{}' /dev/null
        echo "Availability:  $(awk -v u="$up" -v t="$total" 'BEGIN{printf "%.2f%%", (u/t)*100}')"
        echo "Mean latency (UP): $(awk -F, '$2=="UP"{s+=$3;n++} END{if(n)printf "%.1f ms", s/n; else print "-"}' "$csv")"
        echo "Max latency:       $(awk -F, '$2=="UP"{if($3>m)m=$3} END{if(m)printf "%d ms", m; else print "-"}' "$csv")"
    fi
    echo
    echo "--- Last 20 samples ---"
    tail -n 20 "$csv"
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall tcp-monitor"
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

    make_backup tcp-monitor "$CONF" "$DATA_DIR" || { pause; return; }

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
        clear
        echo "==========================================="
        echo " TCP monitoring"
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
        echo "4) Settings (interval, alerts, retention)"
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
