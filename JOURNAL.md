# Suggested first journal entries

Paste these into `JOURNAL.md` at the repo root (create the file if it doesn't exist yet). Order them oldest at the bottom, newest at the top.

---

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
