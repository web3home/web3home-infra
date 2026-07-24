## 2026-07-17 — Traefik moved to bee001: the Odroid is out of the serving path

**Result:** the edge is on bee001. All seven routes serve from it, verified with the
Odroid's Traefik **stopped**. Then every container on the Odroid was stopped and the
external sweep still passed. Nothing on that box is load-bearing anymore.

### The test approach that made this safe

Certs were the enabler: earliest expiry Sep 19, i.e. **64 days out**, and Traefik
renews at 30 days — so nothing would touch ACME before ~Aug 20 and **both Traefiks
could run in parallel with no renewal race**. That meant no test ports: bee001's
Traefik bound 80/443 and simply received nothing, because the router still forwarded
to .11. Tested it directly with `curl --resolve <host>:443:192.168.31.10`, which
bypasses DNS and Cloudflare entirely. The flip then became **only** the router
change — nothing to reconfigure afterwards, and rollback was one router edit.

### acme: copied, not re-issued

12 certs, all valid into Sep/Oct. Copying moves private keys between machines;
re-issuing is cleaner but burns Let's Encrypt rate limits if we iterate. Copied,
because DNS-01 means bee001 can re-issue at any time — the low-risk path with a free
fallback. Store holds 4 ghost certs (odoo, traefik, ha, jellyfin) with no routers;
harmless, they age out. `jellyfin.web3home.info` was never in any inventory.

**`ha.web3home.info` had a cert but NO DNS record** — DNS-01 doesn't need the name to
resolve, so Traefik issued a cert for a hostname pointing nowhere. Home Assistant was
never internet-reachable. Corrects an earlier assumption that it was exposed.

### Dropped docker.sock

The Odroid's Traefik mounted `/var/run/docker.sock` for the docker provider.
docker.sock is root-equivalent on the host. Every route already lived in
`dynamic.yml`, so the provider bought nothing — file-provider-only on bee001. Less
attack surface, routes stay git-trackable. `nostr-json` was the only label-based
service; converted to a file route.

### Debugging the 521s — what actually worked

After the flip: 521 (Cloudflare "origin unreachable") on everything.

- **ufw was a RED HERRING.** It was active allowing only 22/tcp, which looked
  damning — but **Docker publishes ports around ufw** (it writes iptables rules
  ahead of ufw's chain). Adding 80/443 changed nothing. Called "found it" too fast.
- **tcpdump settled it in one shot:** `tcp[tcpflags] & tcp-syn != 0 and not src host
  192.168.31.10` showed **zero inbound SYNs** during an external curl. Packets never
  arrived ⇒ router-side, ruling out everything host-side at once.
- **Root cause: the router would not re-bind an EDITED forward rule.** The rules
  displayed `443 → 192.168.31.10` correctly but did not take effect. Fix: **delete
  both rules, recreate from scratch, reboot the router.**

### Verification traps hit along the way

- **Both Traefiks proxy to the same backends, so 200s prove nothing about which one
  is serving.** Needed a distinguishing signal — bee001's CORS header on nostr.json.
  Deliberately introduced an observable difference; only that made the test valid.
- The CORS test reports "not bee001" on ANY failure, including a 521 error page.
  Useless while the origin was down.
- The definitive proof: **stop the Odroid's Traefik and see if everything still
  works.** Did it once prematurely (before the flip) → instant 521s, which at least
  proved the rollback path: stop → 521, start → restored in ~10s.
- **WebSocket upgrade tests: botched three times.** `curl -I` sends HEAD; upgrades
  need GET. And `Connection: Upgrade`/`Upgrade: websocket` are **HTTP/1.1**
  mechanisms — meaningless over HTTP/2 (RFC 8441 uses Extended CONNECT), so
  Cloudflare's HTTP/2 silently ignored them and returned a plain 200. Correct form:
  `curl -s -o /dev/null -D - --http1.1 -H ... ` → `101 Switching Protocols`.

### The 504: same-bridge hairpin

`nostr-json` returned 504 while answering a direct curl fine. Cause: it shares
Traefik's compose network, and the route pointed at the **host LAN IP** — so the
packet left the bridge, hit the host, and was proxied back into the same bridge. The
return path doesn't survive that. Services on *other* bridges (ghost, nextcloud…)
reach the host IP fine. **Rule: anything on Traefik's own network must be addressed
by container name.** Fixed by `http://nostr-json:80` and dropping the published port
entirely.

### NIP-05 CORS gap closed

`bankless.at/.well-known/nostr.json` returned 200 with **no
`access-control-allow-origin`** — plain nginx sends none. Browser nostr clients fetch
it cross-origin, so verification would fail there; native clients (Damus, Amethyst)
don't enforce CORS, which is why the checkmark looked fine. Added a `nostr-cors`
headers middleware in Traefik — no nginx config needed. Now returns `*`.

### spleeter-web was squatting on 443

Five containers bound `0.0.0.0:443` — every interface — for a local vocal-separation
tool. Had we flipped the port-forward without checking, **the router would have sent
the internet to spleeter's nginx.** Also: it lives at `/home/dm/code/apps/spleeter-web`,
**outside the repo**, so `compose-boot-up.sh` never saw it and it only came back via
`unless-stopped`. Stopped via `compose down` (volumes kept, 56M). **Its 443 mapping
must go before it's ever started again** — it's reached on :8200 anyway.

### bankless.at is now a game

The apex was served by `bankless-redirect` (a `traefik/whoami` dummy backend existing
only to hang a redirectregex on — Traefik needs no service for a redirect). It exited
255 four days ago and nobody noticed. Replaced with a small greyscale canvas game
(honey badger carrying a coin, jumping banks) served by the same nginx.
`priority: 50` so the NIP-05 route still wins.

### Home Assistant — rebuilt fresh, LAN only

One bulb didn't justify migrating. **No Traefik route, no DNS record, no
port-forward.** `network_mode: host` is required, not laziness: WiZ bulbs are found
by UDP broadcast on :38899, which a bridge network can't see. Useful side effect —
**host networking means ufw actually governs the port** (unlike docker-published
ports), so LAN-only is real rather than aspirational. Bluetooth errors in the log are
cosmetic: HA auto-discovered bee001's BT adapter but BlueZ needs D-Bus, which isn't
mounted. Bulb is WiFi; skip the Bluetooth integration.

### Headscale findings — deferred, and the config confirms the research
**Embedded DERP was OFF and it used Tailscale's public relays** — so the ~5-15% of
traffic where NAT traversal fails was relayed through Tailscale's infrastructure. The
exact default-config trap the earlier research flagged, on a node built to exit that
kind of dependency.

Also: `database.host: host.docker.internal` — **another host-native Postgres**, same
hidden pattern as Mattermost. And `policy.mode: file` with `acl.hujson` — the legacy
ACL model; upstream now says Grants.

The control plane is plain HTTPS, which is why it worked through the orange cloud
(the 2026-07-10 outage showed `fetch control key: 523` — a *Cloudflare* error).
**Correction to an earlier claim:** "Cloudflare can't carry UDP so DERP can't
traverse" was true but irrelevant to what existed — DERP was never enabled.

So replicating what we had is easy; *improving* on it is the hard part. Enabling
embedded DERP needs UDP 3478, which Cloudflare won't proxy ⇒ its own port-forward and
likely a grey-clouded hostname, **re-exposing the IP we just masked**. That's a values
call (plus native-vs-Docker, grants-vs-ACL) and gets its own session.

### restic

Added `/srv/dm/ceph/traefik` to BACKUP_PATHS — it holds acme.json (12 certs +
private keys), dynamic.yml (**the entire route table**), the NIP-05 identity and the
site. Would have been the same silent regression as the Vaultwarden one, on the config
that makes the whole edge work.

### Odroid: stopped, not wiped

All containers stopped; external sweep still passes. Final restic run taken. **Not
deleting piecemeal** — P4 re-images the box as Ceph node 2, which wipes it wholesale;
careful individual deletion is busywork with real risk. Leaving the disk intact as a
rollback.

**Check before the wipe:** headscale's data (host-native Postgres — not in any
container; node registrations + acl.hujson exist only there) and bitcoin-node's
datadir (exited 11mo ago; if it ever synced mainnet, worth knowing the size).

### Caught at commit: a real password hash in dynamic.yml

Sanitising the route table for the public repo surfaced two blocks we had never
read — we only ever viewed `head -60` of middlewares and the routers section, so the
middle was a blind spot. A `default-auth` basicAuth middleware carrying a **real
apr1/MD5 hash**, and an `admin-whitelist` with the real LAN range. **Both dead code**
— no router referenced either. They were staged for the **Traefik dashboard, which
was never enabled**, which also explains why `traefik.web3home.info` had a cert and a
DNS record serving nothing. Deleted rather than placeholdered. The hash used `$$`
(Docker Compose escaping), so it was pasted from a label context and would not even
have matched in file-provider YAML. Rotate the password regardless if it exists
anywhere else: apr1 is MD5 and cracks offline in seconds.

The first sanitising pass replaced only `192.168.31.10` and missed
`192.168.31.0/24` in the whitelist. **`grep -c` must return 0 before committing** —
gitleaks hunts tokens and keys, not RFC1918 addresses, so it would NOT have caught
this.

A local model reviewing the file flagged the hash correctly — a genuine catch — but
also claimed every `Host()` rule had mismatched parentheses, and asserted the IPs
were clean when they were not. The syntax claim was disproven twice: Traefik loads
the file and all seven routes serve 200/302 in production, and `grep -q '](http'`
returned "file is clean", so the mangling was a paste-pipeline artifact (it autolinks
`www.*`) — the model reviewed a corrupted copy. **Test against production; don't
argue with a reviewer.**

