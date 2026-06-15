#!/usr/bin/env bash
set -Eeuo pipefail

APP_PORT="${APP_PORT:-3000}"
IMAGE_NAME="${IMAGE_NAME:-my-nextjs-app}"
BLUE_NAME="${BLUE_NAME:-nextjs_blue}"
GREEN_NAME="${GREEN_NAME:-nextjs_green}"
BLUE_HOST_PORT="${BLUE_HOST_PORT:-${BLUE_PORT:-3000}}"
GREEN_HOST_PORT="${GREEN_HOST_PORT:-${GREEN_PORT:-3001}}"
PUBLISH_SLOT_PORTS="${PUBLISH_SLOT_PORTS:-false}"
NGINX_NAME="${NGINX_NAME:-nginx}"
DOCKER_NETWORK="${DOCKER_NETWORK:-devsopserver_net}"
HOST_HTTP_PORT="${HOST_HTTP_PORT:-80}"
HEALTH_PATH="${HEALTH_PATH:-/}"
PUBLIC_URL="${PUBLIC_URL:-}"
LEGACY_APP_CONTAINERS="${LEGACY_APP_CONTAINERS:-nextjs nextjs_new}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF="${SCRIPT_DIR}/nginx/nginx.conf"
COMMIT_SHA="${GITHUB_SHA:-local-$(date +%Y%m%d%H%M%S)}"
SHORT_SHA="${COMMIT_SHA:0:12}"
IMAGE_TAG="${IMAGE_NAME}:${SHORT_SHA}"

