#!/bin/bash
# restic backup for bee001 → RPi4
# Native restic (not containerized). Runs as root via systemd timer.
# Repo password: /root/.restic-password-bee001 (0400, root)
# SSH identity:  /root/.ssh/id_ed25519_restic (via /root/.ssh/config)
#
# Pre-backup: consistent logical dump of the Nextcloud MariaDB
# (--single-transaction) to /srv/dm/services/nextcloud-db/nextcloud.sql,
# which is inside BACKUP_PATHS and on the root LV (independent of Ceph).
# The live InnoDB dir on CephFS is EXCLUDED — file-level snapshots of a
# running DB are not reliably restorable.

set -euo pipefail
umask 077

export RESTIC_REPOSITORY="sftp:dm@192.168.1.21:/mnt/backup/bee001-backups"
export RESTIC_PASSWORD_FILE="/root/.restic-password-bee001"

LOGFILE="/var/log/restic-backup.log"
HOST_TAG="bee001"

NC_DB_CONTAINER="nextcloud-db"
NC_DUMP_DIR="/srv/dm/services/nextcloud-db"
NC_DUMP_FILE="${NC_DUMP_DIR}/nextcloud.sql"
# SQLite-backed services: name|live DB|consistent snapshot destination.
# Snapshots land under /srv/dm/services (already a backup path, on the root LV).
# Postgres-backed services: name|container|user|db|dump destination.
POSTGRES_DBS=(
  "mattermost|mattermost-db|mattermost_user|mattermost|/srv/dm/services/mattermost-db/mattermost.sql"
)

SQLITE_DBS=(
  "vaultwarden|/srv/dm/ceph/vaultwarden/data/db.sqlite3|/srv/dm/services/vaultwarden/vaultwarden.sqlite3"
  "nostr-relay|/srv/dm/ceph/nostr-relay/db/nostr.db|/srv/dm/services/nostr-relay/nostr.db"
)

BACKUP_PATHS=(
  /srv/dm/services
  /srv/dm/ceph/nextcloud
  /srv/dm/ceph/vaultwarden
  /srv/dm/ceph/nostr-relay
  /srv/dm/ceph/mattermost
  /srv/dm/ceph/traefik
  /etc
  /opt/web3home
)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

touch "$LOGFILE"
chmod 640 "$LOGFILE"

log "=== Starting backup ==="

if docker ps --format '{{.Names}}' | grep -qx "$NC_DB_CONTAINER"; then
  log "Dumping Nextcloud DB from '$NC_DB_CONTAINER'..."
  mkdir -p "$NC_DUMP_DIR"; chmod 700 "$NC_DUMP_DIR"
  if docker exec "$NC_DB_CONTAINER" sh -c \
       'exec mariadb-dump --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' \
       > "${NC_DUMP_FILE}.tmp" 2>>"$LOGFILE"; then
    if tail -n 1 "${NC_DUMP_FILE}.tmp" | grep -q '^-- Dump completed'; then
      mv -f "${NC_DUMP_FILE}.tmp" "$NC_DUMP_FILE"; chmod 600 "$NC_DUMP_FILE"
      log "DB dump OK ($(du -h "$NC_DUMP_FILE" | cut -f1))."
    else
      log "ERROR: DB dump missing completion marker — refusing truncated dump."
      rm -f "${NC_DUMP_FILE}.tmp"; exit 1
    fi
  else
    log "ERROR: mariadb-dump failed (exit $?)."
    rm -f "${NC_DUMP_FILE}.tmp"; exit 1
  fi
else
  log "WARNING: '$NC_DB_CONTAINER' not running — NO fresh DB dump this run. Continuing with file backup."
fi

