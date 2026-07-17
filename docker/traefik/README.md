# Traefik — edge reverse proxy (bee001)

`compose.yaml` is deployed; `dynamic.yml.example` and `site/` are **reference
copies** — the live versions are on CephFS at `/srv/dm/ceph/traefik/`.

## Layout

- `/srv/dm/ceph/traefik/acme/acme.json` — cert store. **chmod 600 or Traefik
  refuses to start.** Copied from the Odroid, not re-issued. Never committed.
- `/srv/dm/ceph/traefik/configurations/dynamic.yml` — the route table (file
  provider). `dynamic.yml.example` is this file with the LAN IP placeholdered.
- `/srv/dm/ceph/traefik/nostr-json/` — static site: `index.html` (the game) and
  `.well-known/nostr.json` (NIP-05). Mirrored in `site/`.

## Design notes

- **No docker.sock.** The Odroid mounted it for the docker provider; it is
  root-equivalent on the host, so a Traefik compromise became a host compromise.
  Every route lives in `dynamic.yml`, so the docker provider bought nothing.
- **Same-bridge hairpin:** services sharing Traefik's network MUST be routed by
  container name (`http://nostr-json:80`), never via the host LAN IP — the packet
  leaves the bridge, hits the host, and gets proxied back to the same bridge; the
  return path does not survive it. Symptom: 504 Gateway Timeout while the backend
  answers a direct curl fine. Services on OTHER bridges reach the host IP fine.
- **Route priority:** file routes carry `priority: 100`; Traefik's default is
  derived from rule length (~38), so file routes deterministically beat any stale
  container labels. `bankless-site` is `priority: 50` so the NIP-05 route wins.
- **TLS options are misleading under the orange cloud.** `modern`/`sniStrict` here
  govern only the Cloudflare→origin leg. What browsers negotiate is set in
  Cloudflare's Edge Certificates settings.
