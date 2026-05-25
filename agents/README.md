# agents/

LLM agent prompts used to guide the web3home-infra buildout.

## What this is

Each `*.md` file in this directory is a self-contained system prompt for a specific agent role. The prompts are version-controlled, reviewed via PRs, and scanned by gitleaks like any other code in this repo. Major prompt changes ship as `feat(agent):` commits with rationale in the body.

No application, no server, no API key in this directory. The "agent" is the prompt. The runtime is whatever LLM the operator chooses.

## How to use a prompt

**Option A — paste into a hosted LLM**
1. Open Claude, ChatGPT, or any LLM with web search
2. Paste the entire **System prompt** section of the chosen `.md` file
3. Begin the conversation

**Option B — load into Open WebUI (self-hosted)**
1. In Open WebUI, create a new Model
2. Set the system prompt to the contents of the chosen `.md` file
3. Attach a backend (Ollama for local-only, or an API provider)
4. Use the Model as a persistent chat

**Option C — feed into Claude Code or other CLI agents**
1. Reference the file path with whatever flag the tool expects (`--system-prompt`, `CLAUDE.md`, etc.)
2. Run as normal

## Current agents

| File | Purpose | Status |
|---|---|---|
| [`microceph-agent.md`](microceph-agent.md) | MicroCeph cluster buildout + Odroid M1 migration + Sovereignty Grid alignment | v1.0 |

## Versioning

Agents follow semver-ish in their changelog at the bottom of each file:
- **Major** — capability change (new track, dropped scope, architectural pivot)
- **Minor** — new instructions, new principle, expanded coverage
- **Patch** — clarifications, typo fixes, link updates

## Contributing changes

1. Edit the prompt
2. Bump the changelog with date and rationale
3. Commit with `feat(agent): <short description>` or `docs(agent): <short>`
4. Open a PR; the diff itself is the review surface
5. After merge, anyone using this prompt should re-paste / re-import

## Privacy posture

Agent prompts are public. They reference:
- Hardware models (already public)
- City-level location (already on the public white paper)
- The published architectural choices for this repo

They never contain:
- Passphrases, tokens, or any secret values
- Internal IPs, MAC addresses, serial numbers
- Personal names, family member references
- ISP, exact network topology, or device-fingerprinting details

If a prompt requires per-operator values to function (an API key, a domain name, an IP range), those are *parameter placeholders* (e.g. `<YOUR-DOMAIN>`, `<PRIMARY-NODE-IP>`) that the operator fills in locally before pasting.
