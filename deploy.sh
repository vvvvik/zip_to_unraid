#!/bin/bash
# =============================================================================
# deploy.sh — задеплоїти актуальні backup_*_tower.sh з git на Synology (Leo/MA)
# Запускати з макбука, з клону цього репо.
# =============================================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_PATH="/volume1/scripts/"

MA_HOST="viik@leo-ma-ds920.tail0206.ts.net"   # MA + SuperHumans (спільний Synology)
LEO_HOST="viik@leo-ds718.tail0206.ts.net"     # Leo

cd "$REPO_DIR"

echo "== git pull =="
git pull

echo "== MA + SuperHumans -> $MA_HOST =="
scp backup_MA_tower.sh backup_SuperHumans_tower.sh "${MA_HOST}:${REMOTE_PATH}"

echo "== Leo -> $LEO_HOST =="
scp backup_Leo_tower.sh "${LEO_HOST}:${REMOTE_PATH}"

echo "Готово."
