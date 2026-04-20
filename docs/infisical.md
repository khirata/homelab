# Infisical

Self-hosted secret management. Runs as a Docker Compose stack backed by the shared native PostgreSQL and Redis instances.

**URL:** `http://<siem-host>:8080`

---

## First Run

After the initial deploy, create the admin account via the web UI:

1. Open `http://<siem-host>:8080` in a browser
2. Click **Sign up** and register the first admin user
3. Create an organization and project
4. Add secrets via the UI or Infisical CLI (`infisical secrets set`)

---

## Upgrading

Bump `infisical_version` in `ansible/group_vars/all/vars.yml`, then:

```bash
# 1. Snapshot the database first
make backup

# 2. Deploy (pulls new image, runs db-migration, restarts)
make deploy
```

If migration fails, restore from the pre-upgrade snapshot:

```bash
# List available snapshots
ls /opt/siem/backups/postgresql/

# Restore (run on siem-host as root)
sudo -u postgres pg_restore -d infisical -c \
  /opt/siem/backups/postgresql/<timestamp>_infisical.pgdump
```

---

## Operations

```bash
ssh <user>@<siem-host>

# Status
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml ps

# Logs (live)
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml logs -f infisical
```

---

## Key Secrets

| Variable | Purpose |
|---|---|
| `INFISICAL_ENCRYPTION_KEY` | At-rest secret encryption (64-char hex) — **back up securely** |
| `INFISICAL_AUTH_SECRET` | JWT signing |
| `INFISICAL_SITE_URL` | Cookie/CORS origin (e.g. `http://10.x.x.x:8080`) |

> If `INFISICAL_ENCRYPTION_KEY` changes, all stored secrets become unrecoverable.

See [configuration.md](configuration.md) for the full secrets reference.
