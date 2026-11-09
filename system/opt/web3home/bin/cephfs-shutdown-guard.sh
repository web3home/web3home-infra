#!/bin/bash
# Run by cephfs-shutdown-guard.service at shutdown/reboot, before the network
# goes down: stop containers gracefully (databases shut down clean instead of
# crash-recovering on next boot), SIGKILL anything left, unmount CephFS.
set -u
systemctl list-jobs 2>/dev/null | grep -qE 'shutdown.target|reboot.target|halt.target' || exit 0

ids=$(timeout 10 docker ps -q 2>/dev/null)
if [ -n "$ids" ]; then
  echo "stopping $(echo "$ids" | wc -l) containers (20s grace)"
  # shellcheck disable=SC2086
  timeout 30 docker stop -t 20 $ids >/dev/null 2>&1
  left=$(timeout 5 docker ps -q 2>/dev/null)
  if [ -n "$left" ]; then
    echo "killing stragglers: $(timeout 5 docker ps --format '{{.Names}}' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    docker kill $left >/dev/null 2>&1
  fi
fi
umount -f /srv/dm/ceph 2>/dev/null || umount -l /srv/dm/ceph 2>/dev/null || true
exit 0
