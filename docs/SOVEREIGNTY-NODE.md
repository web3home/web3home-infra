# Building a Digital Sovereignty Node

A field-tested guide to building a self-hosted sovereignty node: encrypted
storage, distributed filesystem, containerized services, GPU-local AI, and
verified backups — on a single small-form-factor box.

Reference hardware: AMD Strix Halo mini-PC (Ryzen AI MAX+ 395, Radeon 8060S
iGPU, 128 GB unified memory), Ubuntu 26.04 LTS. The patterns apply to any
Linux homelab node.

> **Conventions.** All IPs use the RFC 5737 documentation range
> `192.0.2.0/24` (node 1 = `.10`, legacy edge = `.11`, backup = `.21`) —
> substitute your own. Paths, hostnames, and unit names are examples; a
> systemd mount unit's name must match its mountpoint path
> (`systemd-escape -p --suffix=mount /your/path`). Secrets, keys, real
> addresses, and usernames never enter this repo.

> **Verification status.** Every component is marked:
> ✅ battle-tested (survived real failure / reboot cycle) ·
> ⚠️ installed but not yet verified ·
> ❌ known broken or pending.
> Promotion rule: a component only becomes ✅ after it survives a full
> unattended reboot cycle or a real incident. Commit to the repo only after
> battle-test.

---

## 1. Architecture: sovereignty planes, current state, target state

This build implements the Sovereignty Stack from the web3home white paper
(*From Digital Dependency to Distributed Sovereignty*): sovereignty is won
bottom-up, layer by layer — policy bolted on top of rented infrastructure is
tenancy, not sovereignty. For infrastructure work the seven stack layers
group into three planes:

| Plane | Stack layers | What it means in this build |
|---|---|---|
| **Hardware** | Physical | Own the metal. Consumer hardware under your roof, disks encrypted (LUKS), no rented compute for core functions. |
| **Network** | Network · Protocol | Own the paths. Your own mesh (Headscale/WireGuard), your own ingress and TLS, open protocols (Nostr), and a deliberate exit from chokepoints (Cloudflare — §8). |
| **Software** | Communication · Computational · Data · Identity + Financial | Own the functions. FOSS services for files, publishing, messaging, AI inference, secrets, identity, money. |

The plane a problem lives in tells you what fixes it: no software setting
makes a Cloudflare-fronted blog network-sovereign, and no network design
makes rented cloud compute hardware-sovereign.

### 1.1 Current topology (transitional)

```
                    Internet
                       │
                 Cloudflare (DNS + proxy + TLS)      ← chokepoint, scheduled out
                       │
              Legacy edge (.11) — Traefik v3          ← scheduled for decommission
                       │ file-provider routes
        ┌──────────────┴───────────────────────────┐
        │        Sovereignty node (.10)             │
        │  LUKS ▸ LVM ▸ Ubuntu LTS                   │
        │  MicroCeph (mon/mds/osd, single OSD)       │
        │  Docker (gated on CephFS mount)            │
        │  ├─ Nextcloud   ├─ Ghost                   │
        │  └─ llama.cpp Vulkan + Open WebUI (AI)     │
        └──────────────────┬─────────────────────────┘
                           │ restic over SFTP
                  Backup target (.21, RPi4)
```

Honest reading: hardware and software planes are largely sovereign already;
the network plane still routes through two transitional dependencies (the
legacy edge box and Cloudflare) and storage has no redundancy yet.

### 1.2 Target topology

```
        Internet                          Private devices (laptop, phone)
           │                                        │
   DNS (neutral provider) + ACME TLS         Headscale mesh (self-hosted
           │                                  control plane on node 1)
   Router port-forward 80/443                       │
           │                                        │
        ┌──┴────────────────────────────────────────┴──┐
        │  Node 1 (.10) — compute + ingress             │
        │  Traefik (migrated) · Headscale (migrated)    │
        │  CrowdSec/Authelia hardening                  │
        │  Docker services: Nextcloud · Ghost ·         │
        │  Vaultwarden · Mattermost · Nostr relay ·     │
        │  Home Assistant · local AI                    │
        │  Ceph: mon + mds + osd                        │
        ├───────────────────────────────────────────────┤
        │  Node 2 (.11, repurposed legacy edge)         │
        │  Ceph: mon + osd                              │
        ├───────────────────────────────────────────────┤
        │  Node 3 (.21, RPi4)                           │
        │  Ceph: mon (quorum) · restic target           │
        │  (restic repo on LOCAL disk — never on Ceph)  │
        └───────────────────────────────────────────────┘
              3-node Ceph cluster, replication 2–3
```

