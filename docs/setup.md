# Setup

## Prerequisites

- Ansible ≥ 2.15
- `community.docker` collection:
  ```bash
  make install-deps
  ```
- Passwordless sudo for your user on the SIEM server
- Docker installed on the SIEM server (handled by the `docker` role)

---

## Installation

Secrets live in Infisical, so a first install is two passes: bring Infisical up from
`.env` alone, then populate it and deploy everything else.

```bash
# 1. Clone
git clone https://github.com/khirata/homelab && cd homelab

# 2. Configure — .env only needs the bootstrap + connection values
cp .env.example .env
$EDITOR .env          # fill in IPs, SSH users, bootstrap secrets

# 3. Install Ansible dependencies
make install-deps

# 4. Bootstrap Infisical (reads .env directly — Infisical not running yet)
make deploy-infisical
```

Now follow [infisical.md → First Run](infisical.md#first-run): create the admin account,
the project, and the `prod` environment; add the application secrets listed under
"In Infisical" in [configuration.md](configuration.md); then create a machine identity and
put its `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` and the project ID into `.env`.

```bash
# 5. Confirm the machine identity can read secrets
make env | head    # prints values — run privately

# 6. Dry-run, then deploy the rest
make check
make deploy
```

If `make check` aborts with `[infisical] 0 secrets in prod`, the machine identity is not
assigned to the project — fix the grant in the UI rather than putting the secrets back
into `.env`.

---

## Upgrading

Edit version variables in `ansible/group_vars/all/vars.yml` then re-run:

```bash
make deploy
```

For Infisical-specific upgrade steps (database migrations), see [infisical.md](infisical.md#upgrading).
