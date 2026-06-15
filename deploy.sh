#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_PORT=3000
IMAGE_NAME="my-nextjs-app"

BLUE="nextjs_blue"
GREEN="nextjs_green"

DOCKER_NETWORK="devopsserver_net"
NGINX_NAME="nginx"

HOST_PORT=80
NGINX_CONF="${SCRIPT_DIR}/nginx/nginx.conf"

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
  if docker ps --format '{{.Names}}' | grep -q "$BLUE"; then
    echo "$BLUE"
  elif docker ps --format '{{.Names}}' | grep -q "$GREEN"; then
    echo "$GREEN"
  else
    echo ""
  fi
}

deploy_slot() {
  ACTIVE=$(active_slot)

  if [[ -z "$ACTIVE" || "$ACTIVE" == "$GREEN" ]]; then
    TARGET="$BLUE"
  else
    TARGET="$GREEN"
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
# Wait for the app to be healthy
wait_for_app() {
  local name="$1"

  for i in {1..20}; do
    if docker exec "$name" curl -fsS http://localhost:$APP_PORT >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "[deploy] app not ready"
  exit 1
}

# Write NGINX configuration
write_nginx() {
  local target="$1"

  cat > "$NGINX_CONF" <<EOF
events {}

http {
  server {
    listen 80;

    location / {
      proxy_pass http://$target:$APP_PORT;
    }
  }
}
EOF
}
# Run NGINX container
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
wait_for_app "$TARGET"
write_nginx "$TARGET"
run_nginx

echo "[deploy] SUCCESS -> $TARGET"