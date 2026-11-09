#!/bin/bash
# Run by cephfs-shutdown-guard.service at shutdown/reboot, while Ceph is still
# up (the unit is ordered after microceph): stop containers gracefully, SIGKILL
# stragglers, then flush and unmount CephFS cleanly.
# Never `umount -f` on CephFS: it shuts the client down and DISCARDS unflushed
# writes ("dropping dirty Fw state" in the kernel log).
set -u
M=/srv/dm/ceph
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

if mountpoint -q "$M"; then
  timeout 20 sync -f "$M/." || echo "sync of $M timed out"
  if timeout 30 umount "$M"; then
    echo "unmounted $M cleanly"
  else
    pids=$(timeout 5 fuser -m "$M" 2>/dev/null)
    echo "clean umount failed; holders: $(for p in $pids; do printf '%s(%s) ' "$(cat /proc/"$p"/comm 2>/dev/null)" "$p"; done)"
    umount -l "$M" && echo "lazy-unmounted $M"
  fi
fi
exit 0
