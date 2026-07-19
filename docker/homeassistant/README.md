# Home Assistant (bee001)

Fresh install, **LAN only** — no Traefik route, no DNS record, no port-forward.
HA has a real CVE history and there's no mesh to hide behind yet; revisit exposure
when Headscale/mesh returns.

## network_mode: host is required

WiZ bulbs (WiFi) are discovered by **UDP broadcast on :38899**, which a bridged
container cannot see — so HA runs in host networking. Two consequences:

- `ufw` genuinely governs the port (unlike docker-published ports, which bypass
  ufw). LAN-only is enforced by:
      ufw allow from 192.168.31.0/24 to any port 8123 proto tcp   # UI
      ufw allow from 192.168.31.0/24 to any port 38899 proto udp  # WiZ discovery
  The UDP rule is what actually let the bulb pair — without it the broadcast reply
  was dropped.
- HA auto-detects bee001's Bluetooth adapter and logs D-Bus errors (BlueZ needs
  /run/dbus, unmounted). Cosmetic — the bulb is WiFi; skip the Bluetooth integration.

## Example device
- A WiFi smart bulb (WiZ integration) — auto-discovered once UDP 38899 was allowed.
