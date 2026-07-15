#!/usr/bin/env bash
# cephfs-mount-retry.sh — recover from a transient CephFS mount failure.
#
# WHY: after an unclean shutdown the MDS can report up:active while the FS is
# not yet mountable (OSD/PG recovery), so srv-dm-ceph.mount fails once and
# systemd has no native mount retry (upstream RFE #4468 never implemented;
# automount fails permanently, #16811). OnFailure= -> this helper is the
# maintainer-recommended pattern.
#
# On success it explicitly starts docker + web3home-stacks: those die as
# *dependency* failures (inactive, not failed), so they never retry themselves.
# See JOURNAL 2026-07-13 (8h outage, recovered only by accident via the restic
# timer pulling the mount in) and 2026-07-15 (this fix, failure-injection tested).

set -uo pipefail

MOUNT_UNIT="srv-dm-ceph.mount"
MOUNT_POINT="/srv/dm/ceph"
MAX_ATTEMPTS=40
SLEEP_SEC=30   # 40 x 30s = 20 min of retrying

bring_up_dependents() {
  echo "cephfs mounted — bringing up dependents"
  systemctl start docker.service || echo "WARN: docker start failed"
  systemctl start web3home-stacks.service || echo "WARN: web3home-stacks start failed"
  echo "recovery complete"
}

# Never fight a shutdown (same lesson as cephfs-shutdown-guard).
if systemctl list-jobs | grep -qE 'shutdown.target|reboot.target'; then
  echo "shutdown in progress — not retrying"
  exit 0
fi

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  if mountpoint -q "$MOUNT_POINT"; then
    echo "mounted on attempt $i"
    bring_up_dependents
    exit 0
  fi
  echo "attempt $i/$MAX_ATTEMPTS: $MOUNT_POINT not mounted, retrying in ${SLEEP_SEC}s"
  sleep "$SLEEP_SEC"
  systemctl start "$MOUNT_UNIT" >/dev/null 2>&1 || true
done

# Final start may have succeeded after the loop's last check — don't miss it.
if mountpoint -q "$MOUNT_POINT"; then
  echo "mounted on final attempt"
  bring_up_dependents
  exit 0
fi

echo "ERROR: $MOUNT_POINT still not mounted after $MAX_ATTEMPTS attempts (~$((MAX_ATTEMPTS*SLEEP_SEC/60)) min)"
exit 1
