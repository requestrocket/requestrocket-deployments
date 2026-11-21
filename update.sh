#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

LOCK_FILE="/tmp/requestrocket-update.lock"
IMAGE_REPO="ghcr.io/requestrocket/data-plane"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another update is already running -- exiting"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to read config.json"
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is required for digest comparison"
  echo "Install it with: docker buildx install"
  exit 1
fi

if [ ! -f config.json ]; then
  echo "ERROR: config.json not found in $(pwd)"
  exit 1
fi

IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
if [ -z "$IMAGE_TAG" ] || [ "$IMAGE_TAG" = "null" ]; then
  IMAGE_TAG="latest"
fi
export IMAGE_TAG

IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
echo "Checking ${IMAGE}"

# The published image is often a manifest index (buildx provenance), and the
# running container records that index digest in RepoDigests. `docker manifest
# inspect` returns the child manifest digest, which would not match and would
# redeploy every tick. Ask buildx for the tag digest, and keep the child digest
# so a plain single-manifest image still matches.
REMOTE_DIGESTS=""

if INDEX_DIGEST="$(timeout 60 docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE")"; then
  if [ -n "$INDEX_DIGEST" ] && [ "$INDEX_DIGEST" != "null" ]; then
    REMOTE_DIGESTS="$INDEX_DIGEST"
  fi
else
  echo "WARNING: buildx imagetools inspect failed for ${IMAGE}"
fi

if MANIFEST_JSON="$(timeout 60 docker manifest inspect --verbose "$IMAGE" 2>/dev/null)"; then
  if CHILD_DIGEST="$(printf '%s\n' "$MANIFEST_JSON" | jq -r '
    if type == "array" then
      (.[0].Descriptor.digest // empty)
    elif .Descriptor.digest then
      .Descriptor.digest
    else
      empty
    end
  ')"; then
    if [ -n "$CHILD_DIGEST" ] && [ "$CHILD_DIGEST" != "null" ]; then
      REMOTE_DIGESTS="${REMOTE_DIGESTS}"$'\n'"${CHILD_DIGEST}"
    fi
  fi
fi

REMOTE_DIGESTS="$(printf '%s\n' "$REMOTE_DIGESTS" | sed '/^$/d')"
if [ -z "$REMOTE_DIGESTS" ]; then
  echo "ERROR: could not read a registry digest for ${IMAGE}"
  exit 1
fi

echo "Remote digest(s): $(printf '%s\n' "$REMOTE_DIGESTS" | tr '\n' ' ')"

detect_running() {
  if docker ps --format '{{.Names}}' | grep -q '^data-plane-blue$'; then
    echo "data-plane-blue"
  elif docker ps --format '{{.Names}}' | grep -q '^data-plane-green$'; then
    echo "data-plane-green"
  elif docker ps --format '{{.Names}}' | grep -q '^data-plane$'; then
    echo "data-plane"
  else
    echo "none"
  fi
}

RUNNING="$(detect_running)"

if [ "$RUNNING" != "none" ]; then
  IMAGE_ID="$(docker inspect --format '{{.Image}}' "$RUNNING")"
  LOCAL_DIGESTS="$(docker image inspect --format '{{json .RepoDigests}}' "$IMAGE_ID" 2>/dev/null || echo '[]')"
  while IFS= read -r REMOTE_DIGEST; do
    if [ -n "$REMOTE_DIGEST" ] && printf '%s\n' "$LOCAL_DIGESTS" | grep -q "$REMOTE_DIGEST"; then
      echo "Already running ${REMOTE_DIGEST}"
      exit 0
    fi
  done <<< "$REMOTE_DIGESTS"
  echo "${RUNNING} does not match the registry digest"
else
  echo "No data plane container is running"
fi

echo "Pulling ${IMAGE}"
if ! timeout 180 docker pull "$IMAGE"; then
  echo "ERROR: docker pull failed or timed out -- leaving the current container in place"
  exit 1
fi

exec ./deploy.sh --no-pull
