# Journal entries

Order: oldest at the bottom, newest at the top.

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
