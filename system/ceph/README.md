# CephFS persistent mount (bee001)

Reference copies of the units that make `/srv/dm/ceph` (Nextcloud data on
MicroCeph CephFS) mount at boot, before Docker starts its containers.

**These are documentation copies — not auto-deployed.** The live versions
live under `/etc/systemd/system/`. To install on a host:

1. Copy `srv-dm-ceph.mount` → `/etc/systemd/system/srv-dm-ceph.mount`
   (filename MUST match the mount path: `/srv/dm/ceph` → `srv-dm-ceph.mount`).
2. Copy `docker-wait-cephfs.conf` → `/etc/systemd/system/docker.service.d/10-wait-cephfs.conf`.
3. **Replace placeholder IPs with real values**: `mon_addr=192.168.1.10`
   is a placeholder — set the real Ceph monitor address. The mount reads
   the key from `secretfile=/etc/ceph/nextcloud.secret` (created out-of-band,
   never committed).
4. `sudo systemctl daemon-reload`
5. `sudo systemctl enable --now srv-dm-ceph.mount`

The Docker drop-in (`RequiresMountsFor` + `After`) ensures containers never
start against an empty mountpoint — without it, an unmounted CephFS lets
Nextcloud bootstrap a blank install over the real data path. See JOURNAL
entry 2026-06-01 for the incident this prevents.

## Unclean-shutdown recovery: mount retry

`cephfs-mount-retry.service` + `cephfs-mount-retry.sh` + `20-retry-on-failure.conf`.

### The failure this fixes

After a **power loss** (not a clean reboot), `wait-for-ceph-mon` can see the MDS
report `up:active` while the FS is still not mountable — the OSD is coming up and
PGs are peering. The mount then fails with `no mds (Metadata Server) is up`, and:

- `srv-dm-ceph.mount` fails **once** — systemd has no native mount retry.
- `docker` and `web3home-stacks` die as **dependency** failures → `inactive (dead)`,
  not `failed`, so they never retry and no `OnFailure=` of their own can fire.

Real incident (2026-07-10): services were down **8 hours**. Recovery was accidental
— `restic-backup.timer` fired overnight and its `RequiresMountsFor=/srv/dm/ceph`
re-triggered the mount, by which time Ceph had long stabilised.

### The fix

`OnFailure=` on the **mount** (which does fail properly) → a retry helper that
polls/retries the mount for ~20 min, and on success **explicitly starts
`docker.service` and `web3home-stacks.service`** — deliberate recovery instead of
an accidental side effect. Bails immediately if a shutdown is in progress
(same lesson as `cephfs-shutdown-guard`).

Prediction was rejected as the primary fix: no status string reliably predicts
mountability (`ceph -s` health is unusable here — HEALTH_OK is only achieved via
muted `POOL_NO_REDUNDANCY` warnings on this single-OSD node). Retry is the
guarantee; the gate is an optimisation.

### Install

1. Copy `cephfs-mount-retry.sh` → `/opt/web3home/bin/`, `chmod 755`.
2. Copy `cephfs-mount-retry.service` → `/etc/systemd/system/`.
3. Copy `20-retry-on-failure.conf` → `/etc/systemd/system/srv-dm-ceph.mount.d/`.
4. `sudo systemctl daemon-reload` && `systemd-analyze verify default.target`.

No `enable` needed — it is triggered by `OnFailure=`, not by a target.

### Verified (2026-07-15)

Failure injection, no power cut needed: `snap stop microceph.mds` reproduces the
exact `no mds is up` error while mon+OSD stay up. Mount failed → OnFailure fired →
retry looped → `snap start microceph.mds` → mounted on attempt 4 → docker and
web3home-stacks started automatically → all containers back. Zero manual steps.
Also survived a normal clean reboot (drop-in does not disturb the happy path).
