#!/usr/bin/env bash
set -euo pipefail

# Inverse de disable-all.sh : réactive les timers systemd utilisateur
# puis relance les conteneurs (orchestrateur + interface admin) et les serveurs de jeu.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

echo "==> 1/2 Réactivation des timers systemd utilisateur..."
TIMERS=(
  "dune-awakening-auto-update.timer"
  "dune-awakening-db-backup.timer"
)
if command -v systemctl >/dev/null 2>&1; then
  for timer in "${TIMERS[@]}"; do
    if systemctl --user list-unit-files "$timer" --no-legend 2>/dev/null | grep -q "$timer"; then
      systemctl --user enable --now "$timer" || echo "Attention : impossible d'activer $timer" >&2
    else
      echo "Timer introuvable, ignoré : $timer" >&2
    fi
  done
fi

echo "==> 2/2 Démarrage de Dune (conteneurs + serveurs de jeu)..."
# 'dune start' recrée l'orchestrateur et l'interface admin, puis lance les serveurs.
./runtime/scripts/dune start

echo "==> Terminé. État actuel :"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user list-timers "${TIMERS[@]}" --no-pager || true
fi
if command -v podman >/dev/null 2>&1; then
  podman ps -a --format "table {{.Names}}\t{{.Status}}" || true
elif command -v docker >/dev/null 2>&1; then
  docker ps -a --format "table {{.Names}}\t{{.Status}}" || true
fi