case "$HEALTH_PATH" in
  /*) ;;
  *) HEALTH_PATH="/${HEALTH_PATH}" ;;
esac

log() {
  printf '[deploy] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$1"
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-2}"
  local status=""

  for _ in $(seq 1 "$attempts"); do
    status="$(curl -k -s -H 'ngrok-skip-browser-warning: true' -o /dev/null -w '%{http_code}' "$url" || true)"

    if [[ "$status" =~ ^[0-9]{3}$ ]] && [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
      log "$label is healthy at $url ($status)"
      return 0
    fi

    sleep "$delay"
  done

  log "$label is not healthy at $url (last status: ${status:-none})"
  return 1
}

wait_for_container() {
  local container="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-2}"
  local url="http://127.0.0.1:${APP_PORT}${HEALTH_PATH}"
  local js='fetch(process.argv[1]).then((r) => process.exit(r.status >= 200 && r.status < 400 ? 0 : 1)).catch(() => process.exit(1))'

  for _ in $(seq 1 "$attempts"); do
    if docker exec "$container" node -e "$js" "$url" >/dev/null 2>&1; then
      log "$label is healthy inside the container"
      return 0
    fi

    sleep "$delay"
  done

  log "$label did not become healthy inside the container"
  return 1
}

ensure_network() {
  if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    log "Creating Docker network: $DOCKER_NETWORK"
    docker network create "$DOCKER_NETWORK" >/dev/null
  fi
}

detect_active_slot() {
  local active=""

  if [ -f "$NGINX_CONF" ]; then
    if grep -Fq "set \$nextjs_upstream \"${BLUE_NAME}:${APP_PORT}\";" "$NGINX_CONF" && container_running "$BLUE_NAME"; then
      active="$BLUE_NAME"
    elif grep -Fq "set \$nextjs_upstream \"${GREEN_NAME}:${APP_PORT}\";" "$NGINX_CONF" && container_running "$GREEN_NAME"; then
      active="$GREEN_NAME"
    fi
  fi

  if [ -z "$active" ] && container_running "$BLUE_NAME"; then
    active="$BLUE_NAME"
  elif [ -z "$active" ] && container_running "$GREEN_NAME"; then
    active="$GREEN_NAME"
  fi

  printf '%s' "$active"
}

write_nginx_conf() {
  local upstream_name="$1"

  mkdir -p "$(dirname "$NGINX_CONF")"
  cat > "$NGINX_CONF" <<NGINX
events {}

http {
    server {
        listen 80;
        server_name _;

        resolver 127.0.0.11 ipv6=off valid=10s;
        set \$nextjs_upstream "${upstream_name}:${APP_PORT}";

        location / {
            proxy_pass http://\$nextjs_upstream;
            proxy_http_version 1.1;

            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
NGINX
}

nginx_has_config_mount() {
  local mount_source=""
  local expected_source=""

  expected_source="$(cd "$(dirname "$NGINX_CONF")" && pwd)/$(basename "$NGINX_CONF")"
  mount_source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/nginx/nginx.conf"}}{{.Source}}{{end}}{{end}}' "$NGINX_NAME" 2>/dev/null || true)"
  [ "$mount_source" = "$expected_source" ]
}

start_or_reload_nginx() {
  if container_exists "$NGINX_NAME"; then
    if ! nginx_has_config_mount; then
      log "Recreating nginx so it uses ${NGINX_CONF}"
      docker rm -f "$NGINX_NAME" >/dev/null 2>&1 || true
    else
      docker network connect "$DOCKER_NETWORK" "$NGINX_NAME" >/dev/null 2>&1 || true

      if container_running "$NGINX_NAME"; then
        if docker exec "$NGINX_NAME" nginx -s reload >/dev/null 2>&1; then
          log "Reloaded nginx"
          return 0
        fi
      fi

      docker restart "$NGINX_NAME" >/dev/null
      log "Restarted nginx"
      return 0
    fi
  fi

  log "Starting nginx on host port ${HOST_HTTP_PORT}"
  docker run -d \
    --name "$NGINX_NAME" \
    --restart unless-stopped \
    --network "$DOCKER_NETWORK" \
    -p "${HOST_HTTP_PORT}:80" \
    -v "${NGINX_CONF}:/etc/nginx/nginx.conf:ro" \
    nginx:alpine >/dev/null
}

route_nginx_to() {
  local upstream_name="$1"

  write_nginx_conf "$upstream_name"
  docker run --rm \
    -v "${NGINX_CONF}:/etc/nginx/nginx.conf:ro" \
    nginx:alpine nginx -t >/dev/null
  start_or_reload_nginx
}

cleanup_legacy_app_containers() {
  local name=""

  for name in $LEGACY_APP_CONTAINERS; do
    if [ "$name" != "$BLUE_NAME" ] && [ "$name" != "$GREEN_NAME" ] && container_exists "$name"; then
      log "Removing legacy app container: $name"
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
}

rollback() {
  local reason="$1"

  log "Deploy failed: $reason"

  if [ -n "${ACTIVE_NAME:-}" ] && container_running "$ACTIVE_NAME"; then
    log "Rolling nginx back to $ACTIVE_NAME"
    route_nginx_to "$ACTIVE_NAME" || true
    wait_for_http "http://127.0.0.1:${HOST_HTTP_PORT}${HEALTH_PATH}" "rollback nginx" 10 2 || true
  fi

  if [ -n "${TARGET_NAME:-}" ]; then
    docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true
  fi

  exit 1
}

require_command docker
require_command curl

cd "$SCRIPT_DIR"
docker info >/dev/null
ensure_network

ACTIVE_NAME="$(detect_active_slot)"

if [ "$ACTIVE_NAME" = "$BLUE_NAME" ]; then
  TARGET_NAME="$GREEN_NAME"
  TARGET_HOST_PORT="$GREEN_HOST_PORT"
else
  TARGET_NAME="$BLUE_NAME"
  TARGET_HOST_PORT="$BLUE_HOST_PORT"
fi

log "Dev stage: building ${IMAGE_TAG}"
docker build -t "$IMAGE_TAG" -t "${IMAGE_NAME}:latest" .

log "Ops stage: deploying ${TARGET_NAME}"
docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true

PUBLISH_ARGS=()
if [ "$PUBLISH_SLOT_PORTS" = "true" ]; then
  PUBLISH_ARGS=(-p "127.0.0.1:${TARGET_HOST_PORT}:${APP_PORT}")
  log "Publishing ${TARGET_NAME} on 127.0.0.1:${TARGET_HOST_PORT}"
fi

docker run -d \
  --name "$TARGET_NAME" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  --label "com.devsopserver.app=${IMAGE_NAME}" \
  --label "com.devsopserver.git_sha=${COMMIT_SHA}" \
  -e NODE_ENV=production \
  -e PORT="$APP_PORT" \
  -e HOSTNAME=0.0.0.0 \
  "${PUBLISH_ARGS[@]}" \
  "$IMAGE_TAG" >/dev/null

wait_for_container "$TARGET_NAME" "$TARGET_NAME" || rollback "new app container failed health check"

route_nginx_to "$TARGET_NAME" || rollback "nginx could not route to $TARGET_NAME"
wait_for_http "http://127.0.0.1:${HOST_HTTP_PORT}${HEALTH_PATH}" "local nginx" || rollback "local nginx health check failed"

if [ -n "$PUBLIC_URL" ]; then
  wait_for_http "${PUBLIC_URL%/}${HEALTH_PATH}" "public ngrok URL" 20 3 || rollback "public ngrok health check failed"
else
  log "PUBLIC_URL is not set; skipping ngrok health check"
fi

if [ -n "$ACTIVE_NAME" ] && [ "$ACTIVE_NAME" != "$TARGET_NAME" ] && container_exists "$ACTIVE_NAME"; then
  log "Removing previous slot: $ACTIVE_NAME"
  docker rm -f "$ACTIVE_NAME" >/dev/null 2>&1 || true
fi

cleanup_legacy_app_containers

log "Deploy success"
log "Active slot: $TARGET_NAME"
log "Local URL: http://127.0.0.1:${HOST_HTTP_PORT}"
if [ -n "$PUBLIC_URL" ]; then
  log "Public URL: ${PUBLIC_URL}"
fi
