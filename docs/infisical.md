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

**Scope: web UI login only.** Everything in this section configures how a *human* signs in to the Infisical web UI at `https://infisical.yourdomain.com`. It has no effect on the CLI — `make deploy-*` and every Ansible run authenticate with the machine identity described under [CLI Integration](#cli-integration), and never touch Google.

Infisical's free tier supports Google OAuth natively. Since Cloudflare Access already uses Google as its identity provider, the same Google accounts authenticate both layers — users effectively have a single identity across the homelab.

> **`INFISICAL_CLIENT_ID_GOOGLE` is not `INFISICAL_CLIENT_ID`.** The names differ by a suffix and sit near each other in `.env`, but they are unrelated credentials from different issuers:
>
> | | Issued by | Consumed by | Authenticates |
> |---|---|---|---|
> | `INFISICAL_CLIENT_ID` / `_SECRET` | Infisical (machine identity) | Infisical **CLI** | this repo → Infisical |
> | `INFISICAL_CLIENT_ID_GOOGLE` / `_SECRET_GOOGLE` | Google Cloud Console (OAuth app) | Infisical **server** | a human → Infisical web UI |
>
> See [configuration.md](configuration.md#google-sign-in-for-the-infisical-web-ui) for the full breakdown.

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

# Google Cloud OAuth app from step 1 — read by the Infisical SERVER to render
# the "Sign in with Google" button on the web UI login page.
INFISICAL_CLIENT_ID_GOOGLE=<client-id>
INFISICAL_CLIENT_SECRET_GOOGLE=<client-secret>
```

These are bootstrap values: `make deploy-infisical` renders `infisical.env` before Infisical is reachable, so they must exist in `.env` even after you also store them in the project (step 3).

What Ansible does with them:

| `.env` | Ansible var ([vars.yml](../ansible/group_vars/all/vars.yml)) | Rendered into `infisical.env` |
|---|---|---|
| `INFISICAL_CLIENT_ID_GOOGLE` | `vault_infisical_client_id_google` | `CLIENT_ID_GOOGLE_LOGIN` |
| `INFISICAL_CLIENT_SECRET_GOOGLE` | `vault_infisical_client_secret_google` | `CLIENT_SECRET_GOOGLE_LOGIN` |

`CLIENT_ID_GOOGLE_LOGIN` / `CLIENT_SECRET_GOOGLE_LOGIN` are Infisical's own upstream variable names. The block in [`infisical.env.j2`](../ansible/roles/infisical/templates/infisical.env.j2) is guarded by `{% if vault_infisical_client_id_google %}`, so leaving both blank omits Google sign-in cleanly — the UI falls back to email/password only.

> **Keep the redirect URI and `SITE_URL` in sync.** `SITE_URL` resolves to `INFISICAL_EXTERNAL_URL` when set, otherwise `INFISICAL_SITE_URL`, and Infisical derives its callback from it as `<SITE_URL>/api/v1/sso/google`. Changing which URL is in play without updating the authorized redirect URI in Google Cloud Console breaks sign-in with a `redirect_uri_mismatch`.

> **SMTP must be configured** — Infisical requires it when Google OAuth is enabled.

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
make redeploy-infisical
```

**5. Cloudflare Tunnel** (if exposing Infisical externally)

In Cloudflare Tunnel config add a public hostname:
- Hostname: `infisical.yourdomain.com`
- Service: `http://127.0.0.1:8080`

Create a Cloudflare Access application protecting `infisical.yourdomain.com` with the same email policy as your other services. This ensures only whitelisted Google accounts can reach the Infisical login page at all.

> This hostname is for **browsers only**. Do not point `INFISICAL_API_URL` at it — the CLI must keep using the LAN address, and no Access service-token exception is configured for it. See [`INFISICAL_API_URL` must be the LAN address](#infisical_api_url-must-be-the-lan-address).

### User experience

1. User navigates to `https://infisical.yourdomain.com`
2. Cloudflare Access validates their Google session (or prompts Google login once)
3. Infisical login page shows **Sign in with Google** button
4. Since the browser already has a Google session, clicking the button completes instantly — no password entry

---

## CLI Integration

The Makefile wraps all `ansible-playbook` calls with `infisical run --`, which injects secrets as environment variables before Ansible starts. No Ansible changes were needed — the existing `lookup('env', ...)` calls in `group_vars/all/vars.yml` work unchanged.

### Auth model — why the Makefile logs in explicitly

The CLI does **not** read `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`. The only credential env var `run` and `export` honour is `INFISICAL_TOKEN`. Given neither, they fall back to whatever interactive `infisical login` session the operator happens to have — and a user account that is not a member of the project gets an **empty secret set with exit 0**, no error. That silently deploys blank credentials.

So the Makefile exchanges the machine identity's credentials for a token first, then hands it over via `INFISICAL_TOKEN`:

```make
INFISICAL_UNIVERSAL_AUTH_CLIENT_ID     = $(INFISICAL_CLIENT_ID)
INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET = $(INFISICAL_CLIENT_SECRET)

INFISICAL_LOGIN    = infisical login --method=universal-auth \
                       --domain=$(INFISICAL_API_URL) --plain --silent
INFISICAL_TOKEN_SH = _t=$$($(INFISICAL_LOGIN)) && test -n "$$_t" || { ...abort... }
```

The credentials travel via the CLI's own env vars rather than `--client-id` / `--client-secret` flags, keeping the secret out of `ps` output and out of the recipe line make echoes.

Under token auth a missing project grant becomes a loud `403 You are not a member of this project with ID …` instead of silence. The `_infisical-check` prerequisite on every deploy target covers the remaining case (authorised, but the environment is empty) by aborting when the export yields zero keys:

```
[infisical] 27 secrets available          # pass
[infisical] 0 secrets in prod — assign the machine identity to the project, then retry
```

### `INFISICAL_API_URL` must be the LAN address

**Set `INFISICAL_API_URL` to the LAN address (`http://<siem-host>:8080`), never the Cloudflare Tunnel hostname.**

The tunnel hostname sits behind Cloudflare Access, which answers unauthenticated API calls with a `302` to the Google login page. The CLI treats that redirect as "no secrets" rather than an error — the same silent-empty failure mode `_infisical-check` exists to catch. Point `INFISICAL_API_URL` at the tunnel and every deploy either aborts on the guard or, if the guard is bypassed, renders blank credentials.

#### Why not use `INFISICAL_CUSTOM_HEADERS` (deliberate decision)

There **is** a supported way to make the CLI work through Cloudflare Access. Access supports Service Auth policies with service tokens, and the Infisical CLI can attach arbitrary headers via the `INFISICAL_CUSTOM_HEADERS` environment variable:

```bash
# Supported by the CLI — space-separated Name=Value pairs. We do NOT use this.
export INFISICAL_CUSTOM_HEADERS="CF-Access-Client-Id=<id> CF-Access-Client-Secret=<secret>"
```

This works, and Infisical documents Cloudflare Access as its motivating use case. **We deliberately do not use it.** The reasons:

- **It collapses the layer it appears to add.** `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` would have to live in `.env` — the service token is needed to *reach* Infisical, so it cannot be stored in Infisical. That puts it in the same file, on the same host, at the same trust level as `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`. Any compromise yielding one yields both, so against the likeliest threat — a stolen `.env` or a compromised workstation — two layers behave as one.
- **The added credential is broader than the one it guards.** The Infisical machine identity is scoped to a single project with Reader. A Cloudflare Access service token is an account-level credential whose reach depends entirely on policy hygiene; one careless `Any Access Service Token` include on another application (Grafana, the Wazuh dashboard) extends it further than the Infisical identity could ever go. Adding it to `.env` raises that file's value by more than one application's worth.
- **It solves a problem we do not have.** The only consumer of the Infisical API is an operator at a keyboard. CI never deploys — [`ci.yml`](../.github/workflows/ci.yml) only lints, syntax-checks, and renders templates against mock vars, and holds no real secret. A service token is the right tool for an unattended runner that cannot join the network; there isn't one here.

**For off-LAN deploys, join the LAN rather than exposing the API.** Cloudflare WARP on the same Zero Trust account (or Tailscale) puts you on the LAN after an interactive Google login and device posture check, then the normal LAN path applies unchanged. That factor is genuinely independent of `.env`, and the Infisical API never needs a public hostname at all.

> This constrains the **CLI only**. Exposing the Infisical *web UI* through the tunnel behind Access is unaffected and still recommended — see [Google OAuth](#google-oauth-cloudflare-access-sso).

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
