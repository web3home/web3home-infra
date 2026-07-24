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

# Scan roots: the public repo, plus a private tree for client/commercial stacks
# that must not appear in a public repo. `shopt -s nullglob` means a root that
# doesn't exist simply contributes nothing. Without a second root, an out-of-repo
# stack silently never starts at boot (the spleeter-web trap).
SCAN_DIRS=(
  "/home/dm/code/web3home-infra/docker"
  "/home/dm/code/private-stacks/docker"
)

rc=0
count=0
for root in "${SCAN_DIRS[@]}"; do
  for compose in "$root"/*/compose.yaml; do
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
done

[[ "$count" -eq 0 ]] && echo "WARN: no boot-enabled stacks found under: ${SCAN_DIRS[*]}"
if [[ "$rc" -ne 0 ]]; then
  echo "compose-boot-up: one or more stacks failed."
else
  echo "compose-boot-up: $count stack(s) up."
fi
exit "$rc"
