#!/usr/bin/env bash
# lib/docker.sh - Docker/Compose-Helfer. DEPLOY_DIR wird von setup.sh gesetzt.

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then return 0; fi
  log "Docker/Compose nicht gefunden - installiere via get.docker.com ..."
  ensure_tool curl curl
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker || true
  if [[ -n "$SUDO" ]]; then $SUDO usermod -aG docker "$(id -un)" || true
    warn "einmal ab-/anmelden, damit 'docker' ohne sudo laeuft."; fi
}

DOCKER="docker"
docker_wrap() { docker info >/dev/null 2>&1 && DOCKER="docker" || DOCKER="$SUDO docker"; }

# Docker nur einrichten, wenn ein Workflow es wirklich braucht (lazy, einmalig).
_DOCKER_READY=0
need_docker() { [[ "$_DOCKER_READY" == 1 ]] && return 0; ensure_docker; docker_wrap; _DOCKER_READY=1; }

# docker compose im Deploy-Ordner.
dc() { ( cd "$DEPLOY_DIR" && $DOCKER compose "$@" ); }
# occ-Passthrough fuer Nextcloud.
occ() { dc exec -T -u www-data nextcloud php occ "$@"; }
