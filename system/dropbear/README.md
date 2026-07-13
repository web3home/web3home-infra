# Remote LUKS unlock via dropbear-initramfs (bee001)

Lets you unlock the LUKS root over SSH at early boot, instead of typing the
passphrase at the physical console. Unblocks remote reboots.
**Documentation copies — not auto-deployed.** Live config lives under
`/etc/dropbear/initramfs/` and `/etc/initramfs-tools/`.

## SECURITY — what is NEVER committed

- `authorized_keys` — your unlock public key. NOT in this repo (even though
  it's a public key, committing it advertises the unlock setup). Supply your
  own on the host.
- Host keys — irrelevant here anyway; `-R` regenerates them each boot.
- The LUKS passphrase is the real gate. A stolen key alone cannot unlock;
  the SSH key only gets you TO the passphrase prompt.

## Scope

LAN only. dropbear runs in initramfs, before the mesh (Tailscale/Headscale)
exists, so unlock works from the local network, NOT the public internet.
Internet-scope unlock is a separate, security-sensitive decision (tied to the
network-plane migration) — not enabled.

## Install

1. `sudo apt install dropbear-initramfs` (pulls cryptsetup-initramfs, which
   provides `cryptroot-unlock`).
2. Copy `dropbear.conf.example` → `/etc/dropbear/initramfs/dropbear.conf`.
3. Create `/etc/dropbear/initramfs/authorized_keys` (chmod 600) with your
   UNLOCK public key, prefixed with forced-command hardening:
       no-port-forwarding,no-agent-forwarding,no-x11-forwarding,command="cryptroot-unlock" ssh-ed25519 AAAA... unlock-<host>
   Generate the key on the CLIENT you unlock from (not on the encrypted box):
       ssh-keygen -t ed25519 -f ~/.ssh/unlock_<host> -N ""
4. Append the `IP=` line (see `initramfs-ip.example`) to
   `/etc/initramfs-tools/initramfs.conf`; add `r8169` to
   `/etc/initramfs-tools/modules`. Replace placeholders with real LAN values.
5. `sudo update-initramfs -u -k all` (all kernels — GRUB fallback safety).
6. VERIFY before rebooting: confirm dropbear, your key, and the static IP are
   in the booting image:
       sudo unmkinitramfs /boot/initrd.img-$(uname -r) /tmp/ird
       sudo grep -r 'unlock-<host>' /tmp/ird ; sudo rm -rf /tmp/ird
7. Reboot AT THE CONSOLE the first time (fallback if dropbear fails to come
   up). Test from client:
       ssh -p 2222 -i ~/.ssh/unlock_<host> root@<lan-ip>
   Accept the host-key prompt (new each boot due to -R); it auto-runs
   cryptroot-unlock → enter LUKS passphrase → box continues booting.

## Client convenience (~/.ssh/config)

    Host unlock-<host>
        Hostname <lan-ip>
        Port 2222
        User root
        IdentityFile ~/.ssh/unlock_<host>
        RequestTTY yes
        RemoteCommand cryptroot-unlock

Then: `ssh unlock-<host>` → passphrase → done.

## Prerequisites / gotchas

- NIC driver + firmware MUST be in initramfs (verify with lsinitramfs). For
  Realtek r8169, the rtl_nic firmware ships via MODULES=most; confirm.
- No `splash` in GRUB_CMDLINE, or it can hide the console fallback prompt.
- Handles the passphrase-prompted root only; keyfile-unlocked devices (e.g.
  the Ceph OSD) auto-unlock once root is up.
