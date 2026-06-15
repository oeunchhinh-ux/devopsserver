#!/usr/bin/env bash
set -Eeuo pipefail

APP_PORT=3000
IMAGE_NAME="my-nextjs-app"
IMAGE_TAG="$IMAGE_NAME:latest"

BLUE="nextjs_blue"
GREEN="nextjs_green"

NETWORK="devops_net"

NGINX_NAME="nginx"
NGINX_CONF="./nginx/nginx.conf"

log(){ echo "[deploy] $*"; }

# ----------------------------
# Create docker network
# ----------------------------
ensure_network() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || \
  docker network create "$NETWORK"
}

# ----------------------------
# Build image
# ----------------------------
build() {
  docker build -t "$IMAGE_TAG" .
}

# ----------------------------
# Find active container
# ----------------------------
active_slot() {
  if docker ps --format '{{.Names}}' | grep -q "$BLUE"; then
    echo "$BLUE"
  elif docker ps --format '{{.Names}}' | grep -q "$GREEN"; then
    echo "$GREEN"
  else
    echo ""
  fi
}

# ----------------------------
# Deploy new container
# ----------------------------
deploy() {
  ACTIVE=$(active_slot)

  if [[ -z "$ACTIVE" || "$ACTIVE" == "$GREEN" ]]; then
    TARGET="$BLUE"
  else
    TARGET="$GREEN"
  fi

  log "Deploying $TARGET"

  docker rm -f "$TARGET" >/dev/null 2>&1 || true

  docker run -d \
    --name "$TARGET" \
    --network "$NETWORK" \
    -e NODE_ENV=production \
    -e PORT=$APP_PORT \
    "$IMAGE_TAG"

  echo "$TARGET"
}

# ----------------------------
# Wait until app is ready
# ----------------------------
wait_for_app() {
  local name="$1"

  log "Waiting for $name..."

  for i in {1..30}; do
    if docker exec "$name" sh -c "echo > /dev/tcp/127.0.0.1/$APP_PORT" 2>/dev/null; then
      log "App is ready"
      return 0
    fi
    sleep 1
  done

  echo "[deploy] app failed to start"
  exit 1
}

# ----------------------------
# Generate nginx config
# ----------------------------
write_nginx() {
  local target="$1"

  cat > "$NGINX_CONF" <<EOF
events {}

http {
  server {
    listen 80;

    location / {
      proxy_pass http://$target:$APP_PORT;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
  }
}
EOF
}

# ----------------------------
# Run nginx container
# ----------------------------
run_nginx() {
  docker rm -f "$NGINX_NAME" >/dev/null 2>&1 || true

  docker run -d \
    --name "$NGINX_NAME" \
    --network "$NETWORK" \
    -p 80:80 \
    -v "$(pwd)/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    nginx:alpine
}

# ----------------------------
# MAIN FLOW
# ----------------------------
ensure_network
build

TARGET=$(deploy)
wait_for_app "$TARGET"
write_nginx "$TARGET"
run_nginx

echo "[deploy] SUCCESS -> $TARGET"