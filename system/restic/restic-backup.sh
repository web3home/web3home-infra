#!/bin/bash
# restic backup for bee001 → RPi4
# NOTE: committed copy uses placeholder IP 192.168.1.21. Live copy at /opt/web3home/bin/ has the real LAN IP.
# Native restic (not containerized). Runs as root via systemd timer.
# Repo password: /root/.restic-password-bee001 (0400, root)
# SSH identity:  /root/.ssh/id_ed25519_restic (via /root/.ssh/config)

set -euo pipefail
umask 077

export RESTIC_REPOSITORY="sftp:dm@192.168.1.21:/mnt/backup/bee001-backups"
export RESTIC_PASSWORD_FILE="/root/.restic-password-bee001"

LOGFILE="/var/log/restic-backup.log"
HOST_TAG="bee001"

# Paths to back up
BACKUP_PATHS=(
  /srv/dm/services   # all migrated service data (Ghost now, more later)
  /etc               # system config
  /opt/web3home      # scripts
)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

touch "$LOGFILE"
chmod 640 "$LOGFILE"

log "=== Starting backup ==="

# Clear any stale lock from a prior interrupted run
restic unlock 2>&1 | tee -a "$LOGFILE" || log "Note: unlock returned non-zero (ok if no locks)"

# Main backup
if restic backup "${BACKUP_PATHS[@]}" \
    --host "$HOST_TAG" \
    --exclude='*.log' \
    --exclude='**/logs/**' \
    --exclude='**/tmp/**' \
    --exclude='**/cache/**' \
    --verbose 2>&1 | tee -a "$LOGFILE"; then

  log "Backup OK. Pruning per retention policy..."
  restic forget --prune \
      --keep-daily 7 \
      --keep-weekly 4 \
      --keep-monthly 12 \
      --keep-yearly 2 \
      2>&1 | tee -a "$LOGFILE"

  # Weekly integrity check on Sundays
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
