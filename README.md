# homelab

Home lab infrastructure — SIEM server running Wazuh Manager + Grafana LGTM stack
on a Raspberry Pi 5.

Node-level agents (Wazuh Agent, Grafana Alloy node mode) are managed separately
in [dotconfig](https://github.com/khirata/dotconfig) as part of base node setup.

---

## Stack

| Service | Role | Port |
|---|---|---|
| Grafana | Dashboards & alerting | 3000 |
| Loki | Log aggregation | 3100 (internal) |
| Prometheus | Metrics collection | 9090 (internal) |
| Wazuh Manager | SIEM / security events | 1514, 1515, 55000 |
| Grafana Alloy | Syslog receiver + node metrics | 12345, UDP/514 |
| Infisical | Secret management | 8080 |
| PostgreSQL | Shared database (Infisical) | 5432 (localhost only) |
| Redis | Shared cache (Infisical) | 6379 (localhost only) |

---

## Quick Start

```bash
cp .env.example .env && $EDITOR .env   # fill in IPs, hostnames, passwords
make install-deps
make check                             # dry-run
make deploy
```

See [docs/setup.md](docs/setup.md) for full prerequisites and upgrade instructions.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/setup.md](docs/setup.md) | Prerequisites, installation, upgrading |
| [docs/architecture.md](docs/architecture.md) | System diagram, log flows, port summary |
| [docs/configuration.md](docs/configuration.md) | Secrets reference, data locations, Prometheus targets |
| [docs/lgtm.md](docs/lgtm.md) | Grafana, Loki, Prometheus |
| [docs/wazuh.md](docs/wazuh.md) | Wazuh Manager |
| [docs/alloy.md](docs/alloy.md) | Grafana Alloy, Unifi syslog, RPi metrics |
| [docs/infisical.md](docs/infisical.md) | Infisical first run, upgrading, secrets |
| [docs/postgresql.md](docs/postgresql.md) | PostgreSQL operations, backup, restore |
| [docs/redis.md](docs/redis.md) | Redis operations |
| [docs/operations.md](docs/operations.md) | General ops, log locations, verification, SSH tunnels |
