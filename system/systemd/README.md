# Docker stack auto-start after reboot (bee001)

Reference copies of the unit + script that bring up boot-enabled Docker
Compose stacks after a reboot, once CephFS is mounted and Docker is up.
**These are documentation copies — not auto-deployed.** Live versions:
`/etc/systemd/system/web3home-stacks.service` and
`/opt/web3home/bin/compose-boot-up.sh`.

## Why this exists

`cephfs-shutdown-guard` runs `docker kill` on every container at shutdown.
`docker kill` sets each container's desired-state to "stopped", so the
`restart: unless-stopped` policy intentionally does NOT auto-restart them on
the next boot — containers stay down until an explicit `compose up`. This unit
performs that explicit bring-up at boot. `unless-stopped` still handles
crash-restart while the node is running.

Discovered after a reboot where every container stayed down for ~4h until a
manual `compose up`. See JOURNAL entry for the root-cause analysis.

## Install

1. Copy `web3home-stacks.service` → `/etc/systemd/system/web3home-stacks.service`.
2. Copy `compose-boot-up.sh` → `/opt/web3home/bin/compose-boot-up.sh`, `chmod 755`.
   (Paths and user `dm` are real, not placeholders — adjust if your layout differs.)
3. `sudo systemctl daemon-reload`
4. `sudo systemctl enable web3home-stacks.service`

## Adding a stack to the boot set

The script scans `docker/*/compose.yaml` and brings up a stack ONLY if its
directory contains a `.boot-enabled` marker (opt-in, so half-built stacks don't
auto-start). To enrol a service:

    touch docker/<service>/.boot-enabled

Markers are committed to the repo so the boot set is reproducible from a clone.

## Design notes

- No `ExecStop`: `cephfs-shutdown-guard` owns shutdown teardown. A second
  teardown here would race it.
- `RequiresMountsFor=/srv/dm/ceph` + `After=docker.service` gate the bring-up
  behind both the mount and the daemon.
- `Type=oneshot` + `RemainAfterExit=yes`: runs once at boot, shows
  `active (exited)` on success.
- Idempotent: `compose up -d` is a no-op for already-running, unchanged stacks.
