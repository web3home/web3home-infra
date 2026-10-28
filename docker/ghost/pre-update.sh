#!/usr/bin/env bash
# Called by image-update.sh before Ghost changes image. Non-zero exit aborts the
# update with nothing changed.
#
# Ghost migrates its database on start, and a major upgrade (5 -> 6) cannot be
# undone by switching the image back. The whole content dir — SQLite DB, images,
# themes, settings — is the rollback, so it is copied with Ghost STOPPED: a
# SQLite file copied while it is being written can be silently inconsistent.
# Downtime is the length of the tar. Ghost is restarted if this script fails.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
dc() { docker compose --project-directory "$DIR" "$@"; }
OUT="$HOME/ghost-pre-update"; STAMP=$(date +%F-%H%M)
mkdir -p "$OUT"

CID=$(dc ps -q ghost | head -1)
[ -n "$CID" ] || { echo "ghost container not running" >&2; exit 1; }
VER=$(docker exec "$CID" node -p 'require("/var/lib/ghost/current/package.json").version')
SRC=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/ghost/content"}}{{.Source}}{{end}}{{end}}' "$CID")
[ -n "$SRC" ] || { echo "no /var/lib/ghost/content mount found" >&2; exit 1; }
echo "Ghost now: $VER  content: $SRC"

trap 'echo "pre-update failed — starting Ghost again" >&2; dc start ghost' ERR
dc stop ghost
TAR="$OUT/content-$VER-$STAMP.tar.gz"
sudo tar -C "$SRC" -czf "$TAR" .
sudo chown "$(id -u):$(id -g)" "$TAR"
# list into a variable first: `tar | grep -q` kills tar with SIGPIPE once grep
# has its match, and pipefail then reports the pipeline as failed
LIST=$(tar -tzf "$TAR")
grep -qx './data/ghost.db' <<<"$LIST" || { echo "ghost.db missing from $TAR" >&2; false; }
trap - ERR
echo "content tar: $TAR ($(du -h "$TAR" | cut -f1))"
# Ghost stays stopped; image-update.sh starts it on the new image next.
