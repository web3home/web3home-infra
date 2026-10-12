#!/bin/bash
# Restrict INBOUND 80/443 to Cloudflare edge + LAN. ufw does not govern
# Docker-published ports (Docker writes iptables first), so this lives in
# DOCKER-USER, which FORWARD jumps to before Docker's own ACCEPT rules.
#
# -i $WAN_IF is load-bearing. Without it the DROP matched container EGRESS too:
# an outbound HTTPS request has ctorigdstport 443, so every container lost
# internet access (2026-10-11, ~1h of downtime). Container egress arrives on a
# br-* interface and so never matches these rules.
#
# Docker DNATs before FORWARD, hence --ctorigdstport rather than --dport.
# Rules are tagged and deleted individually: never flush DOCKER-USER.
set -euo pipefail
WAN_IF=enp197s0
LAN=192.168.1.0/24
TAG=origin-lockdown

V4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4)
[ -n "$V4" ] || { echo "no cloudflare ranges; refusing to apply"; exit 1; }

# remove only our own rules
# iptables -S prints the comment unquoted, so match it bare. Rule numbers in
# -S output are offset by one (line 1 is the -N chain declaration).
while n=$(iptables -S DOCKER-USER | grep -n -- "--comment $TAG" | head -1 | cut -d: -f1); [ -n "$n" ]; do
  iptables -D DOCKER-USER $((n - 1))
done

add() { iptables -A DOCKER-USER -i "$WAN_IF" -m conntrack --ctorigdstport "$2" \
        --ctdir ORIGINAL ${1:+-s "$1"} -m comment --comment "$TAG" -j "$3"; }

for p in 80 443; do
  add "$LAN" "$p" RETURN
  for n in $V4; do add "$n" "$p" RETURN; done
  add "" "$p" DROP
done
echo "applied: $(iptables -S DOCKER-USER | grep -c "$TAG") rules"
