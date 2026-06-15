#!/usr/bin/env bash
set -Eeuo pipefail

APP_PORT="${APP_PORT:-3000}"
IMAGE_NAME="${IMAGE_NAME:-my-nextjs-app}"

BLUE_NAME="nextjs_blue"
GREEN_NAME="nextjs_green"

NGINX_NAME="nginx"
DOCKER_NETWORK="devopsserver_net"

HOST_HTTP_PORT="80"
HEALTH_PATH="/"

COMMIT_SHA="${GITHUB_SHA:-local-$(date +%Y%m%d%H%M%S)}"
IMAGE_TAG="${IMAGE_NAME}:${COMMIT_SHA:0:12}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF="${SCRIPT_DIR}/nginx/nginx.conf"

log() { echo "[deploy] $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing: $1"
    exit 1
  }
}

# ---------------------------
# NETWORK (CRITICAL FIX)
# ---------------------------
ensure_network() {
  if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    log "Creating network $DOCKER_NETWORK"
    docker network create "$DOCKER_NETWORK" >/dev/null
  fi
}

# ---------------------------
# BUILD
# ---------------------------
log "Building image $IMAGE_TAG"
docker build --no-cache -t "$IMAGE_TAG" -t "${IMAGE_NAME}:latest" .

# ---------------------------
# SLOT LOGIC (FIXED)
# ---------------------------
ACTIVE=""
if docker ps --format '{{.Names}}' | grep -q "$BLUE_NAME"; then
  ACTIVE="$BLUE_NAME"
elif docker ps --format '{{.Names}}' | grep -q "$GREEN_NAME"; then
  ACTIVE="$GREEN_NAME"
fi

if [ "$ACTIVE" = "$BLUE_NAME" ]; then
  TARGET="$GREEN_NAME"
else
  TARGET="$BLUE_NAME"
fi

log "Active: $ACTIVE"
log "Deploying: $TARGET"

# ---------------------------
# CLEAN OLD TARGET
# ---------------------------
docker rm -f "$TARGET" >/dev/null 2>&1 || true

# ---------------------------
# RUN NEW APP
# ---------------------------
docker run -d \
  --name "$TARGET" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  -e NODE_ENV=production \
  -e PORT="$APP_PORT" \
  -e HOSTNAME=0.0.0.0 \
  "$IMAGE_TAG" >/dev/null

# ---------------------------
# HEALTH CHECK (container)
# ---------------------------
log "Waiting for $TARGET"

for i in {1..30}; do
  if docker exec "$TARGET" wget -qO- "http://localhost:$APP_PORT$HEALTH_PATH" >/dev/null 2>&1; then
    log "$TARGET healthy"
    break
  fi
  sleep 2
done

# ---------------------------
# FIXED NGINX CONFIG
# ---------------------------
log "Updating nginx config"

cat > "$NGINX_CONF" <<EOF
events {}

http {
  server {
    listen 80;

    resolver 127.0.0.11 ipv6=off;

    set \$upstream "$TARGET:$APP_PORT";

    location / {
      proxy_pass http://\$upstream;

      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
    }
  }
}
EOF

# ---------------------------
# START / RELOAD NGINX
# ---------------------------
if docker ps --format '{{.Names}}' | grep -q "$NGINX_NAME"; then
  docker exec "$NGINX_NAME" nginx -s reload || docker restart "$NGINX_NAME"
else
  docker run -d \
    --name "$NGINX_NAME" \
    --restart unless-stopped \
    --network "$DOCKER_NETWORK" \
    -p "$HOST_HTTP_PORT:80" \
    -v "$NGINX_CONF:/etc/nginx/nginx.conf:ro" \
    nginx:alpine >/dev/null
fi

# ensure network attach
docker network connect "$DOCKER_NETWORK" "$NGINX_NAME" >/dev/null 2>&1 || true

# ---------------------------
# FINAL VALIDATION
# ---------------------------
log "Validating nginx → app"

sleep 3

docker exec "$NGINX_NAME" wget -qO- "http://$TARGET:$APP_PORT$HEALTH_PATH" >/dev/null \
  || {
    echo "[ERROR] nginx cannot reach $TARGET"
    exit 1
  }

# ---------------------------
# CLEAN OLD SLOT
# ---------------------------
if [ -n "$ACTIVE" ] && [ "$ACTIVE" != "$TARGET" ]; then
  log "Removing old slot $ACTIVE"
  docker rm -f "$ACTIVE" >/dev/null 2>&1 || true
fi

log "DEPLOY SUCCESS"
log "Active: $TARGET"
log "URL: http://localhost:$HOST_HTTP_PORT"