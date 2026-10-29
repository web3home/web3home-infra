#!/bin/sh
# ipopt-drop.sh — drop inbound TCP packets that carry IPv4 options.
#
# Stopgap for CVE-2026-98432 (IPv4 TCP connection-setup use-after-free): the bug
# is only reachable through a connection request carrying IPv4 options (Record
# Route / Timestamp). Normal traffic never sends IP options, so dropping them
# removes the trigger. Lives in raw/PREROUTING, before conntrack and before any
# forwarding, so it covers the host, Docker containers and VPN traffic alike.
# Verified on bee001: a Record Route SYN got a SYN-ACK without this rule and no
# answer with it; plain SYNs unaffected. Remove once a fixed kernel is installed.
#
# Usage: ipopt-drop.sh up|down   (idempotent)
set -eu
# word splitting of $RULE is intended; it holds no glob characters
RULE='-p tcp -m u32 --u32 0>>24&0xF=6:15 -m comment --comment ipopt-drop -j DROP'
# shellcheck disable=SC2086
case "${1:-up}" in
  up)   iptables -t raw -C PREROUTING $RULE 2>/dev/null || iptables -t raw -I PREROUTING $RULE ;;
  down) while iptables -t raw -D PREROUTING $RULE 2>/dev/null; do :; done ;;
  *)    echo "usage: $0 up|down" >&2; exit 2 ;;
esac
