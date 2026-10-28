#!/usr/bin/env bash
# Called by image-update.sh before Nextcloud changes image. Non-zero exit aborts
# the update with nothing changed.
#
# A Nextcloud image change can run a one-way `occ upgrade`, so the old image alone
# is not a rollback. This saves the other two halves: a database dump and the
# code/config tree (/var/www/html minus user data). Both land in ~/nc-pre-update/.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
dc() { docker compose --project-directory "$DIR" "$@"; }
OUT="$HOME/nc-pre-update"; STAMP=$(date +%F-%H%M)
mkdir -p "$OUT"

APP=$(dc ps -q app | head -1); DB=$(dc ps -q db | head -1)
if [ -z "$APP" ] || [ -z "$DB" ]; then echo "app or db container not running" >&2; exit 1; fi
VER=$(docker exec -u www-data "$APP" php occ status --output=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["versionstring"])')
echo "Nextcloud now: $VER"

# 1. database — engine detected from the db container
DUMP="$OUT/db-$VER-$STAMP.sql.gz"
if docker exec "$DB" sh -c 'command -v pg_dumpall' >/dev/null 2>&1; then
  docker exec "$DB" sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > "$DUMP"
elif docker exec "$DB" sh -c 'command -v mariadb-dump || command -v mysqldump' >/dev/null 2>&1; then
  docker exec "$DB" sh -c 'exec $(command -v mariadb-dump || command -v mysqldump) --single-transaction --all-databases -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"' | gzip > "$DUMP"
else
  echo "unknown database engine in db container" >&2; exit 1
fi
# a dump that ends early is worse than none: check it is complete
TAILTXT=$(zcat "$DUMP" | tail -c 2000)   # not piped into grep -q: SIGPIPE + pipefail
grep -qiE 'dump complete' <<<"$TAILTXT" || { echo "dump $DUMP looks incomplete" >&2; exit 1; }
echo "DB dump:  $DUMP ($(du -h "$DUMP" | cut -f1))"

# 2. code + config (what the entrypoint overwrites), without user data
HTML=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/www/html"}}{{.Source}}{{end}}{{end}}' "$APP")
[ -n "$HTML" ] || { echo "no /var/www/html mount found" >&2; exit 1; }
DATA=$(docker exec -u www-data "$APP" php occ config:system:get datadirectory)
EXCL=(--exclude=./data)
case $DATA in /var/www/html/*) EXCL+=(--exclude="./${DATA#/var/www/html/}") ;; esac
echo "data dir: $DATA (excluded if inside html)"
TAR="$OUT/html-$VER-$STAMP.tar.gz"
sudo tar -C "$HTML" "${EXCL[@]}" -czf "$TAR" .
sudo chown "$(id -u):$(id -g)" "$TAR"
echo "html tar: $TAR ($(du -h "$TAR" | cut -f1))"
