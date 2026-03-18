#!/bin/bash
set -euo pipefail
export BORG_REPO="__BORG_REPO__"
borg create --stats --compression zstd,3 \
    "${BORG_REPO}::zenbook-$(date +%Y%m%d-%H%M%S)" \
    /home/__REAL_USER__ /etc \
    --exclude '/home/__REAL_USER__/.cache' \
    --exclude '/home/__REAL_USER__/.local/share/containers' \
    --exclude '/home/__REAL_USER__/projects/*/.venv' \
    --exclude '/home/__REAL_USER__/projects/*/node_modules' \
    --exclude '*.pyc' \
    --exclude '__pycache__'
borg prune --stats --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$BORG_REPO"
borg compact "$BORG_REPO"
