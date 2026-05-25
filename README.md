# web3home-infra

> Infrastructure for the **Sovereignty Grid**.
> Companion repository to [web3home.info](https://web3home.info).

![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue) ![Status: WIP](https://img.shields.io/badge/status-WIP-orange)

A reproducible, encrypted, self-hosted homelab. Storage, identity, messaging, and compute on hardware the operator owns, with keys the operator holds. See the [white paper](https://web3home.info/whitepaper/) for context.

## Principles

- **Self-custody** — keys and data on operator hardware
- **Encryption by default** — LUKS2 at rest, TLS in transit
- **FOSS-first** — fully FOSS service layer; firmware and gaming partition out of scope
- **Auditable** — every config in git, secrets scanned, commands reproducible
- **Resilience** — replicated storage, documented recovery

## Scope of sovereignty

The service and storage layer is FOSS end-to-end (MicroCeph, Docker, Nextcloud, Vaultwarden, Ghost, Mattermost, Ollama, Traefik, [Headscale](https://github.com/juanfont/headscale)). Firmware blobs (BIOS, GPU microcode) and the gaming partition (Steam, Proton, proprietary titles) are explicitly outside the sovereignty boundary. Operational details that constitute attack surface — remote-access mechanisms, exact network topology, key procedures — live in a private operations journal, not in this repository.

## Architecture

```mermaid
graph TB
    subgraph cluster["MicroCeph cluster (3x replicated)"]
        N1["Beelink GTR9 Pro<br/>x86_64 · primary"]
        N2["Odroid M1<br/>ARM64 · secondary"]
        N3["Raspberry Pi 4<br/>ARM64 · tertiary"]
    end
    subgraph services["Service layer"]
        S["Traefik · Nextcloud · Vaultwarden<br/>Ghost · Mattermost · Ollama · Headscale"]
    end
    services -->|RBD / CephFS| cluster
```

Inter-node traffic runs over a self-hosted Headscale overlay. All on-disk storage is LUKS2-encrypted.

## Layout

```
web3home-infra/
├── JOURNAL.md          Operations journal
├── system/             OS install, partitions, LUKS, BIOS
├── ceph/               MicroCeph scripts, OSD configs
├── docker/             Compose files (secrets-free)
├── migration/          Migration scripts
├── .github/workflows/  CI: shellcheck, compose lint, gitleaks
├── .gitignore
├── .env.example
└── README.md
```

## Status

- [ ] Phase 0 — Repo scaffolding, secrets toolchain (sops + age)
- [ ] Phase 1 — Primary node: Ubuntu 24.04 LTS, LUKS2, partition layout
- [ ] Phase 2 — MicroCeph bootstrap, first OSD
- [ ] Phase 3 — Service migration from legacy node, cutover
- [ ] Phase 4 — Secondary node join, three-node replication
- [ ] Phase 5 — Backup automation, monitoring
- [ ] Phase 6 — Documentation hardening, reproducibility tests

Progress is published weekly on the [development journal](https://web3home.info/development/).

## Security and privacy

Secrets managed via [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age); only encrypted forms are committed. Every push is scanned by [gitleaks](https://github.com/gitleaks/gitleaks). Configs ship with generic placeholders (`example.com`, `192.168.1.x`). Report suspected exposures via GitHub Security Advisories on this repository.

## License

[GNU General Public License v3.0](LICENSE).

## Contact

[web3home.info/contact](https://web3home.info/contact/).
