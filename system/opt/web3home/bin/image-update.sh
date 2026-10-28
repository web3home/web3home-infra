#!/usr/bin/env bash
# image-update.sh — move one compose service to the newest digest of its tag.
#
# Usage: image-update.sh <compose-dir> <service> [--check '<cmd>'] [--yes]
#   --check '<cmd>'  shell command run in the OLD and NEW image for comparison,
#                    e.g. 'node -v' or 'php -v | head -1'. Runs with --network none.
#   --yes            skip the confirmation prompt
#
# Refuses to act if the service is built locally (build:), if its image ref uses a
# variable or isn't found literally in the compose file, or if nothing changed.
# If <compose-dir>/pre-update.sh exists it runs before the switch (e.g. a DB dump);
# a non-zero exit aborts with nothing changed. Every service in the file that uses
# the same image ref is moved together (Nextcloud app + cron).
# Never commits and never rolls back by itself — it prints both commands instead,
# because rolling back an app that has already migrated its database needs the
# pre-update backup, not just the old image.
set -euo pipefail
trap 'echo "ERROR: line $LINENO failed: $BASH_COMMAND" >&2' ERR

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,16p' "$0"; exit 2; }

[ $# -ge 2 ] || usage
DIR=$(realpath "$1"); SVC=$2; shift 2
CHECK=""; YES=0
while [ $# -gt 0 ]; do
  case $1 in
    --check) CHECK=${2:?--check needs a command}; shift 2 ;;
    --yes)   YES=1; shift ;;
    *)       usage ;;
  esac
done

FILE=""
for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
  [ -f "$DIR/$f" ] && { FILE="$DIR/$f"; break; }
done
[ -n "$FILE" ] || die "no compose file in $DIR"
dc() { docker compose --project-directory "$DIR" -f "$FILE" "$@"; }

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/image-update"
mkdir -p "$STATE"

# --- what the compose file says (uninterpolated, so we edit what is written) ---
CFG=$(dc config --no-interpolate --format json) || die "docker compose config failed"
IFS='|' read -r OLD HASBUILD < <(printf '%s' "$CFG" | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"].get(sys.argv[1])
if s is None: print("|missing")
else: print(s.get("image", "") + "|" + ("build" if "build" in s else "-"))
' "$SVC")
[ "${HASBUILD:-}" != missing ] || die "no service '$SVC' in $FILE"
[ "$HASBUILD" = "-" ] || die "$SVC is built locally (build:). Bump FROM in its Dockerfile, then:
  docker compose build --pull $SVC && docker compose up -d $SVC"
[ -n "$OLD" ] || die "$SVC has no image:"
case $OLD in *'$'*) die "image ref '$OLD' uses a variable — edit it by hand" ;; esac
grep -qF -- "$OLD" "$FILE" || die "'$OLD' not found literally in $FILE — refusing to edit"

REF=${OLD%%@*}                       # name[:tag] without any digest
last=${REF##*/}
case $last in *:*) REPO=${REF%:*} ;; *) REPO=$REF ;; esac
norm() { local r=${1#docker.io/}; echo "${r#library/}"; }

# --- what is running now ---
CID=$(dc ps -q "$SVC" | head -1)
RUNNING_ID=""
[ -n "$CID" ] && RUNNING_ID=$(docker inspect -f '{{.Image}}' "$CID")

# --- pull the candidate ---
echo "Pulling $REF ..."
docker pull -q "$REF" >/dev/null || die "pull failed"
NEW_ID=$(docker image inspect -f '{{.Id}}' "$REF")
want=$(norm "$REPO")
# (docker adds its own trailing newline, so the loop must tolerate blank lines;
#  an `a && b` test as the loop's last command fails the pipeline under pipefail)
DIGEST=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$REF" |
  while read -r d; do
    if [ -n "$d" ] && [ "$(norm "${d%@*}")" = "$want" ]; then echo "${d#*@}"; break; fi
  done) || true
[ -n "$DIGEST" ] || die "pulled $REF but found no repo digest for $want"
NEW="$REF@$DIGEST"

if [ "$NEW" = "$OLD" ] && [ "$NEW_ID" = "$RUNNING_ID" ]; then
  echo "Up to date: $SVC already runs $NEW"
  exit 0
fi

# --- show what changes ---
label() { docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null | grep -v '<no value>' || true; }
probe() { docker run --rm --network none --entrypoint sh "$1" -c "$CHECK" 2>&1 | sed -n 1,5p || echo "(check failed)"; }
OLD_LABEL=""; [ -n "$RUNNING_ID" ] && OLD_LABEL=$(label "$RUNNING_ID")
NEW_LABEL=$(label "$NEW_ID")
echo
echo "Service:   $SVC   ($FILE)"
echo "Compose:   $OLD"
echo "New:       $NEW"
echo "Running:   ${RUNNING_ID:-<not running>}"
echo "Candidate: $NEW_ID"
[ -n "$OLD_LABEL$NEW_LABEL" ] && echo "Version label: ${OLD_LABEL:-?} -> ${NEW_LABEL:-?}"
if [ -n "$CHECK" ]; then
  [ -n "$RUNNING_ID" ] && { echo "--- check, running image:"; probe "$RUNNING_ID"; }
  echo "--- check, new image:"; probe "$NEW_ID"
fi
[ "$NEW_ID" = "$RUNNING_ID" ] && echo "(Same image content; this only pins the digest.)"
echo

if [ $YES -eq 0 ]; then
  read -r -p "Switch every service using '$OLD' to the new digest? [y/N] " a
  case $a in y|Y) ;; *) echo "Aborted, nothing changed."; exit 0 ;; esac
