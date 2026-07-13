#!/usr/bin/env bash
# compose-boot-up.sh — bring up boot-enabled web3home Docker Compose stacks.
# WHY: cephfs-shutdown-guard `docker kill`s containers at shutdown, setting
# desired-state=stopped, so `restart: unless-stopped` does NOT auto-restart
# them next boot. This performs the explicit `compose up -d` that overrides
# that flag. unless-stopped still handles crash-restart at runtime.
# DISCOVERY: scans docker/*/compose.yaml; brings up a stack ONLY if its dir
# contains a `.boot-enabled` marker. Add with: touch docker/<svc>/.boot-enabled
# Run by web3home-stacks.service (oneshot, after docker + CephFS mount).
set -uo pipefail
shopt -s nullglob

REPO_DIR="/home/dm/code/web3home-infra"

rc=0
count=0
for compose in "$REPO_DIR"/docker/*/compose.yaml; do
  dir="$(dirname "$compose")"
  if [[ ! -f "$dir/.boot-enabled" ]]; then
    echo "skip (not boot-enabled): $dir"
    continue
  fi
  count=$((count + 1))
  echo "==> bringing up: $dir"
  if ! ( cd "$dir" && docker compose up -d ); then
    echo "ERROR: failed to bring up $dir"
    rc=1
  fi
done

[[ "$count" -eq 0 ]] && echo "WARN: no boot-enabled stacks found under $REPO_DIR/docker/"
if [[ "$rc" -ne 0 ]]; then
  echo "compose-boot-up: one or more stacks failed."
else
  echo "compose-boot-up: $count stack(s) up."
fi
exit "$rc"
