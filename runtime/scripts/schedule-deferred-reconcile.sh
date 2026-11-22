#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

[ -r ./.env ] && { set -a; . ./.env; set +a; }

# Starts the deferred dimension reconcile so that it OUTLIVES the console.
#
# It used to be a background job of start-all.sh, which the console runs inside
# its own container. `dune console reload` is `docker rm -f` on that container,
# so anything start-all backgrounded died with it -- and the reconcile is a wait
# that can legitimately run for minutes while Survival_1 warms up. A system
# restore reloads the console seconds after starting the stack, so the wait was
# killed every time and the second Sietch of a multi-dimension map never
# spawned. Nothing reported it: the wait prints nothing until it finishes, and
# deferred-reconcile.sh calls the reconcile with `|| true`.
#
# The helper is a detached container, so a console recreate cannot reach it. It
# needs the repo and the docker socket because the reconcile spawns game
# servers, and it needs the host-path translation environment because
# spawn-server.sh refuses to build bind mounts without it.

LOG_FILE="runtime/generated/deferred-reconcile.log"
HELPER_NAME="${DUNE_DEFERRED_RECONCILE_CONTAINER:-dune-deferred-reconcile}"

run_in_process() {
  mkdir -p runtime/generated
  (
    exec runtime/scripts/deferred-reconcile.sh
  ) >"$LOG_FILE" 2>&1 &
}

helper_image() {
  printf '%s' "${DUNE_SYSTEMD_HELPER_IMAGE:-redblink-dune-docker-console:dev}"
}

mkdir -p runtime/generated

image="$(helper_image)"
host_root="${DUNE_HOST_REPO_ROOT:-$(pwd -P)}"

# A host CLI run has no console image and no container to be killed by, so the
# original in-process job is correct there. Falling back rather than skipping
# keeps `dune start` from silently losing the reconcile on those hosts.
if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Scheduling deferred dimension reconcile in-process (no console helper image)."
  run_in_process
  exit 0
fi

# One at a time. A previous run still waiting would otherwise race this one into
# spawning the same partition twice.
docker rm -f "$HELPER_NAME" >/dev/null 2>&1 || true

is_rootless_podman=0
if [ "${DUNE_ROOTLESS_PODMAN:-}" = "1" ]; then
  is_rootless_podman=1
elif [ "${DUNE_ROOTLESS_PODMAN:-}" = "0" ]; then
  is_rootless_podman=0
elif [ -f /run/.containerenv ] && grep -q '^rootless=1' /run/.containerenv 2>/dev/null; then
  is_rootless_podman=1
elif command -v podman >/dev/null 2>&1; then
  _docker_bin="$(command -v docker 2>/dev/null || true)"
  if [ -n "$_docker_bin" ] && grep -q '/usr/bin/podman' "$_docker_bin" 2>/dev/null; then
    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qx 'true'; then
      is_rootless_podman=1
    fi
  fi
fi
host_docker_sock="${DUNE_DOCKER_SOCKET:-/var/run/docker.sock}"
run_user_args=(--user "${DUNE_HOST_UID:-0}:${DUNE_HOST_GID:-0}" --group-add "${DOCKER_SOCKET_GID:-0}")
if [ "$is_rootless_podman" = "1" ]; then
  run_user_args=(--user 0:0)
  if [ -z "${DUNE_DOCKER_SOCKET:-}" ]; then
    _podman_sock="/run/user/${DUNE_HOST_UID:-$(id -u)}/podman/podman.sock"
    [ -S "$_podman_sock" ] && host_docker_sock="$_podman_sock"
  fi
fi

if ! docker run -d --rm --name "$HELPER_NAME" \
  --network host \
  "${run_user_args[@]}" \
  -v "$host_root:/repo" \
  -v "$host_docker_sock:/var/run/docker.sock" \
  -w /repo \
  -e HOME=/tmp/dune-deferred-home \
  -e DUNE_HOST_REPO_ROOT="$host_root" \
  -e DUNE_CONTAINER_REPO_ROOT=/repo \
  -e DUNE_SKIP_SURVIVAL_DIRECTOR_REFRESH="${DUNE_SKIP_SURVIVAL_DIRECTOR_REFRESH:-}" \
  -e DUNE_DOCKER_DIR=/repo \
  -e DUNE_HOST_UID="${DUNE_HOST_UID:-0}" \
  -e DUNE_HOST_GID="${DUNE_HOST_GID:-0}" \
  -e DOCKER_SOCKET_GID="${DOCKER_SOCKET_GID:-0}" \
  -e DUNE_ROOTLESS_PODMAN="${DUNE_ROOTLESS_PODMAN:-$is_rootless_podman}" \
  -e DUNE_DOCKER_SOCKET="$host_docker_sock" \
  -e COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}" \
  -e DUNE_COMPOSE_PROJECT_NAME="${DUNE_COMPOSE_PROJECT_NAME:-}" \
  --entrypoint bash \
  "$image" -lc "runtime/scripts/deferred-reconcile.sh > $LOG_FILE 2>&1" >/dev/null 2>&1; then
  echo "Could not start the deferred reconcile helper; running it in-process instead." >&2
  run_in_process
  exit 0
fi

echo "Deferred dimension reconcile running as container $HELPER_NAME (survives a console reload)."