Public surface shrinks to what is genuinely public (the blog, selected
endpoints); everything else moves behind the mesh. Publishing gains a
censorship-resistant parallel channel via the Nostr relay — reachable even
if DNS or ingress is interfered with.

### 1.3 Migration phases

1. **Services off the legacy edge** → node 1 (Ghost ✅, Nextcloud ✅, AI ✅;
   remaining: Vaultwarden → Nostr → Mattermost → Home Assistant).
2. **Ingress + mesh migration**: Traefik and Headscale (fresh, current
   version) move to node 1; legacy edge stops proxying.
3. **Storage redundancy**: legacy edge re-images as Ceph node 2; RPi4 joins
   as mon quorum; replication raised from 1 to 2–3.
4. **Cloudflare exit** (§8): DNS to a neutral provider, direct ACME TLS,
   hardened direct exposure or self-managed edge.

Design principles throughout: encrypted at rest, re-buildable from repo +
backups, local AI inference, every recovery procedure rehearsed at least
once, and **no single rented chokepoint between you and your data**.

---

## 2. Foundation: disk, encryption, boot ✅/⚠️

### Layout
- `nvme0n1p1/p2` — EFI + /boot (unencrypted)
- `nvme0n1p3` — **LUKS** → LVM VG `ubuntu-vg` → `ubuntu-lv` (root),
  `lv-swap`, `lv-games`
- `nvme0n1p4` — **LUKS** (keyfile auto-unlock, `nofail`) → Ceph OSD

### crypttab (the contract that makes boot work)
```
cryptroot  UUID=<root-luks-uuid>  none                                  luks
ceph-osd    UUID=<osd-luks-uuid>   /etc/cryptsetup-keys.d/ceph-osd.key   luks,nofail
```
Root prompts for a passphrase at boot; the OSD unlocks itself via keyfile and
must be `nofail` so a storage hiccup never blocks boot.

### Hard-won rules
1. ✅ **After ANY kernel/initramfs-touching change, rebuild and verify:**
   ```
   update-initramfs -u -k all
   lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'crypttab|cryptsetup'
   ```
   Both crypttab and the cryptsetup binaries MUST appear inside the image.
   A stale initramfs = no auto-unlock = dracut emergency shell.
   (Battle-tested: a stale initramfs caused exactly this; rebuild fixed it
   and the fix survived a subsequent boot.)
2. ✅ **Manual recovery from the dracut emergency shell** (rehearsed twice):
   ```
   cryptsetup open /dev/nvme0n1p3 cryptroot     # safe: open only, never format
   lvm vgchange -ay ubuntu-vg
   exit                                           # boot resumes
   ```
3. ✅ **Remote LUKS unlock (dropbear-initramfs): DONE — LAN scope.**
   Unlock the LUKS root over SSH at early boot (`-R` ephemeral host keys,
   key-only, forced `cryptroot-unlock`, port 2222, static IP). Works from the
   LAN only — dropbear predates the mesh, so no internet-scope unlock yet.
   See `system/dropbear/`.

---

## 3. Storage: MicroCeph + CephFS ✅/⚠️

Single-node MicroCeph (mon, mgr, mds, osd as snap services) serving CephFS,
mounted at `/srv/ceph`. Currently single-OSD (no redundancy) — replication
arrives when the cluster gains nodes (Phase 4).

### Least-privilege mount (✅)
Never mount with `client.admin`. Create a scoped client:
```
ceph auth get-or-create client.nextcloud \
  mon 'allow r' mds 'allow rw fsname=cephfs' \
  osd 'allow rw tag cephfs data=cephfs'
# key → /etc/ceph/nextcloud.secret (0400 root)
```

### The mount unit (✅ unit itself · ⚠️ boot-time auto-mount)
`/etc/systemd/system/srv-ceph.mount`:
```ini
[Unit]
Description=CephFS mount for /srv/ceph
After=network-online.target snap.microceph.daemon.service
Wants=network-online.target
Requires=snap.microceph.daemon.service

[Mount]
What=nextcloud@.cephfs=/
Where=/srv/ceph
Type=ceph
Options=mon_addr=192.0.2.10,secretfile=/etc/ceph/nextcloud.secret,_netdev
TimeoutSec=300

[Install]
WantedBy=multi-user.target
```
**Known-good options line is exactly the above.** The kernel rejects
unsupported options with `mount error 22 = Invalid argument` and the failure
message misleadingly complains about keyrings. (Battle-tested the hard way:
an invalid `recover` option broke mounting entirely.)