### Stale now

ufw rules `2368/tcp` and `3000/tcp` ALLOW from 192.168.31.11 — they existed so the
*Odroid's* Traefik could reach bee001's services. Dead weight.
Traefik 3.7.8 is out; we pinned 3.6.1 to match the Odroid. Upgrade separately.

## 2026-07-17 — DDNS: oznu → favonia; home-IP leak closed

**Result:** two archived DDNS containers replaced by one maintained container, a
silent staleness bug fixed, and `relay.bankless.at` stopped publishing our home IP.

### The leak

Zone export showed `relay.bankless.at ... A 91.64.185.204 ; cf_tags=cf-proxied:false`
— the ONLY grey-clouded A record across both zones. Our home IP was in public DNS:
ISP, rough location, and a direct path bypassing Cloudflare entirely.

Decided to proxy it (orange). Nostr events are public and signed, so Cloudflare
seeing them reveals little and they cannot forge events. The tension is real —
a censorship-resistant channel behind a CDN that could censor it — but the
asymmetry decides it: **IP exposure is one-way** (scraped and archived by DNS
history services; going orange stops further exposure but can't unpublish), while
**Cloudflare dependency is reversible in one click**. Verified working through the
orange cloud: NIP-11 returns our config, and a proper HTTP/1.1 upgrade handshake
gets `101 Switching Protocols`. Cloudflare proxies WebSockets on all plans; our own
Mattermost (`connect`, proxied) already proved it.

### The silent bug: 3 of 5 A records were never updated

oznu was configured `ZONE=` with no `SUBDOMAIN`, so it only ever updated the zone
**apex**. `bitwarden003`/`llm`/`nextcloud003`/`www` are CNAMEs to the apex, so they
followed. But `connect` (Mattermost), `ts` (headscale) and `relay` are **standalone
A records** — nothing updated them. On the next dynamic-IP change, Mattermost and
the relay would have gone dark while Nextcloud and Vaultwarden kept working. Latent
for months; only visible because the IP hadn't moved.

### Why oznu had to go

`oznu/docker-cloudflare-ddns` was **archived by its owner Aug 2022**; Docker Hub
images ~5 years old. Worse, it determines the public IP over **plain DNS**, which is
forgeable — spoof a response and it points our domains anywhere. On a node whose
premise is removing untrusted dependencies, a spoofable DNS updater is foundational.
favonia is maintained and queries Cloudflare over HTTPS (`IP4_PROVIDER=cloudflare.trace`).

### Config notes

One container replaces two: favonia takes a DOMAINS list spanning zones with a
single token. `IP6_PROVIDER=none` (netcheck: no IPv6). Dedicated scoped token
(Zone:Read + DNS:Edit on both zones) — favonia does NOT accept legacy global keys.
No Client-IP filter on the token: our IP is dynamic, so pinning would break the
updater exactly when it's needed.

**Cache gotcha:** favonia caches Cloudflare record state for **6h**. Editing a record
in the dashboard to test does NOT get corrected within 5m — the cached view still
looks current. A restart flushes it. The IP-detection path (the actual job) is not
cached and runs every 5m. Worth knowing: an out-of-band record edit can take up to
6h to be corrected.

**Write path must be tested explicitly.** All records read "already up to date", which
exercises Zone:Read only — a read-only token would produce identical logs and fail
silently at the next IP change. Broke `ts.web3home.info` to 192.0.2.1 (TEST-NET-1,
headscale is dead) and confirmed `📡 Updated an outdated A record`.

### Cloudflare housekeeping

Deleted: `traefik.web3home.info` A (dashboard commented out in compose — orphaned),
`odoo.web3home.info` CNAME (odoo exited 4 months ago), `_acme-challenge.bankless.at`
TXT (stale DNS-01 leftover from an interrupted cert run). SSL/TLS mode confirmed
**Full (strict)**.

**Noted:** with the orange cloud, `dynamic.yml`'s TLS options (`modern: VersionTLS13`,
`sniStrict`) only govern the **Cloudflare → origin** leg. What browsers negotiate is
set by Cloudflare's Edge Certificates settings. The strict config is not reaching end
users the way the file implies.

## 2026-07-16 — Mattermost migrated (with real convos); restic covers Postgres

**Result:** third P5 migration. 126 posts / 6 users / 18 channels / 1 team restored
and verified by logging in. Odroid containers left **stopped, not deleted**.

### Chose migrate over rebuild — and it was cheap

It's a small test instance (17 MB DB, 6.3 MB uploads), so rebuild-fresh was tempting.
But there were real conversations, and the version turned out favourable: the running
binary reported **11.0.2**, and the official `mattermost/mattermost-team-edition:11.0.2`
is amd64 — so a **same-version lift with NO schema migration**. Mattermost forbids
skipping majors; migrate first, upgrade later, never both at once.

### The stale-Dockerfile trap

`/mnt/nvme/appdata/mattermost/mattermost-image/Dockerfile` hardcodes **v10.10.1**.
The running binary said **11.0.2**. The file on disk is NOT what built the image —
Portainer held the real definition. **Portainer is the source of truth; files lying
around appdata are not.** Starting an 11.x image against a 10.x DB would have run a
one-way migration. Always ask the binary: `/mattermost/bin/mattermost version`.

The custom image (`your-custom-mattermost:latest` — a literal tutorial placeholder
name) was Debian slim + the community ARM64 tarball + uid-2000 user + tini. **No
patches**, so on amd64 the official image is a genuine drop-in, not an approximation.
uid 2000 matches both sides — no chown needed.

**Gained:** prepackaged plugins are arch-specific. Calls, Playbooks and Agents all
installed cleanly from the official amd64 image; they likely never worked on the
ARM64 repackage.

### Architecture improved

Postgres was **host-native 16.11 reached at 172.17.0.1:5432** (the docker bridge
gateway) — an implicit dependency with no container, invisible in `docker ps`, which
is why `mattermost-db` appeared to be missing. Now a proper `postgres:16` stack
member on an internal network. **DB password rotated** during the move.

`config.json` copied **verbatim, never edited** — it holds `AtRestEncryptKey` and
`PublicLinkSalt` which decrypt stored fields. `MM_*` env vars override the file, so
the datasource is repointed without touching it. MFA is enforced; TOTP secrets live
in the DB and rode along with the dump (team keeps their authenticators).

### pg_dump gotcha — the completion marker moved

`pg_dump` >= **16.10** wraps plain-text dumps in `\restrict`/`\unrestrict` with a
random key (CVE-2025-8714: a malicious source superuser could inject psql
meta-commands and get shell on whoever restores). Backpatched through PG 13.
Consequence: **`-- PostgreSQL database dump complete` is no longer the last line** —
`\unrestrict <token>` is. A `tail -n 1 | grep` check (as the MariaDB block uses)
would wrongly report a truncated dump. restic's Postgres check greps the file.

Restore-side: `\restrict` is a **psql meta-command**, so the restoring psql must be
>= 16.10 or it errors. Our `postgres:16` image ships 16.14. Fine, but pin-worthy.

