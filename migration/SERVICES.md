# Services Migration Inventory

> Source: Odroid M1 (ARM64, 8 GB RAM)
> Target: bee001 (Beelink GTR9 Pro, x86_64, 30 GB RAM, Ceph-backed storage)
> Username on target: `dm`

## Services to migrate

| Service | Image | Role | Notes |
|---|---|---|---|
| traefik | `traefik:v3.6.1` | Reverse proxy, TLS | Move last; config needs sanitizing |
| ghost-cms | `ghost:5-alpine` | Public blog (web3home.info) | Uses SQLite. First service to migrate |
| nextcloud | `nextcloud:32-pdlib` | File storage | ~500 GB data. Migrate to **Postgres** during this step |
| vaultwarden | `vaultwarden/server:latest` | Password manager | SQLite. Small but high-value |
| mattermost-app | custom (rebuild for x86_64) | Team chat | Uses Postgres |
| headscale | `headscale/headscale:latest` | VPN coordinator | Uses Postgres. Move last; the tunnel depends on it |
| nostr-relay | custom (rebuild for x86_64) | Nostr relay | SQLite |
| nostr-json | `nginx:alpine` | NIP-05 identity file | Static |
| homeassistant | `ghcr.io/home-assistant/home-assistant:stable` | Home automation | SQLite by default |
| bankless-redirect | `traefik/whoami` | Domain redirect | Trivial. Move with Traefik |
| mail2most | custom (rebuild for x86_64) | Email → Mattermost bridge | No DB |

## Architecture decisions

### Postgres per container, not shared host service

The Odroid currently runs a shared `postgresql@16-main` host service for Mattermost and Headscale. On bee001 each service gets its own dedicated `postgres:17` container inside its compose stack.

Benefits:
- Each stack independently restartable, upgradable, backupable
- Service isolation: a Postgres issue affects one service, not all
- Cleaner per-service backup story
- No "host package vs container" split-brain

### Nextcloud moves from MariaDB to Postgres

Postgres handles Nextcloud's concurrency and large-library workloads better than MariaDB. Migration uses Nextcloud's official `occ db:convert-type` tool: bring up the new stack with empty Postgres, run the conversion against a snapshot of the MariaDB data, verify file counts and shares match before flipping DNS.

### Internet exposure (decision pending)

Public services (Ghost) need internet exposure; private services (Vaultwarden, Mattermost, Nextcloud admin, Home Assistant) should be Headscale-only.

Options for public exposure of Ghost:
1. Cloudflare Tunnel — outbound only, no port forwarding, hides home IP; cost: Cloudflare sees plaintext
2. Self-hosted reverse-WireGuard via cheap VPS — same effect, no Cloudflare
3. Direct port forwarding — exposes home IP

Decision deferred to Traefik migration step.

### Portainer → plain compose files (+ Dockge if needed)

Portainer stores stack definitions in its own database. Migration approach:
- Export each stack's compose YAML from Portainer UI before tearing down
- Commit sanitized versions to `docker/<service>/` in this repo
- Use Dockge on bee001 if a UI is desired (Dockge reads plain compose files — sovereignty-clean, no proprietary DB)

### Custom images need x86_64 rebuilds

Three services run custom ARM64-tagged images: `mattermost-app`, `nostr-rs-relay`, `mail2most`. For each, locate the Dockerfile on Odroid, copy build context to bee001, rebuild for `linux/amd64`.

## Migration order (low-risk first)

1. **Ghost** — public blog, low traffic, easy to validate via browser
2. **Vaultwarden** — small data, high value, simple test (log in via app)
3. **Nostr (relay + json)** — small, self-contained
4. **Mattermost** — medium complexity; first service to use Postgres-per-container pattern
5. **Home Assistant** — verify integrations work
6. **Nextcloud** — biggest data; includes MariaDB → Postgres conversion
7. **Headscale + Traefik** — last; moving Headscale itself is meta. Plan for brief outage or fallback path
8. **bankless-redirect, mail2most** — finalize during Traefik migration

## Per-service journal entry template

For each service we migrate, the journal entry captures:

- Pre-migration state (versions, sizes, dependencies)
- Backup taken (path, timestamp, verification)
- Volume rsync command(s) used
- Compose file source (sanitized, committed under `docker/<service>/`)
- DNS / Headscale route changes
- Verification steps (what proves the service works on bee001)
- Rollback steps (how to revert to Odroid if needed)
- Decommission step (when Odroid copy is destroyed)
