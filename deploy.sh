#!/usr/bin/env bash
set -Eeuo pipefail

APP_PORT=3000
IMAGE_NAME="my-nextjs-app"

BLUE="nextjs_blue"
GREEN="nextjs_green"

DOCKER_NETWORK="devopsserver_net"
NGINX_NAME="nginx"

HOST_PORT=80
NGINX_CONF="/opt/devopsserver/nginx/nginx.conf"

IMAGE_TAG="${IMAGE_NAME}:latest"

log(){ echo "[deploy] $*"; }

ensure_network() {
  docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || \
    docker network create "$DOCKER_NETWORK"
}

ensure_nginx_config() {
  mkdir -p "$(dirname "$NGINX_CONF")"
}

build() {
  docker build -t "$IMAGE_TAG" .
}

active_slot() {
  docker ps --format '{{.Names}}' | grep -q "$BLUE" && echo "$BLUE"
  docker ps --format '{{.Names}}' | grep -q "$GREEN" && echo "$GREEN"
}

deploy_slot() {
  ACTIVE=$(active_slot)

  if [ "$ACTIVE" = "$BLUE" ]; then
    TARGET="$GREEN"
  else
    TARGET="$BLUE"
  fi

  docker rm -f "$TARGET" >/dev/null 2>&1 || true

  docker run -d \
    --name "$TARGET" \
    --network "$DOCKER_NETWORK" \
    -e NODE_ENV=production \
    -e PORT=$APP_PORT \
    "$IMAGE_TAG"

  echo "$TARGET"
}

write_nginx() {
  TARGET="$1"

  cat > "$NGINX_CONF" <<EOF
events {}

http {
  server {
    listen 80;

    location / {
      proxy_pass http://$TARGET:$APP_PORT;
    }
  }
}
EOF
}

run_nginx() {
  docker rm -f "$NGINX_NAME" >/dev/null 2>&1 || true

  docker run -d \
    --name "$NGINX_NAME" \
    --network "$DOCKER_NETWORK" \
    -p 80:80 \
    -v "$NGINX_CONF:/etc/nginx/nginx.conf:ro" \
    nginx:alpine
}

ensure_network
ensure_nginx_config
build

TARGET=$(deploy_slot)
write_nginx "$TARGET"
run_nginx

echo "[deploy] SUCCESS -> $TARGET"