Also: `pg_dump` has no `--single-transaction` (that's a psql/pg_restore flag) — it's
already consistent via an internal snapshot.

### restic now covers 4 dump types

MariaDB (nextcloud, 771M), Postgres (mattermost, 2.0M), SQLite × 2 (vaultwarden
960K, nostr-relay 252K). `POSTGRES_DBS` / `SQLITE_DBS` tables + per-type functions;
adding a service is one line. Live DB dirs all excluded.

### Noted, not fixed — push metadata leaves the node

`MM_EMAILSETTINGS_PUSHNOTIFICATIONSERVER=https://push-test.mattermost.com` — Mattermost
Inc's **test** proxy: no uptime guarantee, and push metadata for private chat transits
a third party. `PUSHNOTIFICATIONCONTENTS=generic_no_channel` means no message text or
channel names leak, which is the right setting given the circumstance. Fix later:
self-host `mattermost-push-proxy`, or drop push. Contradicts the node's premise.

## 2026-07-16 — nostr-relay migrated; restic SQLite snapshots generalised

**Result:** second P5 migration done. Odroid container left **stopped, not deleted**
as rollback.

### The blocker the earlier migrations dodged

`image=nostr-rs-relay:arm64` — a **locally-built ARM64 image** existing nowhere but
the Odroid's docker storage: unpullable, and wrong arch for amd64 bee001. Same trap
as Nextcloud's custom `-pdlib` build; same fix: use the published upstream image.
`scsibug/nostr-rs-relay:latest` is amd64 and built 2026-05-22 — actively published,
no source build needed. Researched alternatives (strfry leads on throughput) and
rejected switching: strfry is LMDB not SQLite, so 1.2 GB would need export/import,
and its community Docker images are 1-2 years stale. Data moves byte-for-byte on
nostr-rs-relay; changing relay implementation is a separate project.

Image details that mattered: runs as `appuser` **uid 1000 = dm's uid**, so bind
mounts work with no `user:` override; `APP_DATA=/usr/src/app/db` is already the
image default; image ships no config.toml, so our read-only mount shadows nothing.

### The 1.2 GB mystery — relay ran OPEN before the whitelist

Config says `mode = "whitelist"` with ONE pubkey, `name = "Personal Nostr Relay"`.
Reality: **456,727 events from 82,260 distinct authors**, dating 2021-12 → 2026-06.
Only **23 events (0.005%) were ours**. Kind 7 (reactions) alone: 252,188. Also kind
5 (deletions) 58k, kind 9735 (zaps) 44k — mostly strangers' social exhaust.

A whitelist gates **writes, not reads**, and never evicts what's already stored, so
the firehose it ingested pre-whitelist just sat there. `[retention] max_events =
50000` was clearly never enforced either (456k present). Only 0.06 GB was freelist,
so it wasn't dead pages — it was real data.

Pruned to author-only + VACUUM: **1.23 GB → 252 KB** (events 456727→23, tags
1138615→236). Nostr events are replicated across relays by design, and the full
original remains in the Odroid's restic snapshots.

**Trap:** the schema declares `ON DELETE CASCADE`, but `pragma foreign_keys`
defaults to **0** (off, per-connection) in SQLite. Without `pragma foreign_keys =
ON` the delete would have left 1.1M orphaned tag rows and reclaimed nothing.
Pruned the **copy** on bee001, not the source — a botched prune costs a re-copy.

### restic: generalised to a loop

Two SQLite services now, so the Vaultwarden block became `SQLITE_DBS` (a
`name|src|dst` table) + a `snapshot_sqlite()` function. Adding a third service is
one line. A missing DB warns and continues; a failed snapshot is fatal (`|| exit 1`)
— same fail-loud stance as the MariaDB dump's completion-marker check. Verified both
snapshots + clean completion.

### Incidental finding — headscale's label routers have ALWAYS been dead

Traefik logs (predating our changes): `Router headscale cannot be linked
automatically with multiple Services: ["headscale-grpc" "headscale"]`. Its labels
declare two services (8080, 50443) and two routers without telling either router
which service to use, so Traefik can't auto-link and **both label routers fail**.
`ts.web3home.info` works purely off the file route (`priority: 100` → headscale:8080)
— meaning the gRPC endpoint was never reachable. Not fixing: headscale is deferred
and gets rebuilt fresh; this dies with the Odroid.

### Note

`max_event_bytes = 104857600` (100 MB/event, ~800× typical) left as-is:
`max_message_length = 16384` caps inbound websocket messages at 16 KB, so an
oversized event can't physically arrive, and whitelist mode means only we could try.
Ugly, not dangerous — not worth a restart.

## 2026-07-15 (later) — Odroid decommission arc begins: Vaultwarden migrated

**Result:** Vaultwarden moved Odroid → bee001, first of the P5 service migrations.
Old container left **stopped, not deleted** on the Odroid as rollback.

### Odroid inventory — the handover undersold this

P5 claimed 4 services. Reality: ~11 running, plus ~8 long-dead containers
(bitcoin-node exited 11mo ago, n8n/nginx/nodered 10-11mo, odoo 4mo) and 3 already
migrated (ghost, ollama×2). Real migration set is 3 stacks — vaultwarden,
nostr-relay, mattermost(+mail2most) — plus DDNS×2 and Traefik. `nostr-json` and
`bankless-redirect` become Traefik config, not containers. `portainer` +
`docker-socket-proxy` to be retired (they're the old operating model; bee001 uses
git-tracked compose + web3home-stacks). Home Assistant to be rebuilt fresh (one
bulb — not worth migrating, and it lets us re-decide its exposure).

### Findings

- **Stale duplicate routes.** The old Odroid Nextcloud stack was still RUNNING with
  `traefik.http.routers.nextcloud.rule=Host(nextcloud003.web3home.info)` — the same
  host bee001 serves. Not split-brain in practice: the file route carries an explicit
  `priority: 100`, beating the label route's length-derived default (~38). Deliberate,
  by whoever wrote dynamic.yml. Still stopped it — one config edit could have flipped
  it. Headscale has the same duplicate-route pattern.
- **Ingress identified.** `cloudflare-ddns` containers ⇒ dynamic public IP +
  port-forward, NOT a Cloudflare Tunnel. netcheck: 91.x public v4, no CGNAT,
  MappingVariesByDestIP false. So P3 is mostly **repointing the router's 80/443
  forward from .11 → .10**; dynamic.yml's targets already say 192.168.31.10.
- **Vaultwarden was insecure.** No env vars at all ⇒ `SIGNUPS_ALLOWED` defaulted to
  **true** on an internet-facing instance (anyone could register), and `DOMAIN` unset
  (breaks WebAuthn/U2F + email links). Both fixed. ADMIN_TOKEN stays unset ⇒ /admin
  disabled. Image was already current (`vaultwarden/server:latest`) — only the
  container name `bitwardenrs` was a pre-2021 leftover.
- **Odroid IS backed up** (restic → RPi4, cron 05:00, 20 snapshots) incl. Portainer's
  data dir, so the `/data/compose/<N>` stack definitions survive. Compose files are
  readable straight off disk at `appdata/portainer/compose/<N>` — no Portainer API.

### Migration pattern (reusable for the rest)

compose on bee001 (git-tracked, data on CephFS) → **stop source container** → tar
`/data` → scp → start → verify on LAN port → add `priority: 100` file route in the
Odroid's dynamic.yml → verify via HTTPS → `.boot-enabled` → leave source stopped.

- **Stopping the source is mandatory for SQLite/DB stacks.** The tar caught
  `db.sqlite3-wal` (506K, dated today) while the main DB was last written Jul 11 —
  copying only `db.sqlite3` would have silently lost days of vault changes.
- `rsa_key.pem` must come across or every client session is invalidated.
- Web vault needs **HTTPS** to test: `crypto.subtle` is secure-context-only, so
  `http://<lan-ip>:8484` loads the UI but can't log in. Not a migration fault.

### Backup regression caught (would have been silent)

`BACKUP_PATHS` didn't include `/srv/dm/ceph/vaultwarden` — the migration moved the
password vault from a backed-up box to an unbacked-up path. Fixed by mirroring the
existing MariaDB pattern rather than just appending a path: **SQLite in WAL mode has
the same live-copy hazard as a running InnoDB dir** (db.sqlite3/-wal/-shm captured
mid-checkpoint = unrestorable). Added a `sqlite3 .backup` (online backup API)
pre-step writing a consistent snapshot to `/srv/dm/services/vaultwarden/`, and
EXCLUDED the live `db.sqlite3*` + icon_cache. Verified: `Vaultwarden snapshot OK
(956K)`, backup completed clean.

## 2026-07-15 — Unclean-shutdown recovery FIXED (retry chain); redis AOF papercut

**Result:** the 8h-outage hole from 2026-07-10 is closed. A failed CephFS mount
now self-heals: OnFailure → retry helper → mount → explicitly starts docker +
web3home-stacks. Proven by failure injection (no power cut needed) and a clean
reboot.

### The fix

- `srv-dm-ceph.mount` drop-in `20-retry-on-failure.conf`:
  `OnFailure=cephfs-mount-retry.service`.
- `cephfs-mount-retry.service` (oneshot) → `/opt/web3home/bin/cephfs-mount-retry.sh`:
  retries the mount for ~20 min (40 × 30s), bails immediately if a shutdown is in
  progress, and on success explicitly starts `docker.service` +
  `web3home-stacks.service`.
- Why explicit dependent-start: docker and web3home-stacks die as **dependency**
  failures → `inactive (dead)`, not `failed`. Nothing retries them and their own
  `OnFailure=` could never fire. Confirmed in the 07-10 journal.

### Why retry, not a smarter gate

Prediction rejected. Ceph's docs say "at least one MDS up AND the cluster active +
healthy" — but gating on `ceph -s` health is unusable here: our HEALTH_OK is
artificial (muted POOL_NO_REDUNDANCY / POOL_HAS_NO_REPLICAS_CONFIGURED on a
single-OSD node) and flips to WARN when the mutes lapse → a health gate would time
out every boot. Stability polling (`up:active` across N polls) only fixes an MDS
*flap*; it does nothing if the MDS is genuinely active while the OSD/PGs aren't
serviceable — the likelier cause of the 17s gap on 07-10. No status string
reliably predicts mountability. **Retry is the guarantee; the gate is an
optimisation.** Gate hardening dropped as optional polish once retry proved out.

### Test — failure injection, not a power cut

`snap stop microceph.mds` reproduces the exact `no mds (Metadata Server) is up`
error while mon+OSD stay up: same code path, narrower and safer than pulling power.
Stop docker + unmount → stop MDS → `systemctl start srv-dm-ceph.mount` fails →
OnFailure fires (retry `activating`) → loops every 30s → `snap start
microceph.mds` → **mounted on attempt 4 → docker started → web3home-stacks started
→ all 12 containers back. Zero manual steps.** ~30s, where 07-10 took 8h.

Also answered empirically: the feared OnFailure recursion (retry calls `systemctl
start` on the mount; a failed start re-fires OnFailure) is a non-issue — systemd
coalesces the job. One clean invocation in the journal.

### Bug caught before commit

First cut of the script had a real tail-case bug: if the **final** attempt's
`systemctl start` succeeded, the loop ended and the script printed ERROR and exited
1 **without starting docker/web3home-stacks** — mount up, services down: the 07-10
outage reproduced by the very code meant to prevent it. Narrow (only at the 20-min
boundary), but the wrong failure mode to ship. Fixed: bring-up factored into a
function + a post-loop `mountpoint` re-check.

### Redis AOF corruption (a Fix B side effect) — fixed same day

After the clean reboot, `nextcloud-redis` crash-looped (`restarts=18`, exit 1):

    Bad file format reading the append only file
    appendonlydir/appendonly.aof.20.incr.aof at offset 21163915

Offset ~21.1MB in a ~21MB file = the last write, cut mid-flight. Cause:
`cephfs-shutdown-guard` `docker kill`s everything at shutdown (SIGKILL), racing
redis mid-AOF-append. `docker stop` is not an option — it's what wedged reboots in
the first place (2026-06-13). It's a race: most reboots are fine, occasionally not.

Cleared by moving the AOF aside (`appendonlydir.corrupt-20260715`) and restarting.
The data is a **cache + file locks**, not durable state, so losing it costs nothing
(`occ status` confirmed Nextcloud healthy throughout). Stable 13h since.

**Fixed:** dropped persistence entirely —
`command: ["redis-server", "--save", "", "--appendonly", "no"]` and removed the
`/srv/dm/ceph/nextcloud/redis` volume. No AOF, no RDB, no data dir => nothing to
corrupt, so the SIGKILL race is structurally impossible rather than merely rarer.
Verified: `config get appendonly` = no, `config get save` = empty.

Rejected: `--aof-load-truncated` / `aof-load-corrupt-tail-max-size` (tolerates the
corruption instead of removing the cause), and graceful-stopping redis in the
shutdown guard (reintroduces the slow-shutdown wedge from 2026-06-13).

Tradeoff accepted: a redis restart now drops all file locks. Nextcloud re-acquires
them, and clearing stale locks is usually a fix rather than a problem — a client
mid-upload could hiccup. Cheaper than periodic crash-loops.

## 2026-07-13 — P1 dropbear DONE; power-outage post-mortem; NC 33; vision + image-gen

**Result:** remote LUKS unlock over SSH proven working (LAN scope). The
roadmap's top item is closed. Also: post-mortem on the Jul 10 power outage
that revealed a dirty-shutdown boot-recovery gap (documented, not yet fixed).

### Power outage (Jul 10) — post-mortem

Shared power loss killed bee001 + Odroid. Entered LUKS at the TV, walked away —
**services were down ~8h and I didn't know.** Journal-confirmed chain:

- Unclean shutdown → `cephfs-shutdown-guard` never ran (no `docker kill`).
- `wait-for-ceph-mon` reported MDS `up:active` and passed, but the mount fired
  17s later with `no mds is up`. **The gate checks MDS status, not actual
  mountability — the two diverge after a dirty shutdown during MDS recovery.**
- `web3home-stacks` hit `Dependency failed` (mount failed) and **died
  permanently — no retry.**
- Recovery at 03:45 was **accidental**: `restic-backup.timer` fired, its
  `RequiresMountsFor=/srv/dm/ceph` re-triggered the mount (Ceph stable by then),
  Docker followed, containers restored via `unless-stopped` (power-loss left
  them "running", so unlike a clean shutdown they auto-restored).

### KNOWN OPEN ISSUE — dirty-shutdown boot recovery not solid

Clean reboots work (Fix B). Unclean shutdowns do not recover reliably. Fix
designed, NOT yet implemented:
- mount `OnFailure=` → retry helper (systemd has no native mount retry; this is
  the maintainer-recommended pattern, issue #16811/#4468).
- harden the gate to test real FS reachability (stat), not just MDS status.
- make `web3home-stacks` self-heal when the mount comes up late.
Needs power-cut testing — now safe to test because dropbear exists.

### P1 dropbear-initramfs — DONE (LAN scope)

- New layout `/etc/dropbear/initramfs/`. Options: `-R` (ephemeral host keys —
  /boot is unencrypted/untrusted, persistent keys give false assurance),
  `-s -j -k -c cryptroot-unlock -p 2222`.
- ed25519 unlock key generated **on the laptop** (first attempt failed: key was
  generated on the wrong machine — the private half must live on the client).
- Static `ip=`, NOT DHCP — outage-hardened (router may not serve leases when
  box + router co-boot after power loss).
- r8169 module + rtl_nic firmware confirmed in initramfs. `update-initramfs -u
  -k all` (was on -22, -27 staged; covers GRUB fallback).
- **Scope: LAN only.** dropbear predates the mesh, so no internet-scope unlock.
  That's a separate, security-sensitive decision tied to the network migration.
- Docs: `system/dropbear/` (credential files gitignored, never committed).

### Fix B correction — "proven" was half true

Earlier marked "zero manual touches, proven." The systemd gate chain worked,
but **containers never auto-started**: `docker kill` at shutdown sets
desired-state=stopped, and `unless-stopped` honors that → containers stay down
until an explicit `compose up`. Real fix: `web3home-stacks.service` (oneshot
`compose up -d`, `.boot-enabled` marker-gated, no ExecStop so the shutdown
guard still owns teardown). Now reboot-proven repeatedly incl. an apt-upgrade
reboot (uptime == container age). Docs: `system/systemd/`.

### Other

- Nextcloud 32 → 33 (33.0.5; `occ upgrade` ran clean on container restart).
- Qwen3.6-35B-A3B vision enabled: bartowski `mmproj-f16` via `--mmproj`.
  (Model is multimodal; projector ships separately — text worked, images 503'd
  until the mmproj was loaded.)
- ComfyUI/ROCm image-gen working: hec-ovi gfx1151 image, 103GB unified VRAM
  visible, SDXL generates, GPU releases to 0 after (no D-state hang). Isolated
  (restart=no, not in boot set). LTX-2.3 video PARKED — OOM'd the 128GB pool
  when stacked with LLM + spleeter. Needs LLM-parked + offload flags +
  custom_nodes persistence mount. Unified memory is shared: big video model +
  running LLM > 128GB → OOM-killer took both.

## 2026-06-13 — Fix B COMPLETE: bee001 reboots cleanly unattended (battle-tested)

**Result:** full clean reboot cycle proven — shutdown completes on its own,
box power-cycles, LUKS auto-unlocks, CephFS auto-mounts first try, Docker +
all containers auto-start, HEALTH_OK. Zero manual touches. The multi-session
reboot ordeal is closed.

### What finally worked

- **cephfs-shutdown-guard.service** — the key fix was `docker kill` (instant
  SIGKILL) instead of `docker stop` (waits ~10s/container → blew past the 90s
  TimeoutStopSec → systemd SIGKILLed the guard mid-run → redis survived into
  the final sd-sync → wedge). Fast-kill finishes in ~1s. Also: ordered
  `After=network.target network-online.target docker.service` so ExecStop runs
  while the network is still up (clean unmount, no -101 retry storm), plus a
  shutdown-only guard clause (`list-jobs | grep shutdown/reboot || exit 0`) so
  an accidental `systemctl restart` no longer tears down production.
- **wait-for-ceph-mon.service** — boot gate now polls for an **active MDS**
  (`microceph.ceph mds stat | grep up:active`), not bare TCP on :6789. The mon
  port answers ~3s before the MDS is mountable; the old TCP poll passed too
  early and the mount failed with "no mds is up". 180s window also covers MDS
  journal replay after an unclean boot.

### Hard-won lessons (now in the guide)

- A unit whose ExecStop is destructive must early-exit unless the system is
  truly shutting down — never `restart` it casually (tore down prod twice).
- `docker stop` is too slow for shutdown guards; `docker kill` + force-unmount.
- CephFS mount readiness = active MDS, not mon TCP reachability.
- Always `systemd-analyze verify default.target` after unit edits — a
  Before=network.target + After=mount combo silently deletes network.target.

### Committed this session

system/ceph/: cephfs-shutdown-guard.service, wait-for-ceph-mon.service,
srv-dm-ceph.mount (updated), 10-wait-for-mon.conf — all battle-tested before
commit. Plus docs/SOVEREIGNTY-NODE.md (the build guide).

### Still open (roadmap, not blockers)

- dropbear-initramfs for remote LUKS unlock (still needed before remote reboot).
- Boot still needs the physical LUKS passphrase — dropbear is the fix.
- Phase 2–4: Headscale+Traefik migration to node 1, 3-node Ceph + replication,
  Cloudflare exit. Remaining service migrations: Vaultwarden, Nostr, Mattermost,
  Home Assistant.
- Microcode 0x0b700037 still not loading across reboots (low priority).
## 2026-06-01 — Reboot exposed CephFS non-persistence; recovered, mount now durable

**Type**: incident · **Outcome**: resolved, zero data loss, root cause fixed

**Why**: a kisak-mesa upgrade (for GPU work) pulled a new kernel + microcode, requiring a reboot. The reboot surfaced a latent gap: CephFS at /srv/dm/ceph was mounted MANUALLY during migration and never persisted (no fstab/systemd unit). It did not remount at boot.

**Incident chain**:
- Shutdown hung on `libceph: connect …:6789 error -101` (CephFS couldn't unmount cleanly — network torn down first); redis task blocked >122s. Required hard power-cycle.
- Boot: Ceph recovered to HEALTH_OK on its own (unclean-shutdown MDS journal replay), but /srv/dm/ceph did NOT mount.
- Nextcloud containers, finding the mountpoint empty, bootstrapped a FRESH BLANK install into the root-LV dir (809M html + 137M new MariaDB + CAN_INSTALL). No user data written; caught before anyone logged in.

**Recovery (ordered, rollback-safe)**:
- Stopped Nextcloud stack (ghost untouched).
- Verified real data via TEMP mount at /mnt/ceph-verify: 551G, instanceid oc42e0t3b65v, v32.0.10.1 — confirmed intact in Ceph before touching anything.
- Moved blank install aside → /srv/dm/ceph/nextcloud.shadow-blank-2026-06-01 (now shadowed under the mount; delete after bake).
- Mounted real CephFS at /srv/dm/ceph.

**Root-cause fix**:
- Created systemd mount unit `/etc/systemd/system/srv-dm-ceph.mount` (Type=ceph, _netdev, After microceph daemon). Enabled.
- Docker drop-in `docker.service.d/10-wait-cephfs.conf`: `RequiresMountsFor=/srv/dm/ceph` + `After=srv-dm-ceph.mount` — Docker now waits for the mount, so containers can never again init into an empty path.
- Verified: systemd unmount→start cycle works; mount survives by design now.

**Verified post-recovery**: 4 users, 1,019,464 files, 65 shares, maintenance:false, redis locking active, external HTTPS admin API returns 200.

**SECURITY TODO (priority)**: client.admin Ceph key was printed to terminal/logs during diagnosis (`ceph auth ls`). Rotate the admin key and scrub history when convenient.

**Deferred / cleanup**:
- Delete shadow-blank-2026-06-01 after bake (~950M reclaim).
- Mount unit uses zero-placeholder FSID (`admin@.cephfs=`); works via mon_addr resolution. Optionally pin real FSID 785f2ea5-… for robustness.
- restic systemd service has no $HOME → cache disabled (slower). Set RESTIC_CACHE_DIR/HOME in unit.
- Guard against manual/timer restic collision (flock).
- Commit sanitized restic + mount-unit changes to repo.

**GPU/HTPC detour (SOLVED — was a permissions issue, not a driver gap)**: The all-night "llvmpipe only" symptom was NOT missing Strix Halo support. RADV fully drives GFX1151 on the installed kisak Mesa 26.1.1 — confirmed `Radeon 8060S Graphics (RADV STRIX_HALO)`. Root cause: `/dev/dri/renderD128` is `root:render` mode `crw-rw----`, and user `dm` was in neither `render` (991) nor `video` (44), so every non-root Vulkan call hit `Permission denied` → llvmpipe fallback. Fix: `usermod -aG render,video dm` + re-login. Now works as `dm`, no sudo. The kisak Mesa upgrade + new kernel/reboot were not strictly needed for detection (kept anyway; fine).

**NEXT SESSION — clean starting task (HTPC build on a working GPU base)**: install KDE Plasma + SDDM + Steam + Kodi for the living-room/Samsung-TV setup. Foundation verified: amdgpu bound, RADV exposes 8060S to `dm`, `/games` LUVS volume mounted (280G free), Steam needs multilib (already enabled). Reminder: streaming-service DRM (Netflix etc.) caps at 1080p on Linux — local media + YouTube fine. Consider setting default target back to multi-user.target and starting the desktop on demand to keep the server clean.

**Type**: backup · **Outcome**: success, restore-verified

**Why**: migrated Nextcloud data (~540 GiB on single-OSD CephFS) had no bee001-side backup — the open gap from the 05-29 migration. Hard gate before any Postgres conversion or Odroid decommission.

**Changes** (`/opt/web3home/bin/restic-backup.sh`, backup at `.bak-2026-05-31`):
- Added `/srv/dm/ceph/nextcloud` to BACKUP_PATHS.
- Pre-backup logical DB dump: `mariadb-dump --single-transaction` from `nextcloud-db` → `/srv/dm/services/nextcloud-db/nextcloud.sql` (root LV, already in backup scope, Ceph-independent). Temp-then-rename + completion-marker check; truncated dump = fatal.
- Excludes: live `db/` (use the dump instead), `redis/` (cache), `data/appdata_*/preview` (regenerable).

**Verified**: seed snapshot `4cf255ee` (538.839 GiB, 212k files); overnight incremental `d4017edb` (+62 GiB, dedup confirmed). Restore test from `d4017edb`: DB dump parses (214 tables, completion marker); user file sha256 + cmp byte-identical to live.

**Incidents**:
- Concurrent runs: 14h manual seed overlapped the 03:42 timer → manual run's prune hit a repo lock (no data harm; both snapshots clean).
- Timer runs as systemd service with no `$HOME` → `unable to open cache` warnings. Backups fine, but cache disabled = slower. TODO below.

**Deferred / TODO**:
- Fix systemd cache: set `HOME` or `RESTIC_CACHE_DIR` in the service unit.
- Prevent manual/timer collision (flock wrapper, or just don't run manually near 03:30).
- Commit sanitized script changes to repo (placeholder IP).
- Still pending downstream: MariaDB→Postgres conversion (now has its rollback), Odroid Nextcloud decommission (only after a bake period — NOT yet).
# Journal entries

Order: oldest at the bottom, newest at the top.

## 2026-05-29 — Phase 3: Nextcloud migrated to bee001 (the big one)

**Type**: migration · **Outcome**: success, verified end-to-end

**Why**: largest service (~573 GB, 4 users, custom image). Migrated Odroid M1 (ARM64) → bee001 (amd64), data onto CephFS.

**Approach**: maintenance-mode freeze on Odroid → logical DB dump → rsync user files (excl. caches) → restore into fresh MariaDB on bee001 → official image upgrade → Traefik file-route cutover → stop Odroid stack (rollback intact).

**Key decisions**:
- **CephFS for data** — Nextcloud is the first service big enough to justify the Ceph OSD. Created `cephfs` filesystem (single-replica pools, size 1), mounted at /srv/dm/ceph. Data, html, db, redis all under /srv/dm/ceph/nextcloud/.
- **Official `nextcloud:32`** instead of the custom `nextcloud:32-pdlib` — gains amd64, loses pdlib face-recognition. Memories ARM binaries (exiftool-aarch64, go-vod-aarch64) commented out in config.
- **Excluded appdata cache** from rsync — 720k+ preview/thumbnail files are regenerable. Copied only ~167k real user files (573 GB). Filecache (904k entries) reconciles; previews regenerate on demand.
- **MariaDB kept for now**, Postgres conversion deferred — instance complexity warranted one-risk-at-a-time. (Postgres conversion = next-session task.)
- **No GPU passthrough yet** — bee001 AMD GPU is card1 + renderD128 (groups video=44, render=991, NO /dev/video* nodes unlike Odroid). Deferred.

**Incidents**:
- First file rsync filled root LV (200G) — data was going to /srv on root, not Ceph. Root hit 100%. Fixed: set up CephFS, redirected to /srv/dm/ceph (1.2 TiB).
- Created two CephFS filesystems by accident (naming back-and-forth) → HEALTH_ERR (one MDS can't serve two FS). Fixed: deleted extra FS + pools.
- `mon_allow_pool_size_one` needed setting before size-1 pools allowed (EPERM otherwise).
- **MYSQL_ROOT_PASSWORD with `$` broke Docker Compose** — `$changeit` interpreted as variable, truncated the password silently. MariaDB initialized with wrong password. Fixed: changed `$`→`@`, wiped db dir, reinit. Lesson: alphanumeric-only passwords in .env.
- Config dir not writable — CephFS files owned by dm (1000), official image runs as www-data (33). Fixed: chown -R 33:33 (fast on CephFS — metadata-only).
- Version bump 32.0.5 → 32.0.10 (image newer than data) → ran `occ upgrade`, clean.

**Verified**: status.php 200 via Cloudflare→Traefik→bee001; all 4 users list; files:scan saleere = 8 folders/49 files/0 errors; files readable inside container; external HTTPS works; [browser login confirmed].

**Deferred**: Postgres conversion · GPU passthrough · Memories amd64 binaries · restic coverage of /srv/dm/ceph/nextcloud (currently restic only covers /srv/dm/services) · decommission Odroid Nextcloud after bake.

---

## 2026-05-29 — restic backup on bee001 (prerequisite for further migrations)

**Type**: install · **Outcome**: success, restore-verified

**Why**: bee001 had no backup. Required before migrating data-bearing services (Vaultwarden, Nextcloud). Established as a hard gate in the migration plan.

**Design**:
- **Native restic** (not containerized like Odroid's) — backups don't depend on Docker being healthy; simpler script; single static binary
- **Separate repo** `bee001-backups` on the RPi4 (decision B) — distinct encryption password from Odroid's repo; cleaner when RPi4 is later repurposed
- restic 0.18.1 from Ubuntu apt (matches upstream; repo backward-compat covers any drift)

**Secrets**:
- Repo password: `/root/.restic-password-bee001` (0400, root-only, on LUKS disk); copy in password manager; durable record committed sops-encrypted at `secrets/restic.sops.yaml`
- Root SSH key `/root/.ssh/id_ed25519_restic` authorized on RPi4 for unattended root-run backups (root reaching into /home/dm/.ssh would be fragile)

**Backup scope**: `/srv/dm/services`, `/etc`, `/opt/web3home`. Excludes logs/tmp/cache.

**Schedule**: systemd timer daily 03:30 + RandomizedDelaySec 900, Persistent=true (runs at next boot if missed). Nice=10, IOSchedulingClass=idle. Sunday integrity check (5% data subset). Retention 7d/4w/12m/2y.

**Verified**:
- First backup: snapshot `5f87733c`, 1632 files, 93 MiB → 34.5 MiB stored (dedup+compression)
- **Restore tested**: restored ghost.db to scratch, `cmp` confirmed byte-identical to live
- Timer armed and listed

**Committed**: `system/restic/` (script + service + timer, IPs sanitized to placeholders), `secrets/restic.sops.yaml`.

**Note**: when Odroid is decommissioned and RPi4 repurposed as a Ceph node, this backup target must relocate (bee001 local + off-host USB, or cloud backend like B2). Deferred to Phase 4.

---

## 2026-05-28 — Phase 3 step 1: Ghost migrated to bee001

**Type**: migration · **Duration**: ~2 hr (incl. detours) · **Outcome**: success

**Why**: first service migration from Odroid M1 to bee001. Ghost chosen as lowest-risk (public blog, ~127 MB, SQLite, no DB container).

**Approach**: Option β — keep Traefik on Odroid; move only Ghost's process + data to bee001; point Odroid's Traefik at bee001 via file-provider route. Avoids migrating Traefik prematurely.

**Steps**:
- Installed Docker CE on bee001 from Docker's official apt repo (Engine 29.5.2, Compose v5.1.4, Buildx 0.34.1); verified GPG fingerprint 9DC8…CD88
- Set up bee001→Odroid SSH key auth (new dedicated `id_ed25519` key, separate from GitHub key)
- rsync'd Ghost content (~127 MB, 565 files) from Odroid to `/srv/dm/services/ghost/content/` on bee001
- UID match confirmed (both `dm` and Ghost-in-container are 1000) — no chown needed
- Wrote sanitized `docker/ghost/compose.yaml` + `.env.example` + `README.md`; real SMTP creds + bind IP in gitignored `.env`
- Created `traefik` docker network on bee001; brought Ghost up; smoke-tested via curl with Host header (correct 301→https, real content rendered)
- Added `ghost-bee001` router + service to Odroid's Traefik file provider (`dynamic.yml`), pointing at bee001:2368, priority 100, with `security-headers` + `rate-limit` middlewares + `modern@file` TLS
- Bound bee001's Ghost port to LAN IP only via `${GHOST_BIND_IP}` env var (Docker-bypasses-UFW gotcha noted)
- Stopped Ghost on Odroid; verified site still served (now exclusively bee001)

**Verified**:
- `https://web3home.info/` returns HTTP/2 200 via Cloudflare → Odroid Traefik → bee001 Ghost
- Security headers present in response (HSTS, X-Frame-Options, CSP middleware applied)
- bee001 Ghost logs show real external traffic (200s on pages, assets, member API)
- Odroid Ghost container `Exited (0)`

**Incidents**:
- Stopped Odroid's Ghost BEFORE adding the file-provider route → 404 for a few minutes. Recovered by restarting Odroid Ghost, then doing the cutover in the correct order (add route → verify → stop old). Lesson: for label-based routes, the fallback route must exist before removing the source.
- First `dynamic.yml` edit accidentally overwrote the `headscale` service URL (pointed it at Ghost). Caught via Traefik logs (`service ghost-bee001 does not exist`), fixed by restoring `http://headscale:8080` and adding `ghost-bee001` as a proper sibling.

**Decisions**:
- Delta rsync skipped — Odroid Ghost only ran briefly post-initial-sync during recovery; only ephemeral data (sessions, view counts, logs) differed, no real content. Initial rsync had 100% of content.
- Local storage on bee001, not Ceph — single-OSD cluster has no replication benefit yet. Move to CephFS/RBD when cluster has 2+ OSDs.

**Known issues deferred**:
- Pre-existing Traefik warning on Odroid: `headscale` + `headscale-grpc` routers "cannot be linked automatically with multiple Services." Predates this work. Fix during Headscale migration.
- Docker port-publishing bypasses UFW; mitigated by binding to specific LAN IP. Full fix when Ghost moves onto internal Docker network (no published ports) at Traefik migration.
- bee001 Ghost has no restic backup yet. Acceptable for Ghost (not actively writing). MUST set up restic-on-bee001 before Vaultwarden/Nextcloud migrations.

**Rollback path** (still available during bake): restart Ghost on Odroid (`docker start ghost-cms`), remove `ghost-bee001` route from Odroid's `dynamic.yml`. Odroid data untouched, still in restic snapshots.

---

## 2026-05-27 — Discovered existing restic backup infrastructure

**Type**: external · **Outcome**: noted, no action

**Why**: during Ghost migration planning, inventory revealed an existing restic backup setup. Updating mental model + agent context.

**Configuration**:
- Source: Odroid M1 (`/opt`, `/etc`, `/srv`, `/mnt/nvme`)
- Target: dedicated Raspberry Pi at internal IP, `restic` over SFTP
- Retention: 7 daily, 4 weekly, 12 monthly, 2 yearly
- Weekly integrity check (5% data subset) on Sundays
- ~600 GB current snapshot size
- Script: `/usr/local/bin/restic-backup-secure.sh` on Odroid
- Container-based execution (`restic/restic:latest`)

**Implications**:
- Provides an off-machine recovery path for everything on Odroid
- Migration phase risk reduced — restored data is the ultimate fallback
- The backup Pi is currently performing a critical role; treat as untouchable infrastructure during migration
- Decision deferred: when Odroid is eventually wiped and rejoins as a Ceph node, the backup script needs to live somewhere (bee001 likely) and point at a new source list

**Sovereignty alignment**: ✓ — self-hosted backup target on owned hardware; encrypted via restic password file; off-host (different physical device); regularly verified.

---

## 2026-05-27 — Phase 2 complete: MicroCeph cluster bootstrapped

**Type**: install · **Duration**: ~1.5 hr · **Outcome**: success

**Why**: stand up MicroCeph as the storage layer that will eventually host Docker volumes, CephFS, and (later) RGW object storage. Bootstrap single-node now; expand to multi-node when Odroid M1 + RPi4 join.

**Versions**:
- MicroCeph snap: `squid/stable` channel, held against auto-refresh
- Ceph version: 19.2.3 (Squid)
- MicroCeph git: fd93b718e2

**Steps**:
- `sudo snap install microceph --channel=squid/stable`
- `sudo snap refresh --hold microceph` (sovereignty: control upgrade cadence)
- `sudo microceph cluster bootstrap`
- `sudo microceph disk add /dev/mapper/ceph-osd --wipe` — claimed the LUKS-encrypted ~1.2 TiB partition as the first OSD
- `sudo microceph.ceph config set global osd_pool_default_size 1`
- `sudo microceph.ceph config set global osd_pool_default_min_size 1`
- Smoke tested via `rados put` / `rados get` using `/var/snap/microceph/common/` for I/O (snap confinement blocks `/tmp/`)

**Configuration choices**:
- Single-replica default (size=1, min_size=1) — accepted tradeoff until additional OSDs join. Documented in mute below.
- `mon_warn_on_pool_no_redundancy false` — defensive setting; current Ceph still emits POOL_NO_REDUNDANCY warnings despite this.
- `health mute POOL_NO_REDUNDANCY 1y --sticky` + same for `POOL_HAS_NO_REPLICAS_CONFIGURED` — keeps HEALTH_OK meaningful so real warnings (OSD down, disk near-full) stand out.
- `mon_allow_pool_delete false` (default kept) — pool deletion requires explicit toggle each time. Defense against typos.

**Verified**:
- `microceph status`: 1 OSD up, all services (mds, mgr, mon, osd) running on bee001
- `ceph -s`: HEALTH_OK with annotated mutes
- `ceph osd tree`: bee001 in default root, 1.23039 weight
- `ceph df`: 1.2 TiB raw available
- Smoke test: 16-byte object round-tripped via `rados put` / `rados get`; `diff` confirmed byte-identical

**Snap confinement gotcha** (logged for future): MicroCeph's snap cannot read `/tmp/` or other arbitrary host paths. Use `/var/snap/microceph/common/` for file I/O when feeding `rados`, `rbd`, etc.

**Open items deferred**:
- **Pool layout for actual workloads** — RBD pool for Docker volumes, CephFS pool for shared file storage, RGW pool for object storage. Decision deferred until we start the Odroid migration to know exactly what shapes of storage we need.
- **Replication bump to 2 or 3** — when Odroid M1 + RPi4 join as OSDs.
- **Public/cluster network separation** — currently both run on the single `enp197s0` NIC. Worth splitting when we have a 2nd NIC active.
- **CephFS file system creation** — not needed yet; will create when first service requires shared-file semantics.
- **RGW (S3-compatible)** — enable later if/when a service needs object storage.

---

## 2026-05-26 — Tweak: bound systemd-networkd-wait-online to first interface

**Type**: tweak · **Outcome**: applied, not yet verified

**Why**: every boot was hanging ~2 minutes on `systemd-networkd-wait-online.service`. `systemd-analyze blame` showed the wait-online service at 2:00.041, with the underlying cause being that the Beelink has three network interfaces (two onboard 10GbE NICs and one Wi-Fi) and the default behavior waits for ALL to reach "routable" state. With only `enp197s0` actually connected, the service times out at 120s for the unused interfaces.

**Fix**: drop-in override at `/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf` changing the command to `--any --timeout=20`. Boot now waits for any one interface (typically `enp197s0`) to come online, with a 20s ceiling.

**Verified**: pending. Not yet rebooted. Validate on next routine reboot.

**Rollback**: `sudo rm /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf && sudo systemctl daemon-reload`. Config is also tracked at `system/systemd/systemd-networkd-wait-online-override.conf`.

**Sources**:
- https://github.com/systemd/systemd/issues/28927
- https://www.baeldung.com/linux/systemd-networkd-wait-online-service-timeout-solution

---

## 2026-05-26 — Privacy audit of repo after Phase 1

**Type**: tweak · **Outcome**: clean

**Why**: pre-publication sweep after pushing Phase 1 journal entries. Checking for accidentally-committed internal IPs, MAC addresses, personal paths that fingerprint the operator.

**Steps**:
- `grep -rn -E '<rfc1918 ip patterns>' --include='*.md' --include='*.yaml' ...` across all committed text files
- `grep -rn -E '<mac address pattern>'` likewise
- `grep -rn '/home/dm'` for user-specific paths

**Result**:
- Only IP hit: `PRIMARY_NODE_IP=192.168.1.10` in `.env.example` — generic placeholder on the 192.168.1.x range, intended. Keep.
- No MAC addresses committed.
- No `/home/dm` paths committed.

**Convention reinforced**: local config files on individual machines (e.g. `/etc/fail2ban/jail.local`) may reference real internal IPs and never get committed. Templates and examples in the repo use the 192.168.1.x range as placeholder. Future commits of host-specific configs must redact through sops or substitute placeholders.

---

## 2026-05-25 — Phase 1 complete: bee001 hardened and joined the repo

**Type**: install · **Duration**: ~3 hr · **Outcome**: success

**Why**: complete Phase 1 of the buildout — primary node provisioned with encrypted storage, hardened, and integrated into the IaC workflow.

**Steps**:
- Set timezone
- Configured static IP `192.168.x.x` via DHCP reservation on router
- Apt update/upgrade (4 pending security updates applied)
- Shrank LVM volume group from 1.86 TiB → 600 GiB across all five layers (PV, LUKS, partition) without unmounting root
- Created new partition `nvme0n1p4` (~1.26 TiB) in the freed space
- LUKS2-formatted partition with keyfile + passphrase as separate keyslots
- Added to `/etc/crypttab` with keyfile chain so root passphrase transitively unlocks via systemd at boot
- Two reboots performed during the process; both unlock-and-boot sequences successful
- Installed git, age, sops v3.13.1, gitleaks v8.30.1, pre-commit 4.6.0 on bee001
- Configured UFW with deny-incoming / allow-SSH defaults
- Installed and configured fail2ban (sshd jail; LAN ignored)
- Created `/etc/apt/apt.conf.d/52unattended-upgrades-local` override to explicitly disable auto-reboot
- Disabled apport and whoopsie (sovereignty: no crash report uploads to Canonical)
- Silenced Ubuntu Pro / ESM nag in MOTD
- Generated bee001-specific SSH key, added to GitHub
- Generated bee001-specific age key, added as second recipient in `.sops.yaml`
- Cloned `web3home-infra`, ran `pre-commit install`, all hooks pass
- SSH hardening: key-only auth via drop-in config at `/etc/ssh/sshd_config.d/99-web3home-hardening.conf`; verified from second terminal before trusting

**Verified**:
- `lsblk` shows clean layout: `nvme0n1p3 → dm_crypt-0 → ubuntu-vg → {root, swap, games}` and `nvme0n1p4 → ceph-osd`
- Both LUKS volumes unlock automatically with one passphrase at boot
- Multi-recipient sops verified end-to-end: encrypted test file shows 2 `recipient:` entries; bee001 decrypts successfully
- Fresh SSH session lands at prompt with key-only auth; password auth refused

**Rollback**: most steps individually reversible; the partition shrink is the only effectively-permanent change. Backups taken of `/etc/crypttab` and `/etc/fstab` before LVM ops at `/etc/{crypttab,fstab}.bak-2026-05-25`.

**Open items deferred to later phases**:
- Phase 4: dropbear-initramfs over Headscale for remote LUKS unlock
- Stress-test the Realtek RTL8127 NICs under real workload to validate stock r8169 driver vs. installing Beelink-provided r8127 vendor driver
- BIOS Performance Mode (140W TDP) decision deferred to post-stability

---

## 2026-05-25 — Decision: stay on stock `r8169` driver for Realtek RTL8127 NICs

**Type**: decision · **Outcome**: decided

**Why**: discovered the Beelink shipped motherboard revision 2.2 with dual Realtek RTL8127 10GbE controllers, not the problematic Intel E610-XT2 from earlier batches. April 2026 production batch confirmed to have this revision. Currently working stably under kernel 7.0 with the in-tree r8169 driver. Beelink distributes an out-of-tree r8127 vendor driver as an alternative.

**Decision**: do not install the vendor driver. Stay on stock r8169.

**Rationale**:
- Current driver works, no NIC drops observed
- Out-of-tree DKMS modules add maintenance burden across kernel updates
- Forum evidence on necessity is mixed: some rev 2.2 users report stability with stock kernel, some report drops with both
- Vendor driver tarball references kernel 2.4.x/2.6.x in its README (maintenance discipline unclear)
- USB Ethernet dongle remains available as a known-good fallback for cluster workloads

**Re-evaluate if**: actual NIC drops occur under sustained workload. Vendor tarball archived locally for reference; not committed to repo.

**Sources**:
- https://bbs.bee-link.com/d/7762-gtr-9-pro-ethernet-malfunction-under-load (multiple pages)
- https://community.intel.com/t5/Ethernet-Products/E610-XT2-BSOD-NIC-hang-firmware-vs-driver-mismatch
- Beelink CS-Ian Chan statements throughout the forum thread

---

## 2026-05-25 — Decision: LVM-on-LUKS for OS + raw LUKS partition for Ceph OSD

**Type**: decision · **Outcome**: decided

**Why**: the Beelink has a single 2TB NVMe drive. Both the OS (with games partition) and the future Ceph OSD must live on it. Considered three layouts during install.

**Final layout**:
- `/boot/efi` (1 GiB, unencrypted, fat32)
- `/boot` (2 GiB, unencrypted, ext4)
- `nvme0n1p3` (600 GiB, LUKS-encrypted, hosts LVM volume group with root/swap/games)
- `nvme0n1p4` (~1.26 TiB, separately LUKS-encrypted, raw block for MicroCeph)

**Rejected alternatives**:
- All-in-one LVM-on-LUKS (Ceph OSD as LV inside ubuntu-vg): rejected because MicroCeph prefers raw block devices for predictable OSD performance and easier rebalancing
- Per-partition LUKS for each volume: rejected because Ubuntu installer's UI for this in 26.04 is fragile (first install attempt crashed subiquity)

**Unlock chain**: one passphrase entry at cold boot unlocks `nvme0n1p3` (root). Once root is mounted, systemd reads a keyfile at `/etc/cryptsetup-keys.d/ceph-osd.key` and unlocks `nvme0n1p4` automatically. Two LUKS volumes, single passphrase prompt for the user.

**Verified**: rebooted twice during the build; both unlock-and-mount sequences worked correctly.

---

## 2026-05-25 — Incident: oops.env from gitleaks smoke test reached `main`

**Type**: incident · **Outcome**: resolved by interactive rebase + force push

**Why**: during Phase 0, a second gitleaks smoke test with a high-entropy fake GitHub PAT (`ghp_abc...`) made it onto `main` and was pushed to GitHub, despite the local pre-commit hook being installed. The reverted-via-`git revert` first smoke test also remained reachable in `main`'s history.

**Root cause (unclear)**: hook was installed correctly (confirmed in this session by `pre-commit run` and by observing the hook fire on later commits). Most likely either the commit was made with `--no-verify` (consciously or by typo), or the hook was tested with `pre-commit run --all-files` rather than as a real commit hook. Pre-existing belief that "gitleaks blocked the commit" was incorrect.

**Fix**:
- Interactive rebase from the last good commit (`6a8a018`) on bee001, dropping all three bad commits (`da5f916`, `7060b9d`, `9b794d3`)
- Verified gitleaks passes on the rewritten history before pushing
- `git push --force-with-lease origin main` rewrote remote `main` to the clean state
- Reset laptop's local clone to match

**Verified**:
- `gitleaks detect --source=.` returns clean on bee001's clone
- GitHub Actions gitleaks workflow green after force push
- No commits matching `test: this should fail` visible in `main`'s history on GitHub
- Subsequent commits via pre-commit hook show the hook running correctly

**Lesson logged**: even with pre-commit installed, manual commits can bypass hooks (`--no-verify`, alternative tools, IDE git integrations). The server-side GitHub Actions backstop catches what local hooks miss, but only if it actually fails on the leak — the fake high-entropy PAT did flag locally, so the original GitHub Actions runs must have shown failures too (not noticed at the time).

**Process improvement**: when running smoke tests, always do the full `git commit` flow rather than `pre-commit run --all-files`. The hook only protects commit-time, not run-time.

---

## 2026-05-25 — Decision: separate age keys per machine, multi-recipient sops

**Type**: decision · **Outcome**: decided

**Why**: bee001 needed sops capability. Considered copying the laptop's age key vs. generating a new one.

**Decision**: each machine gets its own age key. Both public keys listed in `.sops.yaml` as multi-recipient.

**Rationale**:
- Each private key stays on its owning machine (LUKS-protected disk only)
- If one machine is compromised, rotate only its key — not all of them
- Mirrors the SSH key model (one key per machine)
- Sops handles N recipients natively; encrypted blob grows by ~150 bytes per recipient (negligible)

**Verified**: encrypted test file shows 2 `recipient:` entries; bee001 decrypts using its own private key without needing the laptop's.

**Backup**: laptop's age key + bee001's age key both backed up via the chosen offline method (paper/Vaultwarden). If laptop key is compromised, rotate by removing it from `.sops.yaml`, re-encrypting all sops files in the repo with `sops updatekeys`, and committing.

---

## 2026-05-25 — Phase 0 complete: secrets toolchain operational

**Type**: install · **Duration**: ~1.5 hr · **Outcome**: success

**Why**: Phase 0 requires automated privacy enforcement before any sensitive configs land in the repo. Manual `git diff | grep` review is too easy to forget.

**Source / pinned versions**:
- age 1.1.1 — Ubuntu 24.04 apt
- sops v3.13.1 — https://github.com/getsops/sops/releases/tag/v3.13.1
- gitleaks v8.30.1 — https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1
- pre-commit 4.6.0 — via pipx
- gitleaks-action @v2 — https://github.com/gitleaks/gitleaks-action
- action-shellcheck @2.0.0 — https://github.com/ludeeus/action-shellcheck

**Steps**:
- Installed all four tools, verified versions
- Generated age keypair at `~/.config/sops/age/keys.txt` (chmod 600, outside repo)
- Created `.sops.yaml` with rules for `*.sops.yaml` and `secrets/**` paths
- Created `.pre-commit-config.yaml` with gitleaks + standard hygiene hooks
- Ran `pre-commit install`
- Added `.github/workflows/gitleaks.yml` and `.github/workflows/shellcheck.yml`
- Verified safety net: a fake high-entropy GitHub PAT was blocked by the local hook
- Verified server backstop: both Actions workflows ran green on first push

**Verified**:
- `pre-commit run --all-files` passes
- High-entropy test commit blocked locally
- Both GitHub Actions workflows green on the Actions tab

**Rollback**: `pre-commit uninstall` removes the local hook. The age private key is the only irreplaceable artifact — backed up to <FILL IN your method>.

---

## 2026-05-25 — Decision: chose Gitleaks v8.30.1 over Betterleaks

**Type**: decision · **Duration**: 15 min · **Outcome**: decided

**Why**: discovered during Phase 0 that Zach Rice (Gitleaks creator) launched Betterleaks in Feb 2026 with materially better recall (98.6% vs Gitleaks' 70.4% on CredData benchmark).

**Decision**: Gitleaks v8.30.1 for Phase 0. Re-evaluate Betterleaks in ~6 months.

**Rationale**:
- Betterleaks is very new (~470 stars vs Gitleaks' 25k+) and pre-commit integration is still catching up
- Betterleaks is positioned as a drop-in replacement, so migration cost when mature is low
- For a homelab repo with sops + manual review upstream, Gitleaks' 70% recall as automated backstop is acceptable
- Asymmetric risk: immature tooling can break the pipeline; mature tooling missing edge cases is mitigated by other layers

**Sources**:
- https://www.helpnetsecurity.com/2026/03/19/betterleaks-open-source-secrets-scanner/
- https://github.com/getsops/sops/releases (sops v3.13.1)
- https://github.com/gitleaks/gitleaks/releases (gitleaks v8.30.1)

**Re-evaluation triggers**: Betterleaks >5k stars OR official pre-commit hook lands OR a real Gitleaks miss is found in this repo's history.

---

## 2026-05-25 — Incident: gitleaks smoke test passed a fake AWS key

**Type**: incident · **Duration**: 20 min · **Outcome**: resolved

**Why**: tested the pre-commit hook with `AKIAIOSFODNN7EXAMPLE` (AWS docs' canonical example). Gitleaks did not flag it; commit landed and was pushed to remote before the gap was noticed.

**Root cause**: gitleaks maintains an allowlist of well-known documentation placeholders to suppress false positives. AKIAIOSFODNN7EXAMPLE is on it. The chosen test value tested only the regex, not the allowlist behavior.

**Workaround**:
- Reverted the bad commit with `git revert` (preserved history; no force-push)
- Retested with a high-entropy GitHub PAT-shaped value (`ghp_...`) — hook fired correctly
- Updated `agents/microceph-agent.md` to v1.2 with explicit guidance against documentation placeholders in smoke tests

**Verified**: clean revert pushed; proper smoke test now blocks correctly; agent prompt encodes the lesson.

**Rollback**: not needed.

---

## 2026-05-25 — Decision: age private key backup strategy

**Type**: decision · **Duration**: 10 min · **Outcome**: decided

**Why**: the age private key at `~/.config/sops/age/keys.txt` decrypts every secret in this repo. Loss = all secrets unreadable. Leak = full breach. Backup is mandatory before relying on sops.

**Decision**: <FILL IN your chosen method — paper, Vaultwarden, USB stick, combination>

**Rejected**: cloud storage (violates self-custody), single laptop copy (SPOF on disk failure).

**Verification**: <describe how you confirmed the backup is recoverable — e.g. "decrypted a test sops file using only the restored backup">

**Rollback if compromised**: generate new age keypair → re-encrypt all `*.sops.yaml` files with new public key → update `.sops.yaml` in repo → destroy old key material.


## 2026-05-25 — Adopted Markdown-only agent format (archived JSX artifact)

**Type**: decision · **Duration**: 30 min · **Outcome**: success

**Why**: the agent was initially built as a React/JSX artifact rendered inside a Claude chat. Reviewing it against project principles surfaced three problems:
1. Ephemeral — the artifact doesn't persist across sessions and isn't version-controlled
2. Sovereignty violation — relied on an external chat UI for what should be a self-hostable tool
3. Inconvenient — couldn't be diff-reviewed, couldn't run alongside the rest of the stack

Adopted Option 3 from the agent-architecture discussion: prompts live as Markdown files in `agents/`, the "runtime" is whichever LLM the operator chooses (Claude, ChatGPT, Open WebUI + Ollama, Claude Code). The valuable artifact is the prompt itself, not the wrapper.

**Source**: agent-architecture trade-off analysis in design discussion (2026-05-25).

**Steps**:
- Extracted full system prompt from JSX into `agents/microceph-agent.md`
- Added `agents/README.md` documenting usage options
- Archived the JSX file out of repo (kept locally for reference only)
- Bumped changelog inside `microceph-agent.md` to v1.0

**Verified**: `gitleaks detect --source=agents/` returns clean. File renders correctly on GitHub preview.

**Rollback**: revert the commit; the JSX archive can be restored from local backup if Markdown-only proves limiting.

---

## 2026-05-25 — Initial repository scaffolding

**Type**: decision · **Duration**: 1 hr · **Outcome**: success

**Why**: establish public-from-day-one FOSS posture matching Sovereignty Grid principles. Repository serves as both the operational source of truth for the buildout and the public reference companion to the web3home.info white paper.

**Source**: web3home.info white paper, Sovereignty Grid framing.

**Steps**:
- Created `github.com/web3home/web3home-infra` (public, GPLv3)
- Drafted `README.md` with scope-of-sovereignty disclosure (FOSS-first, not FOSS-pure)
- Defined monorepo layout: `system/`, `ceph/`, `docker/`, `migration/`, `agents/`, `.github/workflows/`
- Established conventions: GPLv3 license, conventional commits, generic placeholders for all sensitive values, sops + age for secrets, gitleaks pre-commit hook

**Verified**: repo loads at `github.com/web3home/web3home-infra`, README renders, license badge correct.

**Rollback**: not applicable — establishing a baseline.

---

## 2026-05-25 — Decided: LUKS unlock strategy

**Type**: decision · **Duration**: 45 min · **Outcome**: decided

**Why**: needed a unified position on disk encryption unlock before any installation. Considered five options:
1. Plain LUKS with manual passphrase only — chosen for Phases 0-3
2. dropbear-initramfs over Headscale — deferred to optional Phase 4 add-on
3. TPM2 auto-unlock — rejected (stolen running machine self-decrypts; defeats threat model)
4. Clevis/Tang network-bound encryption — rejected (adds SPOF; weakens sovereignty)
5. Mutual unlock between Beelink and RPi4 — rejected (circular deadlock after power cut)

**Source**: threat-model analysis; web3home.info Sovereignty Grid principles.

**Steps**: documented in `agents/microceph-agent.md` § LUKS unlock strategy.

**Verified**: agent prompt rejects options 3-5 explicitly when proposed.

**Rollback**: re-open the decision in a follow-up entry; never silently change unlock strategy.

---

## 2026-05-25 — Decided: 2TB partition layout

**Type**: decision · **Duration**: 20 min · **Outcome**: decided

**Why**: Beelink GTR9 Pro has a single 2TB NVMe and is dual-role (homelab + gaming). Games on the same partition as Ceph OSD would starve OSD IOPS via write churn. Separation is required.

**Source**: typical homelab Ceph performance guidance; Strix Halo storage layout considerations.

**Final layout**:
```
/boot/efi   1 GiB     FAT32
/boot       2 GiB     ext4 (unencrypted)
/           200 GiB   LUKS2 → ext4   OS + Docker + GUI
swap        16 GiB    LUKS2 → swap
/games      300 GiB   LUKS2 → ext4   Steam library (noatime)
ceph-osd    ~1.45 TiB LUKS2 raw      MicroCeph OSD
```

Keyfile chain: root passphrase unlocks `/`, then root holds keyfiles auto-unlocking the others via `/etc/crypttab`.

**Verified**: pending — applied during Phase 1 install.

**Rollback**: requires full reinstall; partition decisions are effectively permanent post-install.

## 2026-07-19 — private-stacks pattern; multi-root boot scan

Support for stacks kept OUT of this public repo. `~/code/private-stacks/docker/` holds
their compose + `.env`; content on CephFS. `compose-boot-up.sh` now scans BOTH roots
(SCAN_DIRS) — an out-of-repo stack was otherwise invisible and never started at boot
(the spleeter-web trap). First attempt used a QUOTED brace expansion, which skips
pathname expansion so the glob stayed literal and 0 stacks started; fixed with a nested
loop. git has no copy of private-stacks, so it and the private content path are both in
BACKUP_PATHS.

**Google Fonts / GDPR:** a static site pulling fonts from googleapis.com sends visitor
IPs to Google pre-consent. LG München I, 3 O 17493/20 (2022): €100 + injunction + costs.
Fetch CSS with a modern UA (else TTF not woff2), pull woff2 local, rewrite to relative
paths, verify 0 gstatic refs.

**Registrar-parking wildcard = ACME trap:** moving DNS to Cloudflare can import a parking
`* -> host` wildcard that matches `_acme-challenge.<domain>`, so lego follows it and
tries to write TXT in a zone the token can't touch (`zone could not be found`). Delete
the wildcard, point www at apex. Then NS-delegation caching lingers — Cloudflare shows
"Active" while resolvers still cache old NS. Let's Encrypt caps 5 failed validations
/hostname/hour; don't restart-to-retry while delegation is stale.

**WiZ/HA:** `network_mode: host` (UDP broadcast :38899); ufw governs the port; paired
only after allowing 38899/udp.