fi

# --- pre-update hook (backups) ---
HOOK="$DIR/pre-update.sh"
if [ -e "$HOOK" ]; then
  [ -x "$HOOK" ] || die "$HOOK exists but is not executable — refusing to skip it"
  echo "Running pre-update.sh ..."
  "$HOOK" "$SVC" "$OLD" "$NEW" || die "pre-update.sh failed — nothing changed"
fi

# --- rewrite the compose file (whole image: values only) ---
STAMP=$(date +%F-%H%M%S)
PROJ=$(basename "$DIR")
BAK="$STATE/$PROJ-$(basename "$FILE").$STAMP"
cp -p "$FILE" "$BAK"
python3 - "$FILE" "$OLD" "$NEW" <<'PY'
import re, sys
path, old, new = sys.argv[1:]
text = open(path).read()
pat = re.compile(r'^(\s*image:\s*["\']?)' + re.escape(old) + r'(["\']?\s*(?:#.*)?)$', re.M)
text, n = pat.subn(lambda m: m.group(1) + new + m.group(2), text)
if n == 0:
    sys.exit("no 'image: %s' line matched" % old)
open(path, "w").write(text)
print("Rewrote %d image: line(s)" % n)
PY
dc config -q || { cp -p "$BAK" "$FILE"; die "compose invalid after edit — restored original"; }
mapfile -t SVCS < <(dc config --no-interpolate --format json | python3 -c '
import json, sys
for n, s in json.load(sys.stdin)["services"].items():
    if s.get("image") == sys.argv[1]: print(n)
' "$NEW")
[ ${#SVCS[@]} -gt 0 ] || { cp -p "$BAK" "$FILE"; die "no service matched the new ref — restored original"; }
echo "Services moving: ${SVCS[*]}"

# --- switch ---
dc up -d "${SVCS[@]}"

# --- verify: right image, running, healthy (or stable for 20s if no healthcheck) ---
FAIL=""
for s in "${SVCS[@]}"; do
  deadline=$((SECONDS + 300)); ok=""
  while [ $SECONDS -lt $deadline ]; do
    cid=$(dc ps -q "$s" | head -1)
    if [ -n "$cid" ]; then
      read -r st hl img rc < <(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.Image}} {{.RestartCount}}' "$cid" 2>/dev/null) || { sleep 5; continue; }
      [ "$img" = "$NEW_ID" ] || { echo "$s: still on old image"; break; }
      case "$st/$hl" in
        running/healthy) ok=1; break ;;
        running/none)
          sleep 20
          read -r st2 rc2 < <(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$cid" 2>/dev/null) || continue
          [ "$st2" = running ] && [ "$rc2" = "$rc" ] && { ok=1; break; } ;;
        running/starting) ;;
        *) echo "$s: $st/$hl"; break ;;
      esac
    fi
    sleep 5
  done
  if [ -n "$ok" ]; then echo "OK   $s"; else echo "FAIL $s"; FAIL="$FAIL $s"; fi
done

printf '%s\t%s\t%s\t%s\t%s\n' "$STAMP" "$PROJ/$SVC" "$OLD" "$NEW" "$( [ -n "$FAIL" ] && echo "FAIL:$FAIL" || echo ok )" >> "$STATE/updates.log"
echo
dc ps "${SVCS[@]}"

ROLLBACK="cp -p '$BAK' '$FILE' && docker compose --project-directory '$DIR' -f '$FILE' up -d ${SVCS[*]}"
if [ -n "$FAIL" ]; then
  for s in $FAIL; do echo "--- last 40 log lines: $s"; dc logs --tail 40 "$s" 2>&1 || true; done
  echo
  echo "Update FAILED for:$FAIL. Not rolled back automatically."
  echo "Image-only rollback (safe only if the app did NOT migrate its data):"
  echo "  $ROLLBACK"
  [ -e "$HOOK" ] && echo "If it migrated, restore the pre-update.sh backup first."
  exit 1
fi

echo
echo "Done. Old image is still local, so rollback works offline:"
echo "  $ROLLBACK"
if TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null); then
  MSG="$PROJ: bump $SVC image to ${NEW_LABEL:-${DIGEST:7:12}}"
  echo "Review and commit when you're happy:"
  echo "  cd '$TOP' && git diff && git add '${FILE#"$TOP"/}' && git commit -m \"$MSG\""
fi
