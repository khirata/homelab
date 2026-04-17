# homelab

Home lab infrastructure — SIEM server running Wazuh Manager + Grafana LGTM stack
on a Raspberry Pi 5 (laf3).

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

---

## Prerequisites

- Ansible ≥ 2.15
- `community.docker` collection:
  ```bash
  make install-deps
  ```
- Passwordless sudo for your user on the SIEM server
- Docker installed on the SIEM server (handled by the `docker` role)

---

## Setup

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

---

## Unifi Syslog

Point your Unifi controller at the SIEM server for syslog:
**Settings → System → Logging → Remote Syslog → `<SIEM_SERVER_IP>:514` UDP**

Logs appear in Grafana → Explore → Loki → `{job="unifi"}`.

---

## Adding Prometheus Scrape Targets

Edit `ansible/group_vars/siem_server/vars.yml` and add node IPs to
`prometheus_scrape_targets`, then run `make deploy`.

> Use IP addresses — Go's DNS resolver can't resolve `.local` mDNS names.