# Postgres services: a file-level copy of a live PGDATA is not reliably
# restorable — same reasoning as the MariaDB dump. Dump logically; PGDATA excluded.
# NOTE: pg_dump >= 16.10 wraps output in \restrict/\unrestrict (CVE-2025-8714), so
# the completion marker is NO LONGER the last line — grep the file, don't tail it.
dump_postgres() {
  local name="$1" container="$2" user="$3" db="$4" dst="$5"
  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    log "WARNING: '$container' not running — NO fresh $name dump this run."
    return 0
  fi
  log "Dumping $name Postgres from '$container'..."
  mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
  if docker exec "$container" pg_dump --clean --if-exists --no-owner --no-acl \
       -U "$user" "$db" > "${dst}.tmp" 2>>"$LOGFILE"; then
    if grep -q -- '-- PostgreSQL database dump complete' "${dst}.tmp"; then
      mv -f "${dst}.tmp" "$dst"; chmod 600 "$dst"
      log "$name dump OK ($(du -h "$dst" | cut -f1))."
    else
      log "ERROR: $name dump missing completion marker — refusing truncated dump."
      rm -f "${dst}.tmp"; return 1
    fi
  else
    log "ERROR: pg_dump for $name failed."
    rm -f "${dst}.tmp"; return 1
  fi
}

for entry in "${POSTGRES_DBS[@]}"; do
  IFS='|' read -r _n _c _u _d _f <<< "$entry"
  dump_postgres "$_n" "$_c" "$_u" "$_d" "$_f" || exit 1
done

# SQLite services: same hazard as the live InnoDB dir — a file-level copy of a
# WAL-mode DB can capture the db/-wal/-shm trio mid-checkpoint and be unrestorable.
# Use SQLite's online backup API for a consistent snapshot; live DBs are EXCLUDED.
snapshot_sqlite() {
  local name="$1" src="$2" dst="$3"
  if [ ! -f "$src" ]; then
    log "WARNING: no $name DB at $src — skipping snapshot."
    return 0
  fi
  log "Snapshotting $name SQLite (online backup API)..."
  mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
  if python3 -c '
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close(); src.close()
' "$src" "${dst}.tmp" 2>>"$LOGFILE"; then
    mv -f "${dst}.tmp" "$dst"; chmod 600 "$dst"
    log "$name snapshot OK ($(du -h "$dst" | cut -f1))."
  else
    log "ERROR: $name SQLite snapshot failed."
    rm -f "${dst}.tmp"; return 1
  fi
}

for entry in "${SQLITE_DBS[@]}"; do
  IFS='|' read -r _n _s _d <<< "$entry"
  snapshot_sqlite "$_n" "$_s" "$_d" || exit 1
done

restic unlock 2>&1 | tee -a "$LOGFILE" || log "Note: unlock returned non-zero (ok if no locks)"

if restic backup "${BACKUP_PATHS[@]}" \
    --host "$HOST_TAG" \
    --exclude='*.log' \
    --exclude='**/logs/**' \
    --exclude='**/tmp/**' \
    --exclude='**/cache/**' \
    --exclude='/srv/dm/ceph/nextcloud/db' \
    --exclude='/srv/dm/ceph/nextcloud/redis' \
    --exclude='/srv/dm/ceph/nextcloud/data/appdata_*/preview' \
    --exclude='/srv/dm/ceph/vaultwarden/data/db.sqlite3*' \
    --exclude='/srv/dm/ceph/nostr-relay/db/nostr.db*' \
    --exclude='/srv/dm/ceph/mattermost/db' \
    --exclude='/srv/dm/ceph/vaultwarden/data/icon_cache' \
    --exclude='/srv/dm/ceph/llm/models' \
    --verbose 2>&1 | tee -a "$LOGFILE"; then

  log "Backup OK. Pruning per retention policy..."
  restic forget --prune \
      --keep-daily 7 \
      --keep-weekly 4 \
      --keep-monthly 12 \
      --keep-yearly 2 \
      2>&1 | tee -a "$LOGFILE"

  if [ "$(date +%u)" -eq 7 ]; then
    log "Sunday: running integrity check (5% data subset)..."
    restic check --read-data-subset=5% 2>&1 | tee -a "$LOGFILE"
  fi

  log "=== Backup completed successfully ==="
else
  log "ERROR: Backup failed!"
  restic unlock 2>&1 | tee -a "$LOGFILE" || true
  exit 1
fi
