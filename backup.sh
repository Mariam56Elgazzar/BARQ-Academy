#!/usr/bin/env bash
#
# backup.sh — creates a PostgreSQL logical backup (custom format) via pg_dump
# inside the postgres container, then copies it to ./backups/ on the host.

set -euo pipefail

mkdir -p backups
STAMP=$(date +%Y%m%d_%H%M%S)
FILE="barq_backup_${STAMP}.dump"

echo "=== Creating backup inside postgres container ==="
MSYS_NO_PATHCONV=1 docker exec postgres pg_dump -U barq_app -d barq_tasks -F c -f "/tmp/${FILE}"

echo "=== Copying backup to host: backups/${FILE} ==="
MSYS_NO_PATHCONV=1 docker cp "postgres:/tmp/${FILE}" "./backups/${FILE}"

echo "=== Cleaning up temp file inside container ==="
MSYS_NO_PATHCONV=1 docker exec postgres rm "/tmp/${FILE}"

if [ -s "backups/${FILE}" ]; then
    echo "[PASS] Backup saved: backups/${FILE}"
    exit 0
else
    echo "[FAIL] Backup file missing or empty: backups/${FILE}"
    exit 1
fi
