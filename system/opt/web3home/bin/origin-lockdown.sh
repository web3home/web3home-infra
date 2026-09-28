#!/bin/bash
# Restrict inbound 80/443 to Cloudflare edge + LAN. Docker-published ports are
# not governed by ufw (Docker writes iptables first), so this lives in
# DOCKER-USER. Docker DNATs before this chain, so match the ORIGINAL dest port.
set -euo pipefail
LAN=192.168.1.0/24
V4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4)
[ -n "$V4" ] || { echo "no cloudflare ranges; refusing to apply"; exit 1; }

iptables -F DOCKER-USER
for p in 80 443; do
  iptables -A DOCKER-USER -s "$LAN" -m conntrack --ctorigdstport "$p" --ctdir ORIGINAL -j RETURN
  for n in $V4; do
    iptables -A DOCKER-USER -s "$n" -m conntrack --ctorigdstport "$p" --ctdir ORIGINAL -j RETURN
  done
  iptables -A DOCKER-USER -m conntrack --ctorigdstport "$p" --ctdir ORIGINAL -j DROP
done
iptables -A DOCKER-USER -j RETURN
echo "applied: $(iptables -S DOCKER-USER | wc -l) rules"
