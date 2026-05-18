# Infisical

Self-hosted secret management. Runs as a Docker Compose stack backed by the shared native PostgreSQL and Redis instances.

**URL:** `http://<siem-host>:8080`

---

## First Run

After the initial deploy, create the admin account and populate secrets:

1. Open `http://<siem-host>:8080` in a browser
2. Click **Sign up** and register the first admin user
3. Create an organization and a project named **homelab**
4. Create an environment named **prod** (or use the default)
5. Add all secrets from `.env` into Infisical (exact env var names, exact values) — see [configuration.md](configuration.md) for the full list
6. Create a machine identity for the CLI (**Settings → Machine Identities → Create**, Universal Auth, Reader role on the homelab project)
7. Copy the `CLIENT_ID` and `CLIENT_SECRET` into `.env` as `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`
8. Set `INFISICAL_PROJECT_ID` in `.env` to the project ID shown in Infisical UI (Settings → Project)

> Do NOT add `INFISICAL_ENCRYPTION_KEY` or `INFISICAL_AUTH_SECRET` to the Infisical project — those are the secrets Infisical itself needs to boot and must stay in `.env`.

---

## Google OAuth (Cloudflare Access SSO)

Infisical's free tier supports Google OAuth natively. Since Cloudflare Access already uses Google as its identity provider, the same Google accounts authenticate both layers — users effectively have a single identity across the homelab.

### Why not JWT proxy (like Grafana)?

Infisical has no header-based proxy-auth mode, so the Grafana-style `Cf-Access-Jwt-Assertion` approach cannot be wired directly. Google OAuth is the equivalent for the community edition. (OIDC SSO — true one-click login — requires Infisical Pro.)

### Setup

**1. Create a Google OAuth app**

Go to `console.cloud.google.com` → **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth 2.0 Client ID**:

- Application type: **Web application**
- Authorized redirect URI: `https://infisical.yourdomain.com/api/v1/sso/google`
  (or `http://<siem-host>:8080/api/v1/sso/google` for LAN-only access; add both if needed)

Copy the **Client ID** and **Client Secret**.

**2. Configure `.env`**

```bash
# Public CF Tunnel URL — sets SITE_URL so OAuth redirects resolve correctly
INFISICAL_EXTERNAL_URL=https://infisical.yourdomain.com

# Google OAuth credentials
INFISICAL_CLIENT_ID_GOOGLE=<client-id>
INFISICAL_CLIENT_SECRET_GOOGLE=<client-secret>
```

> SMTP must be configured — Infisical requires it when Google OAuth is enabled.

**3. Add secrets to Infisical project**

Add the new credentials to the Infisical **prod** environment so future deploys inject them:

```bash
infisical secrets set INFISICAL_EXTERNAL_URL=https://infisical.yourdomain.com \
  --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
infisical secrets set INFISICAL_CLIENT_ID_GOOGLE=<id> \
  --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
infisical secrets set INFISICAL_CLIENT_SECRET_GOOGLE=<secret> \
  --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
```

**4. Re-deploy Infisical**

```bash
make deploy-infisical
```

**5. Cloudflare Tunnel** (if exposing Infisical externally)

In Cloudflare Tunnel config add a public hostname:
- Hostname: `infisical.yourdomain.com`
- Service: `http://127.0.0.1:8080`

Create a Cloudflare Access application protecting `infisical.yourdomain.com` with the same email policy as your other services. This ensures only whitelisted Google accounts can reach the Infisical login page at all.

### User experience

1. User navigates to `https://infisical.yourdomain.com`
2. Cloudflare Access validates their Google session (or prompts Google login once)
3. Infisical login page shows **Sign in with Google** button
4. Since the browser already has a Google session, clicking the button completes instantly — no password entry

---

## CLI Integration

The Makefile wraps all `ansible-playbook` calls with `infisical run --`, which injects secrets as environment variables before Ansible starts. No Ansible changes were needed — the existing `lookup('env', ...)` calls in `group_vars/all/vars.yml` work unchanged.

### Normal deploy (secrets from Infisical)

```bash
make deploy-siem       # infisical run -- ansible-playbook ...
make deploy-dashboards
make check             # dry-run
```

### Re-deploy Infisical itself

```bash
make deploy-infisical    # bootstrap: reads secrets from .env (Infisical not yet running)
make redeploy-infisical  # update: injects secrets via infisical run (Infisical already running)
```

### Ad-hoc: run ansible-playbook directly with Infisical secrets

```bash
# Safer: secrets never printed to stdout
infisical run --projectId $INFISICAL_PROJECT_ID --env prod \
  --domain $INFISICAL_API_URL -- \
  ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml

# Convenience: load secrets into current shell (secrets visible in terminal scroll-back)
eval $(make env)
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml --limit siem_server
```

### Inspect / rotate secrets

```bash
# List all secrets
infisical secrets list --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL

# Set a secret
infisical secrets set MY_SECRET=newvalue --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL

# Delete a secret
infisical secrets delete MY_SECRET --projectId $INFISICAL_PROJECT_ID --env prod --domain $INFISICAL_API_URL
```

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
