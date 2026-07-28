#!/usr/bin/env bash
# modules/docker.sh - Docker installieren / Status / aufraeumen.

register docker install dk_install "Docker + Compose installieren"
register docker status  dk_status  "Docker-Status (info + Container)"
register docker prune   dk_prune   "Ungenutzte Images/Cache aufraeumen"

dk_install() {
  need_docker
  log "Docker/Compose bereit:"
  $DOCKER version --format '{{.Server.Version}}' 2>/dev/null | sed 's/^/   Docker /' || true
  $DOCKER compose version 2>/dev/null | sed 's/^/   /' || true
}

dk_status() {
  need_docker
  echo "== docker info =="
  $DOCKER info 2>/dev/null | grep -Ei 'server version|^ containers|running|images|storage driver' || true
  echo; echo "== Container =="
  $DOCKER ps
}

dk_prune() {
  need_docker
  confirm "Ungenutzte Images + Build-Cache entfernen (docker system prune -f)?" || { echo "Abbruch."; return 0; }
  $DOCKER system prune -f
  if confirm "Auch ungenutzte Volumes entfernen? VORSICHT - kann Daten loeschen"; then
    $DOCKER volume prune -f
  fi
}
