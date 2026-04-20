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

```bash
# 1. Clone
git clone https://github.com/khirata/homelab && cd homelab

# 2. Configure
cp .env.example .env
$EDITOR .env          # fill in IPs, hostnames, passwords

# 3. Install Ansible dependencies
make install-deps

# 4. Dry-run first
make check

# 5. Deploy
make deploy
```

---

## Upgrading

Edit version variables in `ansible/group_vars/all/vars.yml` then re-run:

```bash
make deploy
```

For Infisical-specific upgrade steps (database migrations), see [infisical.md](infisical.md#upgrading).
