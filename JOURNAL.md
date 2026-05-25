# Suggested first journal entries

Paste these into `JOURNAL.md` at the repo root (create the file if it doesn't exist yet). Order them oldest at the bottom, newest at the top.

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
