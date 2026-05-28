# Ghost CMS

Public blog for `web3home.info`.

## Architecture

- **Image**: `ghost:5-alpine`
- **Storage**: local path `/srv/dm/services/ghost/content/` on bee001
- **Database**: SQLite, bundled (lives inside content directory)
- **Mail**: Migadu SMTP, credentials via `.env`
- **TLS**: handled by upstream Traefik (currently on Odroid, eventually on bee001)
- **External access**: Cloudflare proxy → home IP → Traefik → this container

## Local setup

1. Create the local content directory:

       sudo mkdir -p /srv/dm/services/ghost/content
       sudo chown -R $USER:$USER /srv/dm/services/ghost

2. Populate `.env` from `.env.example` with real Migadu SMTP credentials.

3. Bring it up:

       docker compose up -d

4. Verify:

       docker compose logs -f ghost

## Migration history

Originally deployed on Odroid M1 (ARM64), migrated to bee001 (x86_64) as Phase 3 step 1. See `JOURNAL.md` entries dated 2026-05-27 onward.
