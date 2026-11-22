#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${DUNE_RUNTIME_PERMISSIONS_REPAIRED:-0}" != "1" ]; then
  runtime/scripts/repair-host-runtime-permissions.sh
  export DUNE_RUNTIME_PERMISSIONS_REPAIRED=1
fi

[ -f .env ] && . ./.env
source runtime/scripts/host-paths.sh
[ -r runtime/scripts/runtime-env.sh ] && source runtime/scripts/runtime-env.sh

CONTAINER_NAME="dune-autoscaler"
IMAGE="dune-orchestrator:dev"
REPO_UID="$(stat -c '%u' .)"
REPO_GID="$(stat -c '%g' .)"
HOST_UID="${DUNE_HOST_UID:-$REPO_UID}"
HOST_GID="${DUNE_HOST_GID:-$REPO_GID}"
DOCKER_SOCK_GID="${DOCKER_SOCKET_GID:-}"
AUTOSCALER_CONTAINER_REPO_ROOT="/repo"
HOST_REPO_ROOT="$(host_path "$PWD")"

if [ "$HOST_UID" = "0" ] && [ "$REPO_UID" != "0" ]; then
  HOST_UID="$REPO_UID"
fi
if [ "$HOST_GID" = "0" ] && [ "$REPO_GID" != "0" ]; then
  HOST_GID="$REPO_GID"
fi

DOCKER_SOCK_PATH="$(dune_docker_socket_path)"
HOST_DOCKER_SOCK="${DUNE_DOCKER_SOCKET:-$DOCKER_SOCK_PATH}"
if [ -z "$DOCKER_SOCK_GID" ] && [ -S "$DOCKER_SOCK_PATH" ]; then
  DOCKER_SOCK_GID="$(stat -c '%g' "$DOCKER_SOCK_PATH" 2>/dev/null || true)"
fi

mkdir -p runtime/generated runtime/logs

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Autoscaler already running: $CONTAINER_NAME"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if ! docker ps --format '{{.Names}}' | grep -qx dune-director; then
  echo "Cannot start autoscaler: dune-director is not running."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx dune-postgres; then
  echo "Cannot start autoscaler: dune-postgres is not running."
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Cannot start autoscaler: Docker image not found: $IMAGE"
  echo "Start or build the orchestrator first:"
  echo "  docker compose up -d --build orchestrator"
  exit 1
fi

# autoscaler.sh reads its configuration from the environment and never sources
# .env itself, so anything an operator sets there has to be handed over here.
# The scan intervals were silently inert before this; POSTGRES_PORT and
# DUNE_PSQL_TRANSPORT decide which port the in-container psql client dials and
# whether it dials one at all. An unset value is passed through as empty, which
# every consumer treats as "use the default".
echo "Starting autoscaler container..."
group_args=()
RUN_USER="${HOST_UID}:${HOST_GID}"
if dune_is_rootless_podman; then
  # En Podman rootless via socket REST, 0:0 correspond à l'UID hôte (tboutin).
  RUN_USER="0:0"
elif [ -n "$DOCKER_SOCK_GID" ]; then
  group_args+=(--group-add "$DOCKER_SOCK_GID")
fi

docker run -d \
  "${DUNE_DOCKER_LOG_ARGS[@]}" \
  --name "$CONTAINER_NAME" \
  --network host \
  --restart unless-stopped \
  --user "$RUN_USER" \
  "${group_args[@]}" \
  --entrypoint bash \
  -e "DUNE_CONTAINER_REPO_ROOT=$AUTOSCALER_CONTAINER_REPO_ROOT" \
  -e "DUNE_HOST_REPO_ROOT=$HOST_REPO_ROOT" \
  -e "DUNE_ROOTLESS_PODMAN=${DUNE_ROOTLESS_PODMAN:-0}" \
  -e "DUNE_DOCKER_SOCKET=$HOST_DOCKER_SOCK" \
  -e "DUNE_AUTOSCALER_INTERVAL=${DUNE_AUTOSCALER_INTERVAL:-}" \
  -e "DUNE_AUTOSCALER_DEMAND_INTERVAL=${DUNE_AUTOSCALER_DEMAND_INTERVAL:-}" \
  -e "DUNE_AUTOSCALER_CHAT_EXCHANGE_REPAIR_SECONDS=${DUNE_AUTOSCALER_CHAT_EXCHANGE_REPAIR_SECONDS:-}" \
  -e "DUNE_AUTOSCALER_CHAT_EXCHANGE_REPAIR_TIMEOUT_SECONDS=${DUNE_AUTOSCALER_CHAT_EXCHANGE_REPAIR_TIMEOUT_SECONDS:-}" \
  -e "POSTGRES_PORT=${POSTGRES_PORT:-}" \
  -e "DUNE_PSQL_TRANSPORT=${DUNE_PSQL_TRANSPORT:-}" \
  -v "$HOST_DOCKER_SOCK:/var/run/docker.sock" \
  -v "$HOST_REPO_ROOT:$AUTOSCALER_CONTAINER_REPO_ROOT" \
  -w "$AUTOSCALER_CONTAINER_REPO_ROOT" \
  "$IMAGE" \
  runtime/scripts/autoscaler.sh >/dev/null

echo "Autoscaler started: $CONTAINER_NAME"
echo "Logs:"
echo "  dune autoscaler logs"
