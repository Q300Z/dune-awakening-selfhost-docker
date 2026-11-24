#!/usr/bin/env bash
set -euo pipefail

# Dossier personnel de l'hôte (pour les unités systemd --user). Dans la
# console, HOME vaut /tmp/dune-console-home : DUNE_HOST_HOME vient alors de .env.
DUNE_HOST_HOME="${DUNE_HOST_HOME:-$HOME}"
DUNE_USER_SYSTEMD_DIR="$DUNE_HOST_HOME/.config/systemd/user"

cd "$(dirname "$0")/../.."
ROOT_DIR="$(pwd)"
HOST_ROOT_DIR="${DUNE_HOST_REPO_ROOT:-$ROOT_DIR}"

STATE_FILE="runtime/generated/shutdown-protection.env"
SERVICE_NAME="dune-awakening-shutdown-protection.service"
SERVICE_FILE="$DUNE_USER_SYSTEMD_DIR/$SERVICE_NAME"
LOG_FILE="runtime/generated/shutdown-protection.log"

usage() {
  cat <<'EOF'
Usage:
  dune shutdown-protection enable
  dune shutdown-protection disable
  dune shutdown-protection remove
  dune shutdown-protection refresh
  dune shutdown-protection status
  dune shutdown-protection run-stop
EOF
}

write_state() {
  local enabled="$1"
  local installed="${2:-${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-0}}"
  local tmp

  mkdir -p runtime/generated
  tmp="${STATE_FILE}.$$"
  cat > "$tmp" <<EOF
DUNE_SHUTDOWN_PROTECTION_ENABLED=$enabled
DUNE_SHUTDOWN_PROTECTION_INSTALLED=$installed
EOF
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$STATE_FILE"
}

read_state() {
  DUNE_SHUTDOWN_PROTECTION_ENABLED=0
  DUNE_SHUTDOWN_PROTECTION_INSTALLED=""
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

can_manage_systemd_units() {
  mkdir -p "$DUNE_USER_SYSTEMD_DIR" 2>/dev/null && [ -d "$DUNE_USER_SYSTEMD_DIR" ] && [ -w "$DUNE_USER_SYSTEMD_DIR" ]
}

can_write_log() {
  [ -w "$LOG_FILE" ] || { [ ! -e "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; }
}

log_event() {
  local message="$1"
  if can_write_log; then
    echo "[$(date -Is)] $message" >> "$LOG_FILE" 2>/dev/null || true
  else
    echo "[$(date -Is)] $message"
  fi
}

docker_helper_image() {
  printf '%s' "${DUNE_SYSTEMD_HELPER_IMAGE:-redblink-dune-docker-console:dev}"
}

can_manage_host_systemd_with_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local sock="/run/user/${DUNE_HOST_UID:-$(id -u)}/podman/podman.sock"
  if [ -n "${DUNE_DOCKER_SOCKET:-}" ] && [ -S "${DUNE_DOCKER_SOCKET}" ]; then
    sock="${DUNE_DOCKER_SOCKET}"
  elif [ ! -S "$sock" ]; then
    sock="/var/run/docker.sock"
  fi
  [ -S "$sock" ] || return 1
  docker image inspect "$(docker_helper_image)" >/dev/null 2>&1 || return 1
}

# DefaultDependencies=no drops the implicit Conflicts=shutdown.target, and
# without it systemd never queues a stop job, so ExecStop would not run before
# the final SIGTERM sweep. Before= alone only orders; it does not stop the unit.
unit_content() {
  local exec_root="$1"
  cat <<EOF
[Unit]
Description=Dune Docker Console clean shutdown protection
Documentation=https://github.com/Red-Blink/dune-awakening-selfhost-docker
DefaultDependencies=no
Wants=podman.socket
After=podman.socket
Conflicts=shutdown.target
Before=shutdown.target reboot.target halt.target kexec.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$exec_root
ExecStart=/bin/true
ExecStop=$exec_root/runtime/scripts/shutdown-protection.sh run-stop
TimeoutStopSec=240

[Install]
WantedBy=default.target
EOF
}

install_unit() {
  mkdir -p "$DUNE_USER_SYSTEMD_DIR"
  unit_content "$HOST_ROOT_DIR" > "$SERVICE_FILE"
}

install_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    -e DUNE_HOST_HOME="$DUNE_HOST_HOME" \
    -e DUNE_SHUTDOWN_UNIT_CONTENT="$(unit_content "$HOST_ROOT_DIR")" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      systemd_dir=/host${DUNE_HOST_HOME}/.config/systemd/user
      mkdir -p "$systemd_dir"
      printf "%s\n" "$DUNE_SHUTDOWN_UNIT_CONTENT" > "$systemd_dir/dune-awakening-shutdown-protection.service"
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user daemon-reload
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user enable --now dune-awakening-shutdown-protection.service
    '
}

disable_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user disable --now dune-awakening-shutdown-protection.service >/dev/null 2>&1 || true
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user daemon-reload
    '
}

remove_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    -e DUNE_HOST_HOME="$DUNE_HOST_HOME" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user disable --now dune-awakening-shutdown-protection.service >/dev/null 2>&1 || true
      rm -f /host${DUNE_HOST_HOME}/.config/systemd/user/dune-awakening-shutdown-protection.service
      env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user daemon-reload
    '
}

show_host_status_via_docker() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      if env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user list-unit-files dune-awakening-shutdown-protection.service --no-legend --no-pager 2>/dev/null | grep -q "^dune-awakening-shutdown-protection.service"; then
        active="$(env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user is-active dune-awakening-shutdown-protection.service 2>/dev/null || true)"
        enabled="$(env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus chroot /host /bin/systemctl --user is-enabled dune-awakening-shutdown-protection.service 2>/dev/null || true)"
        echo "Systemd service:         ${active:-unknown}"
        echo "Systemd enabled:         ${enabled:-unknown}"
      else
        echo "Systemd service:         not installed"
        echo "Systemd enabled:         disabled"
      fi
    '
}

