#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# docker-setup.sh - install Docker from the official repo and configure it
# Modes: (no argument) = interactive menu
#        --prune       = cleanup run (for cron)
#        --status      = status on stdout
#        --uninstall   = uninstall
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="2.3.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/docker-setup.conf"

DAEMON_JSON=/etc/docker/daemon.json
# Provenance marker next to the file: daemon.json itself may not carry one,
# since dockerd rejects every key it does not know.
MARKER=/etc/docker/.daemon.json.docker-setup
REPO_LIST=/etc/apt/sources.list.d/docker.list
REPO_KEY=/etc/apt/keyrings/docker.asc
CRON_FILE=/etc/cron.d/docker-prune

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
LOG_MAX_SIZE="10m"
LOG_MAX_FILE=3
BIND_LOCALHOST=1        # bind published ports to 127.0.0.1 only
LIVE_RESTORE=1
PRUNE_ENABLED=0
PRUNE_HOUR=4
PRUNE_ALL_IMAGES=0
PRUNE_UNTIL_H=168       # 7 days

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

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
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nothing to back up)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

installed() { command -v docker &>/dev/null; }

save_conf() {
    cat > "$CONF" <<EOF
# docker-setup configuration
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
# The distribution packages (docker.io) are usually several versions behind and
# do not ship the compose plugin. Hence the official repo.
install_docker() {
    if installed; then
        echo "Docker is already installed: $(docker --version)"
        return 0
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local id=${ID:-debian} code=${VERSION_CODENAME:-}

    # Derivatives such as Linux Mint carry their own codename, for which there
    # is no Docker repo - there the base distribution's one sits next to it.
    if [[ "$id" != "debian" && "$id" != "ubuntu" ]]; then
        if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
            id=ubuntu; code="$UBUNTU_CODENAME"
        elif [[ -n "${DEBIAN_CODENAME:-}" ]]; then
            id=debian; code="$DEBIAN_CODENAME"
        else
            echo "There is no Docker repo known for distribution '$id'."
            read -rp "Base (debian/ubuntu): " id
            read -rp "Codename (e.g. bookworm, noble): " code
        fi
    fi
    [[ -n "$code" ]] || { read -rp "Codename of the distribution: " code; }

    # Old or competing packages get in the way of the installation.
    local -a old=() p
    for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        dpkg -s "$p" &>/dev/null && old+=("$p")
    done
    if (( ${#old[@]} > 0 )); then
        echo "These packages stand in the way of the official installation:"
        printf '    %s\n' "${old[@]}"
        echo "Containers and data under /var/lib/docker survive the removal."
        confirm "Remove them now?" Y || { echo "Cancelled."; return 1; }
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "${old[@]}" >/dev/null || true
    fi

    echo ">>> Setting up the repo (${id}/${code})..."
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl >/dev/null

    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "https://download.docker.com/linux/${id}/gpg" -o "$REPO_KEY"; then
        echo "!!! The key cannot be fetched."
        return 1
    fi
    chmod a+r "$REPO_KEY"

    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$REPO_KEY" "$id" "$code" > "$REPO_LIST"

    echo ">>> Installing Docker..."
    apt-get update -qq
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null; then
        echo "!!! Installation failed."
        return 1
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    echo ">>> $(docker --version)"
    echo ">>> $(docker compose version 2>/dev/null || echo 'compose plugin not found')"
}

# ---------------------------------------------------------------------------
# daemon.json
# ---------------------------------------------------------------------------
# Whether this file came from here. JSON has no comments, and dockerd refuses
# to start on any key it does not know - so the provenance cannot live inside
# the file and sits next to it instead.
ours() {
    [[ -f "$MARKER" ]] && return 0
    # Files written before 2.2.0 carried a "_comment" key. That is exactly what
    # used to break the daemon, but it still identifies the file as ours.
    [[ -f "$DAEMON_JSON" ]] && grep -q 'docker-setup.sh' "$DAEMON_JSON"
}

write_daemon_json() {
    mkdir -p /etc/docker

    # A foreign file is not overwritten but moved aside - merging JSON by hand
    # in bash would only be guesswork.
    if [[ -f "$DAEMON_JSON" ]] && ! ours; then
        local bak="${DAEMON_JSON}.orig.$(date +%s)"
        cp "$DAEMON_JSON" "$bak"
        echo "Existing $DAEMON_JSON backed up to $bak."
        echo "Your own settings from it have to be carried over by hand:"
        sed 's/^/    /' "$bak"
        confirm "Continue and write a new one?" || return 1
    fi

    # Keep the previous state, so a configuration the daemon rejects can be
    # taken back. Docker being down afterwards is the one outcome this function
    # must never produce.
    local prev="" had_file=0
    if [[ -f "$DAEMON_JSON" ]]; then
        had_file=1
        prev=$(mktemp)
        cp -a "$DAEMON_JSON" "$prev"
    fi

    # No "_comment" and no other invented key: dockerd validates daemon.json
    # strictly and refuses to start on anything it does not recognise, with
    # "the following directives don't match any configuration option".
    {
        echo '{'
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
    printf 'written by docker-setup.sh\n' > "$MARKER"
    chmod 644 "$MARKER"

    # Undo everything this function changed and put the daemon back the way it
    # was found.
    restore_daemon_json() {
        if (( had_file == 1 )); then
            cp -a "$prev" "$DAEMON_JSON"
            echo "    $DAEMON_JSON restored to its previous content."
        else
            rm -f "$DAEMON_JSON" "$MARKER"
            echo "    $DAEMON_JSON removed again (there was none before)."
        fi
        if installed && ! systemctl is-active docker &>/dev/null; then
            systemctl start docker >/dev/null 2>&1 \
                && echo "    Docker started again." \
                || echo "    !!! Docker still does not start - check 'journalctl -u docker'."
        fi
        [[ -n "$prev" ]] && rm -f "$prev"
    }

    # Check before restarting, the way nginx -t and sshd -t are used elsewhere.
    # Available from Docker 23; where it is missing, the restart below is the
    # only test there is.
    if command -v dockerd &>/dev/null && dockerd --help 2>&1 | grep -q -- '--validate'; then
        local out
        if ! out=$(dockerd --validate --config-file "$DAEMON_JSON" 2>&1); then
            echo "!!! Docker rejects the configuration:"
            sed 's/^/    /' <<<"$out"
            restore_daemon_json
            return 1
        fi
    fi

    if installed && systemctl is-active docker &>/dev/null; then
        if systemctl restart docker; then
            echo "$DAEMON_JSON written, Docker restarted."
        else
            echo "!!! Docker does not start with the new configuration:"
            journalctl -u docker -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
            echo
            echo ">>> Taking the change back so the host is not left without Docker."
            restore_daemon_json
            return 1
        fi
    else
        echo "$DAEMON_JSON written."
    fi

    [[ -n "$prev" ]] && rm -f "$prev"
    return 0
}

settings() {
    echo "--- Current settings ---"
    echo "  Log rotation:      max ${LOG_MAX_SIZE} x ${LOG_MAX_FILE} per container"
    echo "  Bind ports to:     $( ((BIND_LOCALHOST==1)) && echo '127.0.0.1 (local only)' || echo '0.0.0.0 (all addresses)')"
    echo "  live-restore:      $( ((LIVE_RESTORE==1)) && echo on || echo off)"
    echo

    local S F
    echo "Without rotation /var/lib/docker/containers grows without bound - that is"
    echo "the most common cause of a full disk on a Docker host."
    read -rp "Maximum size per log file [${LOG_MAX_SIZE}]: " S; LOG_MAX_SIZE=${S:-$LOG_MAX_SIZE}
    read -rp "Number of files per container [${LOG_MAX_FILE}]: " F; LOG_MAX_FILE=${F:-$LOG_MAX_FILE}

    echo
    echo "Docker publishes ports (-p 8080:80) DIRECTLY to the network via iptables -"
    echo "bypassing ufw. A ufw rule does not protect them."
    echo "Binding them to 127.0.0.1 by default makes them reachable only locally and"
    echo "through a reverse proxy (Caddy/nginx)."
    confirm "Bind ports to 127.0.0.1 by default?" \
        "$( ((BIND_LOCALHOST==1)) && echo Y || echo N)" && BIND_LOCALHOST=1 || BIND_LOCALHOST=0

    echo
    echo "live-restore keeps containers running while the Docker service restarts -"
    echo "during a package update, for instance."
    confirm "Enable live-restore?" "$( ((LIVE_RESTORE==1)) && echo Y || echo N)" \
        && LIVE_RESTORE=1 || LIVE_RESTORE=0

    save_conf
    write_daemon_json || true
    pause
}

# ---------------------------------------------------------------------------
# The docker group
# ---------------------------------------------------------------------------
add_user() {
    echo "!!! Whoever is in the group 'docker' can read and write every file on the"
    echo "!!! system as root through a container. That is equivalent to root rights,"
    echo "!!! only without the sudo log."
    echo
    echo "Currently in the group: $(getent group docker | cut -d: -f4 | tr ',' ' ' || echo '(nobody)')"
    echo
    local u
    read -rp "User (empty = cancel): " u
    [[ -n "$u" ]] || return
    if ! id "$u" &>/dev/null; then echo "User '$u' does not exist."; pause; return; fi

    confirm "Really add '$u' to the docker group?" || { echo "Cancelled."; pause; return; }
    usermod -aG docker "$u"
    echo "Added. In effect after the next login of '$u'."
    pause
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
write_prune_cron() {
    if (( PRUNE_ENABLED == 0 )); then
        rm -f "$CRON_FILE"
        return 0
    fi
    cat > "$CRON_FILE" <<EOF
# docker-prune - clears out unused images, containers and networks
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 ${PRUNE_HOUR} * * 0 root ${SELF} --prune >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# Volumes are NEVER removed automatically - that is where the data lives, and a
# volume without a running container is by no means a superfluous volume.
do_prune() {
    installed || { echo "Docker is not installed." >&2; return 1; }
    local -a args=(system prune -f --filter "until=${PRUNE_UNTIL_H}h")
    (( PRUNE_ALL_IMAGES == 1 )) && args=(system prune -af --filter "until=${PRUNE_UNTIL_H}h")
    docker "${args[@]}"
}

cleanup_menu() {
    installed || { echo "Docker is not installed."; pause; return; }
    while true; do
        clear
        echo "=== Cleanup ==="
        docker system df 2>/dev/null || echo "(docker system df not available)"
        echo
        echo "Automatic: $( ((PRUNE_ENABLED==1)) && echo "Sundays at ${PRUNE_HOUR}:00, older than ${PRUNE_UNTIL_H}h$( ((PRUNE_ALL_IMAGES==1)) && echo ', unused images too')" || echo 'off')"
        echo
        echo "1) Clean up now"
        echo "2) Configure the automatic run"
        echo "3) Show unused volumes (deletes nothing)"
        echo "4) Back"
        read -rp "Choice: " CH
        case "$CH" in
            1) echo; do_prune; echo; pause ;;
            2)
                confirm "Clean up automatically once a week?" \
                    "$( ((PRUNE_ENABLED==1)) && echo Y || echo N)" && PRUNE_ENABLED=1 || PRUNE_ENABLED=0
                if (( PRUNE_ENABLED == 1 )); then
                    local H U
                    read -rp "Hour (0-23) [${PRUNE_HOUR}]: " H; PRUNE_HOUR=${H:-$PRUNE_HOUR}
                    read -rp "Only remove things older than (hours) [${PRUNE_UNTIL_H}]: " U
                    PRUNE_UNTIL_H=${U:-$PRUNE_UNTIL_H}
                    echo
                    echo "Without '-a' only untagged images go. With '-a' tagged images that"
                    echo "no container is currently using go too - those have to be pulled"
                    echo "again on the next start."
                    confirm "Remove unused tagged images as well (-a)?" \
                        "$( ((PRUNE_ALL_IMAGES==1)) && echo Y || echo N)" \
                        && PRUNE_ALL_IMAGES=1 || PRUNE_ALL_IMAGES=0
                fi
                save_conf; write_prune_cron
                echo "Saved."; pause
                ;;
            3)
                echo
                echo "Volumes without a container (the cleanup does NOT touch these):"
                docker volume ls -qf dangling=true 2>/dev/null | sed 's/^/  /' || true
                echo
                echo "Remove them one by one with: docker volume rm <name>"
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
    if ! installed; then echo "Docker is not installed."; return; fi
    echo "--- Version ---"
    docker --version 2>/dev/null | sed 's/^/  /'
    docker compose version 2>/dev/null | sed 's/^/  /'
    echo
    echo "--- Service ---"
    printf '  docker: %s\n' "$(systemctl is-active docker 2>/dev/null || echo '-')"
    echo
    echo "--- Settings from $DAEMON_JSON ---"
    if [[ -f "$DAEMON_JSON" ]]; then sed 's/^/  /' "$DAEMON_JSON"; else echo "  (none)"; fi
    echo
    echo "--- Containers ---"
    docker ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "  (no output)"
    echo
    echo "--- Disk usage ---"
    docker system df 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "--- The docker group ---"
    echo "  $(getent group docker | cut -d: -f4 || echo '(nobody)')"

    # Published ports that really are open to the outside
    local exposed
    exposed=$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
              | grep -E '^\s*0\.0\.0\.0:|^\s*:::' | sed 's/^ *//' | sort -u)
    if [[ -n "$exposed" ]]; then
        echo
        echo "!!! These ports are bound to ALL addresses and are therefore reachable"
        echo "!!! from the network, bypassing ufw:"
        printf '  %s\n' "$exposed"
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall docker-setup"
    echo
    echo "The following will be removed:"
    [[ -f "$DAEMON_JSON" ]] && echo "  - $DAEMON_JSON (a backed-up version is restored, if there is one)"
    [[ -f "$CONF" ]]        && echo "  - $CONF"
    [[ -f "$CRON_FILE" ]]   && echo "  - $CRON_FILE (automatic cleanup)"
    echo
    echo "Left untouched: Docker itself, running containers, images and above all"
    echo "the volumes under /var/lib/docker. To remove everything:"
    echo "    apt purge docker-ce docker-ce-cli containerd.io \\"
    echo "        docker-buildx-plugin docker-compose-plugin"
    echo "    rm -rf /var/lib/docker /var/lib/containerd"
    echo "    rm -f ${REPO_LIST} ${REPO_KEY}"
    echo "  (that also deletes every volume and with it the containers' data)"
    echo
    if installed && [[ -n "$(docker ps -q 2>/dev/null)" ]]; then
        echo "!!! $(docker ps -q | wc -l) containers are running right now. They keep running."
        echo
    fi

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup docker-setup "$DAEMON_JSON" "$CONF" || { pause; return; }

    rm -f "$CRON_FILE" "$CONF"

    local orig
    orig=$(ls -1t "${DAEMON_JSON}".orig.* 2>/dev/null | head -1 || true)
    if [[ -n "$orig" ]]; then
        mv "$orig" "$DAEMON_JSON"
        echo "$DAEMON_JSON restored from $orig."
        rm -f "$MARKER"
    elif [[ -f "$DAEMON_JSON" ]] && ours; then
        rm -f "$DAEMON_JSON" "$MARKER"
        echo "$DAEMON_JSON removed."
    fi

    if installed && systemctl is-active docker &>/dev/null; then
        if confirm "Restart Docker now so the change takes effect?" Y; then
            systemctl restart docker || echo "!!! The restart failed."
        fi
    fi

    echo
    echo "Removed. Without log rotation container logs grow without bound again -"
    echo "keep an eye on that (disk-monitor.sh helps)."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Docker"
        echo "==========================================="
        if installed; then
            echo "Version:   $(docker --version 2>/dev/null | sed 's/Docker version //')"
            echo "Service:   $(systemctl is-active docker 2>/dev/null || echo '-')"
            echo "Containers: $(docker ps -q 2>/dev/null | wc -l) running, $(docker ps -aq 2>/dev/null | wc -l) in total"
            echo "Ports:     $( ((BIND_LOCALHOST==1)) && echo '127.0.0.1 only by default' || echo 'all addresses')"
        else
            echo "Status: not installed"
        fi
        echo
        echo "1) Install"
        echo "2) Show status"
        echo "3) Settings (log rotation, port binding, live-restore)"
        echo "4) Add a user to the docker group"
        echo "5) Clean up"
        echo "6) Uninstall"
        echo "7) Quit"
        read -rp "Choice: " CH
        case "$CH" in
            1) install_docker && { save_conf; write_daemon_json || true; }; pause ;;
            2) show_status; pause ;;
            3) settings ;;
            4) installed && add_user || { echo "Docker is not installed."; pause; } ;;
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
    *)           echo "Usage: $0 [--prune|--status|--uninstall|--version]"; exit 1 ;;
esac
