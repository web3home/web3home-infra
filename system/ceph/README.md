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
   the key from `secretfile=/etc/ceph/admin.secret` (created out-of-band,
   never committed).
4. `sudo systemctl daemon-reload`
5. `sudo systemctl enable --now srv-dm-ceph.mount`

The Docker drop-in (`RequiresMountsFor` + `After`) ensures containers never
start against an empty mountpoint — without it, an unmounted CephFS lets
Nextcloud bootstrap a blank install over the real data path. See JOURNAL
entry 2026-06-01 for the incident this prevents.
