#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# git-updater.sh - keep git working copies up to date via cron
# Modes: (no argument) = interactive menu
#        --run         = one run over all repos (for cron)
#        --status      = short status on stdout
#        --uninstall   = uninstall
#
# Deliberately without 'set -e': the runner collects errors and reports them at
# the end instead of aborting on the first broken repo.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/git-updater.conf"
CRON_FILE=/etc/cron.d/git-updater

# ---------------------------------------------------------------------------
# Load the configuration / defaults
# ---------------------------------------------------------------------------
DATA_DIR="$DIR/var"
INTERVAL_MIN=5
TIMEOUT=120              # seconds per git call
COMPOSE_TIMEOUT=900      # seconds per docker compose deployment (builds take time)
RETENTION_DAYS=30
MAIL_ON_UPDATE=1         # mail when new commits were fetched
MAIL_ON_ERROR=1          # mail when a repo could not be updated
MAIL_ON_NOOP=0           # mail even when there was nothing to do
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

pause() { read -rp "Press Enter to continue..." _; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

make_backup() {
    local name=$1; shift
    local ts tgz p dir
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nothing to back up)"; return 0; fi
    if [[ $EUID -eq 0 ]]; then dir=/root; else dir="$HOME"; fi
    mkdir -p "$dir" 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="${dir}/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

is_setup() { [[ -f "$CONF" && -d "$REPOS_DIR" ]]; }

make_dirs() { mkdir -p "$REPOS_DIR" "$STATE_DIR" "$LOG_DIR"; }

save_conf() {
    cat > "$CONF" <<EOF
# git-updater configuration
DATA_DIR="${DATA_DIR}"
INTERVAL_MIN=${INTERVAL_MIN}
TIMEOUT=${TIMEOUT}
COMPOSE_TIMEOUT=${COMPOSE_TIMEOUT}
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
        echo "The cron entry needs root. Add it manually:"
        echo "*/${INTERVAL_MIN} * * * * root ${SELF} --run"
        return
    fi
    cat > "$CRON_FILE" <<EOF
# git-updater - keeps working copies up to date
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${INTERVAL_MIN} * * * * root ${SELF} --run >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ---------------------------------------------------------------------------
# Calling git on behalf of the owner
# ---------------------------------------------------------------------------
# A repo rarely belongs to root. If git runs as the owner, that account's SSH
# keys and credential helpers apply, and git's protection against foreign
# directories ("detected dubious ownership") never kicks in at all.
#
# BatchMode/GIT_TERMINAL_PROMPT are mandatory: a cron run waiting for a
# passphrase or a host key confirmation would otherwise hang until the timeout,
# and again the next time.
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
# Running commands inside the repo
# ---------------------------------------------------------------------------
# Like gitrun as the configured user, but for arbitrary commands: POST_CMD and
# the compose deployment. Sets CMD_OUT, returns the exit code.
run_in_dir() {
    local u=$1 p=$2 tmo=$3 cmd=$4 rc=0
    if [[ "$u" == "$(id -un)" ]]; then
        CMD_OUT=$(cd "$p" && timeout "$tmo" bash -c "$cmd" 2>&1) || rc=$?
    else
        CMD_OUT=$(sudo -n -u "$u" bash -c \
            "cd $(printf %q "$p") && timeout $tmo bash -c $(printf %q "$cmd")" 2>&1) || rc=$?
    fi
    (( rc == 124 )) && CMD_OUT="timed out after ${tmo}s"
    return $rc
}

# Builds the deployment command. The compose frontend is picked at runtime and
# in the user's name: depending on the installation the CLI plugin lives under
# /usr/libexec or in ~/.docker/cli-plugins, which could not reliably be
# determined from here.
compose_script() {
    local pull=$1 build=$2 s
    s='if docker compose version >/dev/null 2>&1; then dc() { docker compose "$@"; }; '
    s+='elif command -v docker-compose >/dev/null 2>&1; then dc() { docker-compose "$@"; }; '
    s+='else echo "neither \"docker compose\" nor \"docker-compose\" found" >&2; exit 127; fi; '
    # pull before up: with externally built images an unreachable registry
    # should show up before containers are replaced.
    [[ "$pull" == "1" ]] && s+='dc pull && '
    if [[ "$build" == "1" ]]; then s+='dc up -d --build'; else s+='dc up -d'; fi
    printf '%s' "$s"
}

# Short form for the overview: -, up, build, pull+up, pull+build
compose_label() {
    local on=${1:-0} pull=${2:-0} build=${3:-0}
    [[ "$on" != "1" ]] && { echo "-"; return; }
    local l=""
    [[ "$pull" == "1" ]] && l="pull+"
    if [[ "$build" == "1" ]]; then echo "${l}build"; else echo "${l}up"; fi
}

# Is there a compose file in the directory? Only decides the prompt's default.
compose_file_here() {
    local d=$1 f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [[ -f "$d/$f" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Repos (CRUD)
# ---------------------------------------------------------------------------
repo_file() { echo "$REPOS_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9._-' '_').conf"; }

list_repos() {
    if [[ ! -d "$REPOS_DIR" ]] || ! ls "$REPOS_DIR"/*.conf &>/dev/null; then
        echo "(no repositories registered)"
        return
    fi
    printf "%-16s %-30s %-12s %-9s %-10s %-7s %s\n" \
        "NAME" "DIRECTORY" "BRANCH" "USER" "COMPOSE" "ACTIVE" "STATE"
    printf "%-16s %-30s %-12s %-9s %-10s %-7s %s\n" \
        "----------------" "------------------------------" "------------" \
        "---------" "----------" "-------" "--------------------"
    local f
    for f in "$REPOS_DIR"/*.conf; do
        # Clear the fields first: otherwise an old entry without the compose
        # lines shows the values of the previously read entry.
        ( NAME=""; REPO_PATH=""; BRANCH=""; RUN_USER=""; ENABLED=""
          COMPOSE=0; COMPOSE_PULL=0; COMPOSE_BUILD=0
          . "$f"
          local st="-" ts="-"
          if [[ -f "$STATE_DIR/${NAME}.state" ]]; then
              st=$(cut -d'|' -f1 "$STATE_DIR/${NAME}.state")
              ts=$(cut -d'|' -f2 "$STATE_DIR/${NAME}.state")
          fi
          printf "%-16s %-30s %-12s %-9s %-10s %-7s %s %s\n" \
              "$NAME" "$REPO_PATH" "${BRANCH:-(current)}" "$RUN_USER" \
              "$(compose_label "${COMPOSE:-0}" "${COMPOSE_PULL:-0}" "${COMPOSE_BUILD:-0}")" \
              "$([[ "$ENABLED" == "1" ]] && echo yes || echo no)" "$st" "$ts"
        )
    done
}

# Asks for the compose fields. Works on the caller's COMPOSE, COMPOSE_DIR,
# COMPOSE_PULL and COMPOSE_BUILD, and reads REPO_PATH and RUN_USER from there.
ask_compose() {
    echo
    echo "--- Docker Compose ---"
    echo "After new commits the application can be redeployed automatically:"
    echo "optionally 'docker compose pull', then 'docker compose up -d'."

    local def=N
    if [[ "${COMPOSE:-0}" == "1" ]]; then
        def=Y
    elif compose_file_here "$REPO_PATH"; then
        echo "There is a compose file in the repository."
        def=Y
    fi
    if ! confirm "Use the compose deployment?" "$def"; then
        COMPOSE=0
        return
    fi
    COMPOSE=1

    local d
    read -rp "Directory relative to the repo, '.' = root [${COMPOSE_DIR:-.}]: " d
    d=${d:-${COMPOSE_DIR:-.}}
    [[ "$d" == "." ]] && d=""
    d=${d#/}; d=${d%/}
    COMPOSE_DIR="$d"
    local cdir="$REPO_PATH${COMPOSE_DIR:+/$COMPOSE_DIR}"
    if [[ ! -d "$cdir" ]]; then
        echo "  -> careful: ${cdir} does not exist."
    elif ! compose_file_here "$cdir"; then
        echo "  -> careful: there is no compose file in ${cdir}."
    fi

    echo
    echo "'docker compose pull' first: needed when the images are built"
    echo "externally and pulled from a registry - not for a local build."
    confirm "Run 'docker compose pull' first?" \
        "$([[ "${COMPOSE_PULL:-0}" == "1" ]] && echo Y || echo N)" \
        && COMPOSE_PULL=1 || COMPOSE_PULL=0

    echo
    echo "'--build': rebuilds the images from the repository - needed when they"
    echo "are built locally."
    confirm "Bring it up with '--build'?" \
        "$([[ "${COMPOSE_BUILD:-1}" == "1" ]] && echo Y || echo N)" \
        && COMPOSE_BUILD=1 || COMPOSE_BUILD=0

    # Docker belongs to root. Without the 'docker' group (or rootless Docker)
    # the deployment fails on the socket permission - better to notice that now
    # than on the first cron run.
    if [[ "$RUN_USER" != "root" ]] \
       && ! id -nG "$RUN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo
        echo "  -> ${RUN_USER} is not in the group 'docker'. Unless a rootless"
        echo "     Docker runs there, access to the socket is missing:"
        echo "     usermod -aG docker ${RUN_USER}"
    fi

    echo
    echo "On new commits this then runs in ${cdir}:"
    (( COMPOSE_PULL == 1 )) && echo "  docker compose pull"
    echo "  docker compose up -d$( (( COMPOSE_BUILD == 1 )) && echo ' --build')"
}

create_repo() {
    echo "--- Existing entries ---"; list_repos; echo

    local NAME REPO_PATH BRANCH RUN_USER POST_CMD NOTE
    local COMPOSE=0 COMPOSE_DIR="" COMPOSE_PULL=0 COMPOSE_BUILD=1
    read -rp "Name: " NAME
    while [[ -z "$NAME" || "$NAME" =~ [[:space:]/] ]] || [[ -f "$(repo_file "$NAME")" ]]; do
        echo "Invalid or already taken."
        read -rp "Name: " NAME
    done

    read -rp "Directory of the working copy: " REPO_PATH
    while [[ ! -d "$REPO_PATH/.git" ]]; do
        echo "  -> There is no git repository there (.git is missing)."
        read -rp "  Directory: " REPO_PATH
        [[ -z "$REPO_PATH" ]] && { echo "Cancelled."; pause; return; }
    done
    REPO_PATH=${REPO_PATH%/}

    # The owner of the directory is almost always the right user.
    local owner; owner=$(stat -c %U "$REPO_PATH" 2>/dev/null || echo root)
    read -rp "Run as which user [${owner}]: " RUN_USER
    RUN_USER=${RUN_USER:-$owner}
    while ! id "$RUN_USER" &>/dev/null; do
        echo "  -> That user does not exist."
        read -rp "  User: " RUN_USER
    done

    local cur; cur=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)
    read -rp "Branch [${cur:-current}]: " BRANCH

    ask_compose

    echo
    echo "In addition, a command of your own can run after new commits, e.g."
    echo "'systemctl reload caddy'. It runs in the directory of the working copy"
    echo "as ${RUN_USER}, after the compose deployment."
    read -rp "Command (empty = none): " POST_CMD

    read -rp "Note (optional): " NOTE

    cat > "$(repo_file "$NAME")" <<EOF
NAME="${NAME}"
REPO_PATH="${REPO_PATH}"
BRANCH="${BRANCH}"
RUN_USER="${RUN_USER}"
COMPOSE="${COMPOSE}"
COMPOSE_DIR="${COMPOSE_DIR}"
COMPOSE_PULL="${COMPOSE_PULL}"
COMPOSE_BUILD="${COMPOSE_BUILD}"
POST_CMD="${POST_CMD}"
ENABLED="1"
NOTE="${NOTE}"
EOF

    echo
    echo "Immediate test:"
    make_dirs
    update_one "$(repo_file "$NAME")" verbose
    pause
}

edit_repo() {
    echo "--- Entries ---"; list_repos; echo
    read -rp "Name to edit: " N
    local f; f=$(repo_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    # Old entries do not know the compose fields - set the defaults before
    # reading.
    local COMPOSE=0 COMPOSE_DIR="" COMPOSE_PULL=0 COMPOSE_BUILD=1
    # shellcheck disable=SC1090
    . "$f"
    local P B U C E O
    read -rp "Directory [${REPO_PATH}]: " P; REPO_PATH=${P:-$REPO_PATH}; REPO_PATH=${REPO_PATH%/}
    read -rp "Branch [${BRANCH:-(current)}]: " B; BRANCH=${B:-$BRANCH}
    read -rp "User [${RUN_USER}]: " U; RUN_USER=${U:-$RUN_USER}

    ask_compose

    echo
    read -rp "Command after an update [${POST_CMD}]: " C; C=${C:-$POST_CMD}
    read -rp "Active (1/0) [${ENABLED}]: " E; E=${E:-$ENABLED}
    read -rp "Note [${NOTE}]: " O; O=${O:-$NOTE}

    cat > "$f" <<EOF
NAME="${NAME}"
REPO_PATH="${REPO_PATH}"
BRANCH="${BRANCH}"
RUN_USER="${RUN_USER}"
COMPOSE="${COMPOSE}"
COMPOSE_DIR="${COMPOSE_DIR}"
COMPOSE_PULL="${COMPOSE_PULL}"
COMPOSE_BUILD="${COMPOSE_BUILD}"
POST_CMD="${C}"
ENABLED="${E}"
NOTE="${O}"
EOF
    echo "Updated."
    pause
}

delete_repo() {
    echo "--- Entries ---"; list_repos; echo
    read -rp "Name to remove: " N
    local f; f=$(repo_file "$N")
    [[ -f "$f" ]] || { echo "Not found."; pause; return; }

    echo
    echo "This removes only the entry - the working copy on disk stays."
    confirm "Really remove '$N'?" || { echo "Cancelled."; pause; return; }
    rm -f "$f" "$STATE_DIR/${N}.state"
    echo "Removed."
    pause
}

repo_menu() {
    while true; do
        clear
        echo "=== Manage repositories ==="
        list_repos
        echo
        echo "1) Create an entry"
        echo "2) Edit an entry"
        echo "3) Remove an entry"
        echo "4) Back"
        read -rp "Choice: " CH
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
# Updating
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
                || echo "$(date '+%F %T') !!! sending mail failed" >> "$ALERT_LOG"
        else
            echo "$(date '+%F %T') !!! 'mail' missing - nothing sent" >> "$ALERT_LOG"
        fi
    fi
}

# Sets the globals RESULT (OK|UPDATED|ERROR), DETAIL and LINE.
update_one() {
    local f=$1 verbose=${2:-}

    # shellcheck disable=SC1090
    . "$f"

    RESULT=OK; DETAIL=""; LINE=""

    if [[ "$ENABLED" != "1" && -z "$verbose" ]]; then RESULT=SKIP; return 0; fi

    if [[ ! -d "$REPO_PATH/.git" ]]; then
        RESULT=ERROR; DETAIL="no git repository under ${REPO_PATH}"
    else
        local old new out rc=0
        old=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --short HEAD 2>/dev/null)

        if [[ -z "$old" ]]; then
            RESULT=ERROR; DETAIL="HEAD not readable (permissions? user ${RUN_USER}?)"
        else
            # Check local changes first: a --ff-only fails on them anyway, but
            # with a far less clear message.
            if [[ -n "$(gitrun "$RUN_USER" "$REPO_PATH" status --porcelain 2>/dev/null)" ]]; then
                RESULT=ERROR; DETAIL="local changes in the working copy"
            else
                if [[ -n "$BRANCH" ]]; then
                    out=$(gitrun "$RUN_USER" "$REPO_PATH" checkout "$BRANCH" 2>&1) || {
                        RESULT=ERROR; DETAIL="branch '${BRANCH}' cannot be checked out: $(head -1 <<<"$out")"
                    }
                fi

                if [[ "$RESULT" != "ERROR" ]]; then
                    # --ff-only: never merge or rebase automatically. If the
                    # working copy has diverged, that should show up rather than
                    # silently produce a merge commit.
                    out=$(gitrun "$RUN_USER" "$REPO_PATH" pull --ff-only --quiet 2>&1) || rc=$?
                    if (( rc != 0 )); then
                        RESULT=ERROR
                        case "$out" in
                            *"no tracking information"*|*"no upstream"*)
                                DETAIL="no upstream set for the branch" ;;
                            *"Not possible to fast-forward"*|*"non-fast-forward"*|*"diverged"*)
                                DETAIL="the working copy has diverged (no fast-forward)" ;;
                            *"Permission denied"*|*"Could not read from remote"*)
                                DETAIL="no access to the remote (SSH key for ${RUN_USER}?)" ;;
                            *)
                                DETAIL=$(head -2 <<<"$out" | tr '\n' ' ') ;;
                        esac
                        (( rc == 124 )) && DETAIL="timed out after ${TIMEOUT}s"
                    else
                        new=$(gitrun "$RUN_USER" "$REPO_PATH" rev-parse --short HEAD 2>/dev/null)
                        if [[ "$old" != "$new" ]]; then
                            RESULT=UPDATED
                            DETAIL="${old} -> ${new}"
                            LINE=$(gitrun "$RUN_USER" "$REPO_PATH" log -1 --pretty='%h %s (%an)' 2>/dev/null)

                            # Deploy first, then the custom command: that is the
                            # order you would do it in by hand.
                            if [[ "${COMPOSE:-0}" == "1" ]]; then
                                local cdir="$REPO_PATH${COMPOSE_DIR:+/$COMPOSE_DIR}"
                                if [[ ! -d "$cdir" ]]; then
                                    RESULT=ERROR
                                    DETAIL="${DETAIL}, but the compose directory ${cdir} is missing"
                                elif run_in_dir "$RUN_USER" "$cdir" "$COMPOSE_TIMEOUT" \
                                        "$(compose_script "${COMPOSE_PULL:-0}" "${COMPOSE_BUILD:-0}")"; then
                                    DETAIL="${DETAIL}, deployed"
                                else
                                    # Compose reports the cause at the end of the
                                    # output, not at the beginning.
                                    RESULT=ERROR
                                    DETAIL="${DETAIL}, but compose failed: $(grep -v '^[[:space:]]*$' <<<"$CMD_OUT" | tail -1)"
                                fi
                            fi

                            if [[ -n "$POST_CMD" && "$RESULT" != "ERROR" ]]; then
                                if run_in_dir "$RUN_USER" "$REPO_PATH" "$TIMEOUT" "$POST_CMD"; then
                                    DETAIL="${DETAIL}, command run"
                                else
                                    RESULT=ERROR
                                    DETAIL="${DETAIL}, but the command failed: $(head -1 <<<"$CMD_OUT")"
                                fi
                            fi
                        else
                            DETAIL="unchanged (${old})"
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
    is_setup || { echo "Not set up. Run the setup first." >&2; return 1; }
    make_dirs

    # At a five-minute cadence a slow run can spill into the next one. If flock
    # is missing (not present on every system), work goes on without a lock -
    # better a possible overlap than no run at all.
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "A run is not finished yet - skipped." >&2
            echo "$(date '+%F %T') run skipped (lock)" >> "$RUN_LOG"
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
        # update_one deliberately sets global variables (no subshell), so that
        # RESULT and DETAIL arrive here.
        NAME=""; REPO_PATH=""; BRANCH=""; RUN_USER=""; POST_CMD=""; ENABLED=""; NOTE=""
        COMPOSE=0; COMPOSE_DIR=""; COMPOSE_PULL=0; COMPOSE_BUILD=0
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
                changes+=("UPDATE   ${NAME}: ${DETAIL}${LINE:+ | ${LINE}}")
                updated=$(( updated + 1 ))
                ;;
            ERROR)
                # Do not keep kicking on every run - only on the change.
                if [[ "$prev" != "ERROR" ]]; then
                    changes+=("ERROR    ${NAME}: ${DETAIL}")
                    failed=$(( failed + 1 ))
                fi
                ;;
            OK)
                [[ "$prev" == "ERROR" ]] && changes+=("RECOVERED ${NAME}: fine again")
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
        body="git-updater on ${host}"$'\n'"As of: ${now}"$'\n\n'
        if (( ${#changes[@]} > 0 )); then
            body+=$(printf '  %s\n' "${changes[@]}")
        else
            body+="  No changes."
        fi
        if (( failed > 0 )); then
            subject="[git] ${host}: ${failed} repo(s) with an error"
        elif (( updated > 0 )); then
            subject="[git] ${host}: ${updated} repo(s) updated"
        else
            subject="[git] ${host}: no changes"
        fi
        notify "$subject" "$body"
    fi

    if [[ -n "$verbose" ]]; then
        echo
        if (( ${#changes[@]} > 0 )); then
            printf '%s\n' "${changes[@]}"
        else
            echo "No changes - no mail would be sent."
        fi
    fi

    return $rc
}

show_log() {
    echo "--- Last messages ---"
    tail -n 30 "$ALERT_LOG" 2>/dev/null || echo "(none)"
    echo
    echo "--- Last runs ---"
    tail -n 20 "$RUN_LOG" 2>/dev/null || echo "(none)"
    pause
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
configure() {
    echo ">>> Settings for git-updater"
    echo

    local D I T CT
    read -rp "Data directory [${DATA_DIR}]: " D; DATA_DIR=${D:-$DATA_DIR}
    read -rp "Check interval in minutes [${INTERVAL_MIN}]: " I; INTERVAL_MIN=${I:-$INTERVAL_MIN}
    read -rp "Time limit per git call in seconds [${TIMEOUT}]: " T; TIMEOUT=${T:-$TIMEOUT}
    # An image build takes minutes, not seconds - hence its own, far more
    # generous limit.
    read -rp "Time limit per compose deployment in seconds [${COMPOSE_TIMEOUT}]: " CT
    COMPOSE_TIMEOUT=${CT:-$COMPOSE_TIMEOUT}

    echo
    echo "--- Notification ---"
    local M W
    read -rp "Mail address (empty = none) [${ALERT_MAIL}]: " M; ALERT_MAIL=${M:-$ALERT_MAIL}
    read -rp "Webhook URL (empty = none) [${ALERT_WEBHOOK}]: " W; ALERT_WEBHOOK=${W:-$ALERT_WEBHOOK}

    if [[ -n "$ALERT_MAIL$ALERT_WEBHOOK" ]]; then
        confirm "Report when new commits were fetched?" \
            "$([[ $MAIL_ON_UPDATE -eq 1 ]] && echo Y || echo N)" \
            && MAIL_ON_UPDATE=1 || MAIL_ON_UPDATE=0
        confirm "Report when a repo could not be updated?" \
            "$([[ $MAIL_ON_ERROR -eq 1 ]] && echo Y || echo N)" \
            && MAIL_ON_ERROR=1 || MAIL_ON_ERROR=0
        confirm "Report even when there was nothing to do?" \
            "$([[ $MAIL_ON_NOOP -eq 1 ]] && echo Y || echo N)" \
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
    echo "Data:     $DATA_DIR"
    echo "Cron:     every ${INTERVAL_MIN} min  ($CRON_FILE)"
    echo ">>> Set up. Now create entries under 'Manage repositories'."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall git-updater"
    echo

    local n=0
    [[ -d "$REPOS_DIR" ]] && n=$(find "$REPOS_DIR" -name '*.conf' 2>/dev/null | wc -l)

    echo "The following will be removed:"
    [[ -f "$CRON_FILE" ]] && echo "  - cron entry $CRON_FILE (every ${INTERVAL_MIN} min)"
    [[ -f "$CONF" ]]      && echo "  - configuration $CONF"
    [[ -d "$DATA_DIR" ]]  && echo "  - data directory $DATA_DIR (${n} entries, state, logs)   [asked]"
    echo
    echo "The working copies themselves are not touched - they are simply no"
    echo "longer pulled automatically."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup git-updater "$CONF" "$DATA_DIR" || { pause; return; }

    if [[ -f "$CRON_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo "!!! Not root - please remove the cron entry manually:"
            echo "    rm -f $CRON_FILE"
        else
            rm -f "$CRON_FILE"
        fi
    fi
    rm -f "$CONF"

    if [[ -d "$DATA_DIR" ]] && confirm "Delete entries and logs in $DATA_DIR as well?"; then
        rm -rf "$DATA_DIR"
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
        echo " Keep git working copies up to date"
        echo "==========================================="
        if is_setup; then
            echo "Data: $DATA_DIR"
            echo "Cron: $([[ -f "$CRON_FILE" ]] && echo "every ${INTERVAL_MIN} min" || echo '!!! not installed')"
            echo "Mail: ${ALERT_MAIL:-(none)}"
            echo
            list_repos
        else
            echo "Status: not set up"
        fi
        echo
        echo "1) Manage repositories"
        echo "2) Update all now"
        echo "3) Settings (interval, notification)"
        echo "4) Show the log"
        echo "5) Uninstall"
        echo "6) Quit"
        read -rp "Choice: " CH
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
    *)           echo "Usage: $0 [--run|--status|--uninstall|--version]"; exit 1 ;;
esac
