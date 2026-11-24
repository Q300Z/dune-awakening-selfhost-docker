#!/usr/bin/env bash
set -euo pipefail

# Arrête proprement les serveurs Dune, supprime les conteneurs Compose
# (serveur + interface admin) et désactive les timers systemd utilisateur.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

echo "==> 1/3 Arrêt propre des serveurs de jeu (si actifs)..."
if [ -x "./runtime/scripts/dune" ]; then
  ./runtime/scripts/dune stop || true
fi

echo "==> 2/3 Arrêt et suppression des conteneurs (serveur + interface admin)..."
if command -v podman-compose >/dev/null 2>&1; then
  podman-compose -f docker-compose.yml -f docker-compose.web.yml down
elif command -v docker >/dev/null 2>&1; then
  docker compose -f docker-compose.yml -f docker-compose.web.yml down
else
  echo "Erreur : ni podman-compose ni docker n'a été trouvé." >&2
  exit 1
fi

echo "==> 3/3 Désactivation des timers systemd utilisateur..."
TIMERS=(
  "dune-awakening-auto-update.timer"
  "dune-awakening-db-backup.timer"
)
if command -v systemctl >/dev/null 2>&1; then
  for timer in "${TIMERS[@]}"; do
    if systemctl --user list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
      systemctl --user disable --now "$timer" || true
    fi
  done
fi

echo "==> Terminé. État actuel :"
if command -v podman >/dev/null 2>&1; then
  podman ps -a --format "table {{.Names}}\t{{.Status}}" || true
elif command -v docker >/dev/null 2>&1; then
  docker ps -a --format "table {{.Names}}\t{{.Status}}" || true
fi