### Boot readiness gate (✅ battle-tested)
A mount that fires before CephFS is serving fails and stays failed. The
correct readiness signal is **an active MDS**, not mon TCP reachability — the
mon port answers a few seconds before the MDS is mountable, so a bare TCP poll
passes too early and the mount dies with `no mds is up`.
`wait-for-ceph-mon.service` polls `microceph.ceph mds stat` for `up:active`
(up to 180 s, covering MDS journal replay after an unclean boot); a drop-in
makes the mount `After=`/`Wants=` it. With this, the mount succeeds on the
first attempt after a **clean** boot and Docker auto-starts behind it.

**The gate is an optimisation, not a guarantee** — after an unclean shutdown it
can pass and the mount still fail. See the next section.

### Unclean-shutdown recovery: mount retry (✅ failure-injection tested)

Clean reboots are covered by the gate above. **Power loss is a different animal.**
The MDS can report `up:active` while the filesystem is still not serviceable (OSD
coming up, PGs peering), so the mount fires anyway and dies with
`no mds (Metadata Server) is up`. Then:

- `srv-ceph.mount` fails **once**. systemd has no native mount retry (upstream
  RFE #4468, never implemented). `automount` is not the answer either — it stays
  failed indefinitely after a failed attempt (#16811).
- `docker.service` and dependent units die as **dependency** failures →
  `inactive (dead)`, not `failed`. Nothing retries them, and an `OnFailure=` on
  them could never fire.

Real incident: services down **8 hours**, and recovery was accidental — the
nightly restic timer's `RequiresMountsFor=/srv/ceph` re-triggered the mount long
after Ceph had stabilised.

**Do not try to make the gate smarter.** No status string reliably predicts
mountability. Gating on `ceph -s` health is actively harmful on a single-OSD
node: HEALTH_OK there is artificial (it depends on muted `POOL_NO_REDUNDANCY` /
`POOL_HAS_NO_REPLICAS_CONFIGURED` warnings) and reverts to WARN when the mutes
lapse — the gate would then time out on every boot. Stability polling only
catches an MDS *flap*, not an MDS that is genuinely active while the OSDs aren't
ready.

**Retry is the guarantee.** Hang `OnFailure=` off the **mount** (which fails
properly), never off the dependency-failed units:

```ini
# /etc/systemd/system/srv-ceph.mount.d/20-retry-on-failure.conf
[Unit]
OnFailure=cephfs-mount-retry.service
```

That oneshot runs a helper which retries the mount for ~20 min and, **on success,
explicitly starts the dependent units** — deliberate recovery instead of an
accidental side effect. It exits immediately if a shutdown is in progress (same
lesson as the shutdown guard).

Test it without pulling power: `snap stop microceph.mds` reproduces the exact
`no mds is up` error while mon and OSD stay up. See `system/ceph/`.

### Never let Docker start before CephFS (✅ — prevented a real disaster)
Drop-in `/etc/systemd/system/docker.service.d/10-wait-cephfs.conf`:
```ini
[Unit]
RequiresMountsFor=/srv/ceph
After=srv-ceph.mount
```
Without this, containers bootstrap a blank install into the empty mountpoint
(the "shadow install" incident). With it, Docker simply stays down until the
mount exists — if Docker is "mysteriously not starting," this guardrail is
doing its job; fix the mount, Docker follows.

### Shutdown teardown (⚠️ 90% — systemd hang fixed, kernel stall remains)
The failure mode: network tears down → containers still hold CephFS open →
kernel client retries the dead mon forever (`libceph: ... error -101`) →
shutdown wedges → forced power-off.

`cephfs-shutdown-guard.service` (oneshot, `DefaultDependencies=no`,
`Before=shutdown.target`, `Conflicts=shutdown.target`) runs at shutdown:
stop all containers → stop docker → `umount`, escalating to `-f`, then `-l`.

**Cycle warning (battle-tested mistake):** do NOT also order this unit
`After=srv-ceph.mount` + `Before=network.target` — that creates an
ordering cycle and systemd silently deletes `network.target` from boot.
Always verify after unit changes:
```
systemd-analyze verify default.target   # must show no cycles
```

**Status: ✅ battle-tested.** The full clean cycle is proven — shutdown
completes on its own, the box power-cycles, and on boot CephFS auto-mounts and
Docker auto-starts with zero manual touches.

Two fixes made it work, both learned the hard way:
- **`docker kill`, not `docker stop`.** `docker stop` waits ~10 s per
  container for graceful exit; with several containers the guard blew past its
  `TimeoutStopSec`, systemd SIGKILLed it mid-run, a container (redis) survived
  into the final `sd-sync`, and the reboot wedged. `docker kill` (immediate
  SIGKILL) + force-unmount finishes in ~1 s. Services here are crash-safe, so
  graceful container shutdown buys nothing.
- **Order the guard `After=network.target network-online.target
  docker.service`.** At boot that means it *stops first* at shutdown — so its
  ExecStop runs while the network and Docker are still alive (clean unmount, no
  `-101` retry storm).
- **Shutdown-only guard clause.** The ExecStop begins with
  `systemctl list-jobs | grep -qE 'shutdown.target|reboot.target' || exit 0`
  so an accidental `systemctl restart` of the unit can never tear down
  production. (Lesson: a unit with a destructive ExecStop must never be
  casually restarted — `daemon-reload` alone applies file edits.)

**Still pending for remote operation:** boot still needs the LUKS passphrase
at the console OR remotely via dropbear-initramfs over the LAN (see §2), so a
LAN-scope remote reboot is now safe. NOTE: clean reboots are proven; unclean
(power-loss) shutdowns have a known boot-recovery gap — see JOURNAL 2026-07-13.

---

## 4. Container platform: Docker ✅

- Compose files live in the repo (`docker/<service>/compose.yaml`); state
  lives on CephFS or local volumes — the split is deliberate:
  *repo = how to run it, storage = what it holds.*
- Docker's `KillMode=process` means `systemctl stop docker` does NOT stop
  containers. Any teardown logic must `docker stop $(docker ps -q)` first.
- Passwords in `.env` files: **alphanumeric only** (Compose `$` interpolation
  silently corrupts values containing `$`).

---

## 5. Services

### Nextcloud ✅
Data + html on CephFS (`/srv/ceph/nextcloud`), MariaDB + Redis on local
volumes (DB on distributed FS = pain; excluded from file backup, captured via
SQL dump instead). All CephFS files owned UID/GID 33 (www-data).

### GPU AI stack: llama.cpp Vulkan + Open WebUI ✅
On Strix Halo (gfx1151), RADV Vulkan outperforms ROCm for llama.cpp, and
Ollama's vendored llama.cpp is stale — use upstream
`ghcr.io/ggml-org/llama.cpp:server-vulkan` directly:

```yaml
services:
  llama-server:
    image: ghcr.io/ggml-org/llama.cpp:server-vulkan
    devices: [/dev/dri/renderD128, /dev/dri/card1]
    group_add: ["991", "44"]        # host render + video GIDs (getent group)
    volumes: [/srv/ceph/llm/models:/models:ro]
    command: >
      -m /models/<model>.gguf -ngl 99 -fa on -c 8192
      --host 0.0.0.0 --port 8000 --alias <name>
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      start_period: 120s
  open-webui:
    image: ghcr.io/open-webui/open-webui:latest
    environment:
      - OPENAI_API_BASE_URL=http://llama-server:8000/v1
      - OPENAI_API_KEY=sk-noauth          # dummy; llama-server ignores it
      - WEBUI_AUTH=True
    volumes: [/srv/ceph/llm/webui-data:/app/backend/data]
    ports: ["3000:8080"]
```

Rules learned:
- Smoke-test GPU-in-container FIRST (`vulkaninfo` in a throwaway container
  with the same devices/group_add) before building the stack.
- Recent llama.cpp: `-fa` requires a value (`-fa on`); bare `-fa` crash-loops.
- The image's built-in healthcheck probes :8080 — override it to your real
  port or the container reports unhealthy forever.
- llama-server = ONE model per process. Multiple models → multiple services,
  each added to Open WebUI as an endpoint.
- Models: large + re-downloadable → on CephFS for space, **excluded from
  backup and gitignored** (`*.gguf`). WebUI data (chats/RAG/config):
  irreplaceable → **kept in backup**.
- Download with the HF CLI (`apt install python3-huggingface-hub`), with an
  HF token — anonymous 20 GB pulls stall on rate limits.

### Ghost ✅
Local volume, proxied from the edge node like everything else.

---

## 6. Edge: Cloudflare + Traefik ✅ (transitional — exit path in §8)

This is the *working* ingress today, documented because it serves traffic
right now — but it is a network-plane dependency scheduled for replacement
(§1.3 phases 2 and 4).

Pattern: Cloudflare (DNS, proxy, TLS) → Traefik v3 on the edge node →
file-provider routes to backend services by IP:port. To publish a new
service, clone an existing router+service pair in `dynamic.yml`:

```yaml
# routers:
llm-node:
  rule: "Host(`llm.example.org`)"
  service: llm-node
  entryPoints: [websecure]
  tls: { certResolver: cloudflare, options: secure@file }
  middlewares: [security-headers, rate-limit]
# services:
llm-node:
  loadBalancer:
    passHostHeader: true
    servers: [{ url: "http://192.0.2.10:3000" }]
```

Rules:
- Back up `dynamic.yml` before every edit; Traefik file-watch applies changes
  live — an indentation slip takes down working routes instantly.
- Open the backend's firewall to the proxy only:
  `ufw allow from 192.0.2.11 to any port 3000 proto tcp`.
- Anything public sits behind both Cloudflare and the app's own auth;
  add a Cloudflare Access policy for admin-grade surfaces.

---

## 7. Backups: restic ✅ (restore-verified)

restic → SFTP → independent target (RPi4). The non-negotiables:

1. **Dump databases pre-backup** (`mariadb-dump --single-transaction` →
   temp-then-rename + completion-marker check; truncated dump = abort).
   Never file-copy a live DB.
2. **Exclude the re-downloadable and the volatile:** live `db/`, `redis/`,
   preview caches, `llm/models`. Keep the irreplaceable: user data, configs,
   WebUI data, SQL dumps.
3. **A backup is not a backup until restored:** verify the DB dump
   (table count + completion marker) and at least one real user file
   (sha256 + byte-compare) from the actual repository.
4. Keep the previous node's repo intact as independent fallback until the
   new node has months of history.

---

## 8. Network sovereignty: the Cloudflare exit & remote access ❌ (planned)

### 8.1 What Cloudflare actually provides (know what you're replacing)

| Function | Sovereign replacement | Trade-off |
|---|---|---|
| DNS hosting | Neutral DNS provider (e.g. deSEC) or own authoritative NS pair | Registrar remains an irreducible dependency for ICANN domains |
| TLS issuance (proxy certs) | Traefik already does ACME — switch the challenge off Cloudflare's API to another DNS provider or HTTP-01 | None; this is the easiest step |
| IP masking | (a) accept exposure of the home IP, or (b) a rented VPS as a self-managed WireGuard front | (a) costs privacy; (b) re-introduces a rented box — but commodity, swappable, and yours to configure: a conscious dependency, not a platform |
| DDoS absorption | Realism: nothing self-hosted absorbs a volumetric attack | For a personal node the threat model rarely justifies the chokepoint; app-layer abuse is handled by CrowdSec + rate limits |
| Bot/WAF filtering | CrowdSec + Traefik middlewares (rate-limit, geo, Authelia for admin surfaces) | Self-managed effort |

### 8.2 The exit, in order of difficulty

1. **Shrink the public surface first.** Most services never needed to be
   public — they were public because the proxy made it easy. Target: only
   the blog (and chosen endpoints) stay public; Nextcloud, WebUI, admin
   panels move behind the mesh.
2. **TLS independence**: re-point Traefik's ACME challenge away from the
   Cloudflare API.
3. **DNS to a neutral provider**, un-proxied records pointing at the ingress.
4. **Direct exposure**: router port-forwards 80/443 → Traefik on node 1,
   hardened (CrowdSec, rate limits, Authelia on anything admin-grade) — or
   the optional VPS front if IP masking matters to your threat model.
5. **Protocol-layer resilience**: keep publishing on Nostr in parallel.
   A relay-replicated note needs neither your DNS nor your ingress —
   it is the channel that survives interference with both.

### 8.3 Private access: the mesh

- Headscale (self-hosted Tailscale control plane) is the access layer for
  everything non-public. **Known defect on the legacy deployment:** a netmap
  bug — new nodes register but receive zero peers (mutual invisibility);
  survived an in-place upgrade; not worth debugging on hardware slated for
  re-imaging. **Resolution: fresh, current-version Headscale on node 1 at
  migration (phase 2).**
- UFW on every node must allow the mesh explicitly once live:
  `ufw allow in on tailscale0` + `41641/udp`.
- Until the mesh works: selective publishing via the transitional edge
  (with app auth), LAN for the rest.

### 8.4 Residual dependency register (the honest list)

What remains non-sovereign even at target state, kept visible by design:

- **ISP / last mile** — physical-layer dependency; dynamic IP or CGNAT may
  force dynamic-DNS or a tunnel front. Mitigation is plurality (LTE backup),
  not elimination.
- **Domain registrar** — irreducible for ICANN names; Nostr identity and
  relay publishing are the protocol-layer hedge.
- **Power** — a UPS turns outages into clean shutdowns instead of the
  unclean-boot recovery drill (§9 exists because of this).
- **Hardware supply chain** — consumer silicon is trusted, not verified.
  Acknowledged and out of scope.

A dependency you can name, price, and swap is managed; one you cannot see is
the dangerous kind. The register exists so none move silently into the
second category.

---

## 9. Runbooks

### R1 — Node wedged at shutdown (libceph -101 spam, no progress)
Hold power 10 s → power on → LUKS passphrase at console → boot. Ceph
self-recovers (HEALTH_WARN → OK, MDS journal replay, minutes). Zero-loss
twice-rehearsed.

### R2 — Dracut emergency shell (LVM/LUKS not found at boot)
Section 2 recovery: `cryptsetup open` → `vgchange -ay` → `exit`.
Afterwards, on the running system: `update-initramfs -u -k all` + verify.

### R3 — After any unclean boot: bring services up
```
sudo systemctl start srv-ceph.mount     # if not auto-mounted
mountpoint /srv/ceph                     # verify before going further
sudo systemctl start docker
cd ~/code/web3home-infra/docker/nextcloud && docker compose up -d
cd ~/code/web3home-infra/docker/llm && docker compose up -d
```
Verify Nextcloud serves REAL data (`grep instanceid .../config.php`) —
guards against ever serving a blank install.

### R4 — Suspected blank/"shadow" install on CephFS path
Stop the stack. Mount CephFS to a TEMP path and verify the real data exists
there. Move the blank tree aside (never delete in the moment). Mount the real
FS at the service path. Start the stack. Verify instanceid.

---

## 10. Status matrix

| Component | Status |
|---|---|
| LUKS + LVM + initramfs auto-unlock | ✅ battle-tested |
| Emergency-shell recovery procedure | ✅ rehearsed twice |
| CephFS least-privilege mount unit | ✅ |
| Docker-gated-on-mount guardrail | ✅ prevented real data loss |
| Docker stack auto-start after reboot (web3home-stacks) | ✅ battle-tested |
| Remote LUKS unlock (dropbear, LAN scope) | ✅ proven |
| Unclean-shutdown boot recovery (mount retry chain) | ✅ failure-injection tested |
| restic backup with restore verification | ✅ |
| Nextcloud / Ghost / LLM stack | ✅ serving |
| Cloudflare + Traefik publishing pattern | ✅ |
| Shutdown guard (docker kill + clean unmount) | ✅ battle-tested |
| wait-for-ceph-mon boot gate (MDS-aware) | ✅ battle-tested |
| Full unattended reboot cycle | ✅ battle-tested 2026-06-13 |
| dropbear-initramfs remote unlock | ❌ not installed |
| Headscale on node 1 (fresh, phase 2) | ❌ planned |
| Traefik migration to node 1 (phase 2) | ❌ planned |
| 3-node Ceph, replication 2–3 (phase 3) | ❌ planned |
| Cloudflare exit (phase 4, §8) | ❌ planned |
| Remaining service migrations (Vaultwarden, Nostr, Mattermost, HA) | ❌ planned |

**The bar for flipping ⚠️→✅: one full unattended reboot cycle** — shutdown
completes alone, LUKS auto-unlocks, CephFS auto-mounts, Docker auto-starts,
all services serve, zero manual touches. Then commit.
