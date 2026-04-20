# Configuration

## Secrets

Sourced from `.env` at deploy time via `lookup('env', ...)` — never committed.

| Variable | Used by |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login |
| `WAZUH_API_PASSWORD` | Wazuh REST API (`wazuh` user) |
| `POSTGRESQL_PASSWORD` | PostgreSQL `infisical` user |
| `REDIS_PASSWORD` | Redis `requirepass` (binds to 0.0.0.0 for Docker access) |
| `INFISICAL_ENCRYPTION_KEY` | Infisical at-rest secret encryption (64-char hex) |
| `INFISICAL_AUTH_SECRET` | Infisical JWT signing |
| `INFISICAL_SITE_URL` | Infisical cookie/CORS origin (e.g. `http://10.x.x.x:8080`) |

> **CRITICAL — `INFISICAL_ENCRYPTION_KEY`**: This key encrypts all secrets stored in Infisical.
> If it changes, all stored secrets become unrecoverable. Back up your `.env` file securely.

---

## Unifi Syslog

Point your Unifi controller at the SIEM server:
**Settings → System → Logging → Remote Syslog → `<SIEM_SERVER_IP>:514` UDP**

Logs appear in Grafana → Explore → Loki → `{job="unifi"}`.

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