enable_protection() {
  if ! command -v systemctl >/dev/null 2>&1; then
    if install_unit_via_docker_host; then
      write_state 1 1
      echo "Shutdown protection enabled."
      echo "Service: $SERVICE_NAME"
      return 0
    fi
    write_state 0 0
    echo "Shutdown protection could not be installed because env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user was not found and the host service could not be installed through Docker."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh enable"
    return 1
  fi

  if ! can_manage_systemd_units; then
    if install_unit_via_docker_host; then
      write_state 1 1
      echo "Shutdown protection enabled."
      echo "Service: $SERVICE_NAME"
      return 0
    fi
    write_state 0 0
    echo "Shutdown protection could not be installed because this user cannot write systemd units."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh enable"
    return 1
  fi

  install_unit
  env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user daemon-reload
  env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user enable --now "$SERVICE_NAME"
  write_state 1 1

  echo "Shutdown protection enabled."
  echo "Service: $SERVICE_NAME"
}

# Rewrites the unit on hosts that already have protection on, so a unit fix
# reaches them on update. Never touches the state file: a failure here must
# not silently turn protection off.
refresh_protection() {
  read_state
  if [ "${DUNE_SHUTDOWN_PROTECTION_ENABLED:-0}" != "1" ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && can_manage_systemd_units; then
    install_unit
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user daemon-reload
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user enable "$SERVICE_NAME"
    echo "Shutdown protection service refreshed."
  elif install_unit_via_docker_host; then
    echo "Shutdown protection service refreshed."
  else
    echo "Shutdown protection service could not be refreshed from this environment."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh refresh"
    return 1
  fi
}

disable_protection() {
  read_state
  write_state 0 "${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-1}"
  if command -v systemctl >/dev/null 2>&1 && can_manage_systemd_units; then
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user daemon-reload
    write_state 0 1
  elif can_manage_host_systemd_with_docker; then
    disable_unit_via_docker_host
    write_state 0 1
  else
    echo "Shutdown protection could not be disabled because the host systemd service cannot be managed from this environment."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh disable"
    return 1
  fi

  echo "Shutdown protection disabled."
}

remove_protection() {
  write_state 0 0
  if command -v systemctl >/dev/null 2>&1 && can_manage_systemd_units; then
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user daemon-reload
    write_state 0 0
  elif can_manage_host_systemd_with_docker; then
    remove_unit_via_docker_host
    write_state 0 0
  else
    echo "Shutdown protection could not be removed because the host systemd service cannot be managed from this environment."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh remove"
    return 1
  fi

  echo "Shutdown protection removed."
}

show_status() {
  read_state
  local enabled_text="false"
  local installed_text="${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-}"

  if [ "${DUNE_SHUTDOWN_PROTECTION_ENABLED:-0}" = "1" ]; then
    enabled_text="true"
  fi
  if [ -z "$installed_text" ] && [ "$enabled_text" = "true" ]; then
    installed_text=1
  fi

  echo "Shutdown protection enabled: $enabled_text"
  echo "Unit file:                   $SERVICE_NAME"
  echo "Clean stop command:          $HOST_ROOT_DIR/runtime/scripts/shutdown-protection.sh run-stop"
  echo "Timeout:                     240 seconds"
  echo "Manual install command:      sudo $HOST_ROOT_DIR/runtime/scripts/shutdown-protection.sh enable"

  if [ "$installed_text" = "1" ]; then
    if [ "$enabled_text" = "true" ]; then
      echo
      echo "Systemd service:         active"
      echo "Systemd enabled:         enabled"
    else
      echo
      echo "Systemd service:         inactive"
      echo "Systemd enabled:         disabled"
    fi
    return 0
  fi

  echo
  if command -v systemctl >/dev/null 2>&1; then
    if env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user list-unit-files "$SERVICE_NAME" --no-legend --no-pager 2>/dev/null | grep -q "^$SERVICE_NAME"; then
      active="$(env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
      enabled="$(env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
      echo "Systemd service:         ${active:-unknown}"
      echo "Systemd enabled:         ${enabled:-unknown}"
    else
      echo "Systemd service:         not installed"
      echo "Systemd enabled:         disabled"
    fi
  else
    show_host_status_via_docker || {
      echo "Systemd service:         not installed"
      echo "Systemd enabled:         disabled"
    }
  fi
}

run_stop() {
  mkdir -p runtime/generated
  read_state
  if [ "${DUNE_SHUTDOWN_PROTECTION_ENABLED:-0}" != "1" ]; then
    log_event "Host shutdown protection clean stop skipped because protection is disabled."
    return 0
  fi
  if can_write_log; then
    {
      echo "[$(date -Is)] Host shutdown protection clean stop started."
      runtime/scripts/stop-all.sh
      echo "[$(date -Is)] Host shutdown protection clean stop finished."
    } >> "$LOG_FILE" 2>&1
  else
    echo "[$(date -Is)] Host shutdown protection clean stop started."
    runtime/scripts/stop-all.sh
    echo "[$(date -Is)] Host shutdown protection clean stop finished."
  fi
}

cmd="${1:-status}"

case "$cmd" in
  help|--help|-h)
    usage
    ;;
  enable|on)
    enable_protection
    ;;
  disable|off)
    disable_protection
    ;;
  remove|uninstall)
    remove_protection
    ;;
  refresh)
    refresh_protection
    ;;
  status)
    show_status
    ;;
  run-stop)
    run_stop
    ;;
  *)
    usage
    exit 2
    ;;
esac
