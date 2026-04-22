#!/usr/bin/env bash
# 远端服务器拉取最新镜像并重建服务。
set -euo pipefail

APP_DIR=${APP_DIR:-$(cd "$(dirname "$0")" && pwd)}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
APP_BASE_DIR=${APP_BASE_DIR:-$APP_DIR}
DOCKERHUB_IMAGE=${DOCKERHUB_IMAGE:-}
IMAGE_TAG=${IMAGE_TAG:-latest}

log() {
  echo "[remote-deploy] $*"
}

require_file() {
  local file="$1"
  local hint="$2"
  if [[ ! -f "$file" ]]; then
    log "missing $file"
    log "$hint"
    exit 1
  fi
}

if [[ -z "$DOCKERHUB_IMAGE" ]]; then
  log "DOCKERHUB_IMAGE is required"
  exit 1
fi

command -v docker >/dev/null 2>&1 || {
  log "docker is not installed"
  exit 1
}

mkdir -p "$APP_DIR/configs" "$APP_DIR/logs"
require_file "$APP_DIR/$COMPOSE_FILE" "sync docker-compose.yml to the server first"
require_file "$APP_DIR/.env" "copy .env.example to .env and fill in production secrets first"
require_file "$APP_DIR/configs/config.yaml" "copy configs/config.example.yaml to configs/config.yaml and adjust it first"

cd "$APP_DIR"

log "pulling ${DOCKERHUB_IMAGE}:${IMAGE_TAG}"
APP_BASE_DIR="$APP_BASE_DIR" DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" IMAGE_TAG="$IMAGE_TAG" \
  docker compose -f "$COMPOSE_FILE" pull server

log "starting containers"
APP_BASE_DIR="$APP_BASE_DIR" DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" IMAGE_TAG="$IMAGE_TAG" \
  docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

log "current status"
APP_BASE_DIR="$APP_BASE_DIR" DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE" IMAGE_TAG="$IMAGE_TAG" \
  docker compose -f "$COMPOSE_FILE" ps
