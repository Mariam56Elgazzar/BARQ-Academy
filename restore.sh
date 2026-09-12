#!/usr/bin/env bash
#
# restore.sh — restores a PostgreSQL logical backup (custom format) into
# the running postgres container using pg_restore --clean --if-exists.

set -euo pipefail

BACKUP_FILE="${1:?Usage: ./restore.sh <backup-file-name-in-backups/>}"

if [ ! -f "backups/${BACKUP_FILE}" ]; then
    echo "[FAIL] Backup file not found: backups/${BACKUP_FILE}"
    exit 1
fi

echo "=== Copying backup into postgres container ==="
MSYS_NO_PATHCONV=1 docker cp "backups/${BACKUP_FILE}" "postgres:/tmp/${BACKUP_FILE}"

echo "=== Restoring (--clean --if-exists drops/recreates existing objects) ==="
MSYS_NO_PATHCONV=1 docker exec postgres pg_restore -U barq_app -d barq_tasks --clean --if-exists "/tmp/${BACKUP_FILE}"

echo "=== Cleaning up temp file inside container ==="
MSYS_NO_PATHCONV=1 docker exec postgres rm "/tmp/${BACKUP_FILE}"

echo "[PASS] Restore completed from backups/${BACKUP_FILE}"
