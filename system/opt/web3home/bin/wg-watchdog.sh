#!/bin/bash
# wg-quick@wg0 is a oneshot, so systemd reports active (exited) even when the
# tunnel passes no traffic. On 2026-09-24 NetworkManager adopted wg0 and
# flushed wg-quick's policy rules: handshakes kept succeeding, bee001 stopped
# replying on 10.8.0.7, and nothing noticed for a week.
# Test reachability, not unit state.
set -uo pipefail
HUB=10.8.0.1
ping -c 2 -W 5 "$HUB" >/dev/null 2>&1 && exit 0
logger -t wg-watchdog "hub $HUB unreachable; restarting wg-quick@wg0"
systemctl restart wg-quick@wg0
sleep 10
if ping -c 2 -W 5 "$HUB" >/dev/null 2>&1; then
  logger -t wg-watchdog "recovered after restart"
else
  logger -t wg-watchdog "STILL unreachable after restart - needs attention"
  exit 1
fi
