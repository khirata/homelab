# Configuration

Every variable reaches Ansible the same way — `lookup('env', ...)` — but they come from
two different places:

| Source | What lives there | Injected by |
|---|---|---|
| **Infisical** (prod env) | Application secrets | `infisical run` in the Makefile |
| **`.env`** (gitignored) | Infisical CLI credentials, bootstrap secrets, connection/config | Make's `-include .env` + `export` |

`.env` is deliberately small: it holds only what Infisical cannot supply — the credentials
needed to reach Infisical, the values `make deploy-infisical` renders *before* Infisical
exists, and config that is not in the project. See [.env.example](../.env.example).

## In `.env` — connection

| Variable | Purpose |
|---|---|
| `SIEM_SERVER_IP` | LAN IP of the SIEM server (becomes `ansible_host`) |
| `SIEM_SERVER_USER` | SSH user on the SIEM server (becomes `ansible_user`) |
| `POSTGRESQL_SERVER_IP` | LAN IP of the PostgreSQL host |
| `POSTGRESQL_SERVER_USER` | SSH user on the PostgreSQL host |
| `REDIS_SERVER_IP` | LAN IP of the Redis host — rendered into Infisical's `REDIS_URL` |

## In `.env` — bootstrap secrets

Consumed by `make deploy-infisical` (docker + postgresql + infisical roles), which runs
without Infisical injection. Duplicates live in Infisical for normal deploys — keep both
in sync when rotating.

| Variable | Used by | Generate with |
|---|---|---|
| `POSTGRESQL_PASSWORD` | PostgreSQL `infisical` user | `openssl rand -base64 16` |
| `REDIS_PASSWORD` | Redis `requirepass` — hex only, `/` and `=` break the `redis://` URL | `openssl rand -hex 32` |
| `INFISICAL_ENCRYPTION_KEY` | Infisical at-rest encryption — exactly 32 chars | `openssl rand -hex 16` |
| `INFISICAL_AUTH_SECRET` | Infisical JWT signing — min 32 chars | `openssl rand -hex 32` |
| `INFISICAL_SITE_URL` | Infisical cookie/CORS origin (e.g. `http://10.x.x.x:8080`) | — |
| `INFISICAL_EXTERNAL_URL` | Public CF Tunnel URL (optional) — overrides `SITE_URL` | — |
| `INFISICAL_CLIENT_ID_GOOGLE` / `_SECRET_GOOGLE` | Google OAuth sign-in (optional) | Google Cloud Console |

> **CRITICAL — `INFISICAL_ENCRYPTION_KEY`**: This key encrypts all secrets stored in Infisical.
> If it changes, all stored secrets become unrecoverable. Never store it in Infisical itself.
> Back up your `.env` file securely.

## In `.env` — config not stored in Infisical

Not secret, but absent from the Infisical project, so a deploy run without `.env` renders
them empty rather than failing.

| Variable | Purpose |
|---|---|
| `GRAFANA_EXTERNAL_URL` | Public URL Grafana embeds in alert links |
| `CLOUDFLARE_TEAM_NAME` | Cloudflare Access team — enables Grafana JWT auth when set |
| `NTFY_TOPIC` | ntfy topic on the self-hosted server (defaults to `homelab`) |
| `UNIFI_CONTROLLER_URL_SITE1` / `_SITE2` | Unifi controller URLs (443 on UDM, 8443 on CloudKey) |

## In Infisical (prod environment)

**Source of truth: [`infisical-secrets.template.env`](../infisical-secrets.template.env).**
Every Infisical-managed key, with its length/character requirements and the command that
generates it, lives in that file — not duplicated here, so the two cannot drift.

It is a real file in two senses:

- `make _infisical-check`, a prerequisite of every deploy target, fails when Infisical is
  missing any key the template marks required. A key renamed in the UI is caught before
  Ansible renders a blank credential.
- `infisical secrets set --file` imports it, so a fresh project is populated in one pass.

Uncommented `KEY=` entries are required; `# KEY=` entries are documented but never enforced.

### Populating a fresh project

```bash
cp infisical-secrets.template.env /tmp/secrets.env
$EDITOR /tmp/secrets.env                    # fill in values
infisical secrets set --file /tmp/secrets.env \
  --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
shred -u /tmp/secrets.env
```

> **`secrets set --file` is an upsert.** Pointing it at the committed template — or any
> copy with blank values — overwrites every listed secret with an empty string, and
> `_infisical-check` still passes because the keys exist. Only pass it a filled-in copy
> kept outside the repo.

### Inspecting what is actually stored

```bash
make env                                    # prints values — run privately

# Key names and comments only, no values — regenerates the template's shape
infisical secrets generate-example-env \
  --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
```

`generate-example-env` emits each secret's Infisical **comment** above its key. Populating
those comments in the UI makes this command reproduce the template automatically; they are
currently empty, so it prints bare keys.

---

## Prometheus Scrape Targets

Edit `ansible/group_vars/siem_server/vars.yml` and add node IPs to
`prometheus_scrape_targets`, then run `make deploy`.

> Use IP addresses — Go's DNS resolver can't resolve `.local` mDNS names.

---

## Data Locations

| Service | Path on siem-host |
|---|---|
| Grafana data | `/opt/siem/data/grafana` |
| Loki chunks | `/opt/siem/data/loki` |
| Prometheus TSDB | `/opt/siem/data/prometheus` |
| Compose + all configs | `/opt/siem/config/` |
| Wazuh logs/rules/agents | `/var/ossec/` |
| Alloy config | `/etc/alloy/config.alloy` |
| PostgreSQL data | `/var/lib/postgresql/16/main/` |
| Redis data | `/opt/siem/data/redis/` |
| PostgreSQL backups | `/opt/siem/backups/postgresql/` |
