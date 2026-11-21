#!/usr/bin/env bash
set -euo pipefail

HEALTH_RETRIES=20
HEALTH_INTERVAL=3
SKIP_PULL=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --no-pull) SKIP_PULL=true ;;
  esac
done

check_health() {
  local container="$1"
  local status
  status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
  [ "$status" = "healthy" ]
}

wait_healthy() {
  local container="$1"
  echo "Waiting for $container to become healthy..."
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    if check_health "$container"; then
      echo "$container is healthy"
      return 0
    fi
    echo "  Attempt $i/$HEALTH_RETRIES -- not ready yet, retrying in ${HEALTH_INTERVAL}s..."
    sleep "$HEALTH_INTERVAL"
  done
  echo "ERROR: $container did not become healthy in time"
  return 1
}

detect_active_slot() {
  if docker ps --format '{{.Names}}' | grep -q "^data-plane-blue$"; then
    echo "blue"
  elif docker ps --format '{{.Names}}' | grep -q "^data-plane-green$"; then
    echo "green"
  else
    echo "none"
  fi
}

load_image_tag() {
  if [ -n "${IMAGE_TAG:-}" ]; then
    export IMAGE_TAG
    return
  fi
  if [ -f config.json ] && command -v jq >/dev/null 2>&1; then
    IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
  fi
  IMAGE_TAG="${IMAGE_TAG:-latest}"
  export IMAGE_TAG
}

main() {
  echo "=== Data Plane Blue-Green Deploy ==="
  load_image_tag
  echo "Image tag: $IMAGE_TAG"

  ACTIVE=$(detect_active_slot)
  echo "Currently active slot: $ACTIVE"

  if [ "$ACTIVE" = "blue" ]; then
    NEXT="green"
    NEXT_COMPOSE="docker-compose.green.yml"
    PREV_COMPOSE="docker-compose.blue.yml"
    NEXT_CONTAINER="data-plane-green"
    PREV_CONTAINER="data-plane-blue"
  elif [ "$ACTIVE" = "green" ]; then
    NEXT="blue"
    NEXT_COMPOSE="docker-compose.blue.yml"
    PREV_COMPOSE="docker-compose.green.yml"
    NEXT_CONTAINER="data-plane-blue"
    PREV_CONTAINER="data-plane-green"
  else
    echo "No active slot found -- doing initial deploy to blue"
    NEXT="blue"
    NEXT_COMPOSE="docker-compose.blue.yml"
    PREV_COMPOSE=""
    NEXT_CONTAINER="data-plane-blue"
    PREV_CONTAINER=""
  fi

  echo "Deploying to slot: $NEXT"

  if [ "$SKIP_PULL" = true ]; then
    echo "Skipping image pull (--no-pull)"
  else
    echo "Pulling latest image..."
    docker compose -f "$NEXT_COMPOSE" pull
  fi

  echo "Starting $NEXT_CONTAINER..."
  docker compose -f "$NEXT_COMPOSE" up -d

  if ! wait_healthy "$NEXT_CONTAINER"; then
    echo "Deploy failed -- rolling back"
    docker compose -f "$NEXT_COMPOSE" down
    exit 1
  fi

  if [ -n "$PREV_CONTAINER" ]; then
    echo "Stopping previous slot ($PREV_CONTAINER)..."
    docker compose -f "$PREV_COMPOSE" down
  fi

  # The bootstrap compose file starts a container named data-plane. It shares the
  # Traefik router name with the blue/green slots, so leave it running only until
  # the first slot is healthy. Stop that service alone -- a full compose down would
  # remove MongoDB, Traefik, and the network the new slot is using.
  if [ "$ACTIVE" = "none" ] && docker ps -a --format '{{.Names}}' | grep -q '^data-plane$'; then
    echo "Stopping bootstrap container (data-plane)..."
    docker compose stop data-plane
    docker compose rm -f data-plane
  fi

  echo "=== Deploy complete. Active slot: $NEXT ==="
}

main "$@"
