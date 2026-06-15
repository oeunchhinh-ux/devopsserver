#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────
NETWORK="nextjs_net"
IMAGE="my-nextjs-app:latest"
APP_PORT=3000
BLUE="nextjs_blue"
GREEN="nextjs_green"
NGINX="nginx_proxy"

# ── Helpers ───────────────────────────────────────────
log() { echo "[deploy] $*" >&2; }

ensure_network() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || docker network create "$NETWORK"
}

build() {
  docker build -t "$IMAGE" .
}

active_slot() {
  if docker ps --format '{{.Names}}' | grep -q "^${BLUE}$"; then
    echo "blue"
  elif docker ps --format '{{.Names}}' | grep -q "^${GREEN}$"; then
    echo "green"
  else
    echo "none"
  fi
}

start_container() {
  local name="$1"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$name" \
    --network "$NETWORK" \
    -e NODE_ENV=production \
    -e PORT=$APP_PORT \
    -e DEPLOY_SLOT="${name##nextjs_}" \
    "$IMAGE"
  log "Started $name"
}

wait_for_app() {
  local name="$1"
  log "Waiting for $name to be ready..."
  for i in $(seq 1 30); do
    if docker exec "$name" node -e \
      "const h=require('http');h.get('http://localhost:3000/',(r)=>{process.exit(r.statusCode<400?0:1)}).on('error',()=>process.exit(1))" \
      >/dev/null 2>&1; then
      log "$name is ready"
      return 0
    fi
    sleep 2
  done
  log "ERROR: $name failed to become ready"
  docker logs "$name" --tail 20 >&2
  exit 1
}

start_nginx() {
  local target="$1"
  docker rm -f "$NGINX" >/dev/null 2>&1 || true

  # Write nginx config with correct upstream
  local conf="/tmp/nginx_active.conf"
  cat > "$conf" << EOF
upstream nextjs_upstream {
    server ${target}:${APP_PORT};
    keepalive 32;
}
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass         http://nextjs_upstream;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade     \$http_upgrade;
        proxy_set_header   Connection  "upgrade";
        proxy_set_header   Host        \$host;
        proxy_set_header   X-Real-IP   \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF

  docker run -d \
    --name "$NGINX" \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 80:80 \
    -v "$conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine
  log "Nginx started → $target"
}

stop_old() {
  local old="$1"
  if [ -n "$old" ] && [ "$old" != "none" ]; then
    local container="nextjs_${old}"
    docker rm -f "$container" >/dev/null 2>&1 || true
    log "Removed old slot: $container"
  fi
}

# ── Main ──────────────────────────────────────────────
ensure_network

CURRENT=$(active_slot)
log "Current slot: $CURRENT"

if [ "$CURRENT" = "blue" ]; then
  NEW_CONTAINER="$GREEN"
else
  NEW_CONTAINER="$BLUE"
fi

log "Deploying to: $NEW_CONTAINER"

build
start_container "$NEW_CONTAINER"
wait_for_app "$NEW_CONTAINER"
start_nginx "$NEW_CONTAINER"
stop_old "$CURRENT"

echo ""
echo "[deploy] SUCCESS -> $NEW_CONTAINER is live on port 80"
