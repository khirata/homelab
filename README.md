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

---

## SIEM

### Architecture

```
                        ┌──────────────────────────────────────────┐
                        │  <siem-host>  (RPi5 16GB, 2TB NVMe)      │
                        │                                          │
  Unifi GW ──UDP/514──► │  Alloy (systemd)                        │
                        │    ├─ syslog receiver → Loki             │
  <node-*> ────TCP─────►│    └─ node metrics → Prometheus          │
   (Alloy agents)       │                                          │
                        │  Docker Compose                          │
  Browser ─────────────►│    ├─ Grafana    :3000                  │
                        │    ├─ Loki       :3100 (internal)        │
                        │    └─ Prometheus :9090 (internal)        │
                        │                                          │
  Wazuh agents ────────►│  Wazuh Manager (systemd)                │
    (all nodes)         │    ├─ agent events    :1514              │
                        │    ├─ enrollment      :1515              │
                        │    └─ REST API        :55000 (local)     │
                        └──────────────────────────────────────────┘
```

Each remote node runs (managed via dotconfig):
- **Grafana Alloy** (systemd) — ships journal logs and node metrics to the SIEM server
- **Wazuh Agent** (systemd) — ships security events to Wazuh Manager

---

### Log Flow

#### 1. Systemd Journal (remote nodes → Loki)

```
systemd journal  (local read, no port)
    │
    ▼
Alloy  loki.source.journal
    │  relabel:
    │    __journal__systemd_unit  → label "unit"
    │    __journal__hostname      → label "host"
    │    static: job="journal", instance="<node>"
    │
    ▼  HTTP POST  TCP 3100
<siem-host>:3100  (Loki container)
    │
    ▼
/opt/siem/data/loki  (chunks on disk)
```

**Sample — raw journal entry:**
```
Apr 18 12:00:01 <node> sshd[1234]: Failed password for invalid user admin from 10.0.0.1 port 54321 ssh2
```

**Sample — Loki push body (JSON):**
```json
{
  "streams": [{
    "stream": { "unit": "ssh.service", "host": "<node>", "job": "journal", "instance": "<node>" },
    "values": [["1713441601000000000", "Failed password for invalid user admin from 10.0.0.1 port 54321 ssh2"]]
  }]
}
```

> **Minimal-mode nodes** (RAM-constrained): same journal → Loki path; node_exporter/metrics are skipped.

#### 2. Unifi Gateway Syslog (→ Loki)

```
Unifi GW  [configured via Unifi UI → Settings → System → Logging]
    │
    ▼  UDP 514
<siem-host>:514  (Alloy server-mode syslog receiver)
    │  parse RFC3164: priority, timestamp, hostname, program → Loki labels
    │  add static: job="unifi"
    │
    ▼  HTTP POST  TCP 3100  (localhost)
Loki container
    │
    ▼
/opt/siem/data/loki
```

**Sample — on the wire (RFC3164):**
```
<134>Apr 18 12:00:05 unifi-gw kernel: [1234567.890] eth0: link is up at 1Gbps
```

**Sample — Loki push body (JSON):**
```json
{
  "streams": [{
    "stream": { "job": "unifi", "hostname": "unifi-gw", "program": "kernel" },
    "values": [["1713441605000000000", "[1234567.890] eth0: link is up at 1Gbps"]]
  }]
}
```

> Message content is preserved verbatim. RFC3164 envelope fields (hostname, program) become Loki stream labels.

#### 3. RPi Hardware Metrics (vcgencmd → Prometheus)

```
vcgencmd  (temperature, voltage, clock, throttle)
    │
    ▼  /usr/local/bin/rpi-metrics  (bash, runs every 30 s via systemd timer)
    │
/var/lib/node_exporter/textfile_collector/rpi.prom  (Prometheus text format, no port)
    │
    ▼
Alloy  prometheus.exporter.unix  [reads textfile_collector dir]
    │
    ▼  HTTP POST  TCP 9090  (Prometheus remote write, snappy-compressed protobuf)
<siem-host>:9090  (Prometheus container)
    │
    ▼
/opt/siem/data/prometheus  (TSDB on disk)
```

**Sample — rpi.prom file:**
```
rpi_temperature_celsius 47.2
rpi_voltage_volts{component="core"} 0.8563
rpi_voltage_volts{component="sdram_c"} 1.2000
rpi_clock_hz{clock="arm"} 1800000000
rpi_clock_hz{clock="core"} 400000000
rpi_throttled_flags 0
rpi_undervoltage_detected 0
rpi_throttled_now 0
```

> Wire format (node → Prometheus) is snappy-compressed protobuf — not human-readable.

#### 4. Node Metrics (system-level → Prometheus)

Same remote-write path as RPi metrics; collected in-process by Alloy (no textfile intermediary).

```
Alloy  prometheus.exporter.unix  [reads /proc, /sys]
    │
    ▼  HTTP POST  TCP 9090  (protobuf remote write)
<siem-host>:9090  (Prometheus)
```

#### 5. Wazuh Security Events (→ Wazuh Manager)

```
System events  (auth, file integrity, syscheck, etc.)
    │
    ▼
Wazuh Agent  (ossec-agentd, /var/ossec/)
    │
    ├──[enrollment, one-time]──► TCP 1515  →  <siem-host>:1515
    │
    └──[event stream, continuous]─► TCP 1514  →  <siem-host>:1514
                                       OSSEC encrypted binary protocol
    │
    ▼
Wazuh Manager  (systemd on <siem-host>)
    │  rules engine: decode → parse → enrich → alert
    │
    ├── /var/ossec/logs/alerts/  (JSON alerts)
    └── /var/ossec/queue/db/     (event DB)
    │
    ▼  HTTPS  TCP 55000  (localhost only)
Wazuh REST API  →  Grafana (API plugin)
```

**Sample — Wazuh alert JSON (post-rules):**
```json
{
  "timestamp": "2026-04-18T12:00:01.000+0000",
  "rule": { "level": 5, "description": "sshd: Authentication failed.", "id": "5760" },
  "agent": { "id": "001", "name": "<node>" },
  "data": { "srcip": "10.0.0.1", "srcuser": "admin" },
  "full_log": "Failed password for invalid user admin from 10.0.0.1 port 54321 ssh2"
}
```

> Agent → Manager is an encrypted OSSEC binary protocol. JSON is produced by the manager after decoding and rule evaluation.

#### Port Summary

| Source | Port | Proto | Direction | Receiver |
|---|---|---|---|---|
| Systemd journal | 3100 | TCP | nodes → siem-host | Loki |
| Unifi GW syslog | 514 | UDP | unifi-gw → siem-host | Alloy (server mode) |
| Node / RPi metrics | 9090 | TCP | nodes → siem-host | Prometheus |
| Wazuh enrollment | 1515 | TCP | nodes → siem-host | Wazuh Manager |
| Wazuh events | 1514 | TCP | nodes → siem-host | Wazuh Manager |
| Wazuh REST API | 55000 | HTTPS | localhost only | — |
| Alloy self-metrics | 12345 | HTTP | local only | — |
| Grafana UI | 3000 | HTTP | clients → siem-host | Grafana |

---

### UI URLs

| Service | URL | Notes |
|---|---|---|
| Grafana | http://\<siem-host\>:3000 | Login: `admin` / `vault_grafana_admin_password` |
| Alloy UI | http://\<siem-host\>:12345 | Pipeline graph + component status |
| Prometheus | http://\<siem-host\>:9090 | SSH tunnel required — bound to 127.0.0.1 |
| Wazuh API | https://\<siem-host\>:55000 | SSH tunnel required — bound to localhost |

> **Prometheus / Wazuh API tunnel:**
> ```bash
> ssh -L 9090:localhost:9090 -L 55000:localhost:55000 <user>@<siem-host>
> ```

---

### Data Locations

| Service | Path on siem-host |
|---|---|
| Grafana data | `/opt/siem/data/grafana` |
| Loki chunks | `/opt/siem/data/loki` |
| Prometheus TSDB | `/opt/siem/data/prometheus` |
| Compose + all configs | `/opt/siem/config/` |
| Wazuh logs/rules/agents | `/var/ossec/` |
| Alloy config | `/etc/alloy/config.alloy` |
| PostgreSQL data | `/var/lib/postgresql/16/main/` |
| Redis RDB snapshot | `/var/lib/redis/dump.rdb` |
| PostgreSQL backups | `/opt/siem/backups/postgresql/` |

---

### Secrets

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

### Operations

```bash
ssh <user>@<siem-host>

# LGTM Docker stack
cd /opt/siem/config
sudo docker compose -f docker-compose.lgtm.yml ps
sudo docker compose -f docker-compose.lgtm.yml logs -f grafana
sudo docker compose -f docker-compose.lgtm.yml restart

# Infisical Docker stack
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml ps
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml logs -f infisical

# PostgreSQL
sudo systemctl status postgresql@16-main
sudo -u postgres psql -c '\l'       # list databases
sudo -u postgres psql infisical     # connect to infisical DB

# Redis
sudo systemctl status redis-server
redis-cli ping                      # should return PONG

# Wazuh Manager
sudo systemctl status wazuh-manager
sudo journalctl -u wazuh-manager -f

# Alloy (server mode)
sudo systemctl status alloy
sudo journalctl -u alloy -f

# PostgreSQL backup (manual trigger)
sudo systemctl start pg-backup.service
sudo journalctl -u pg-backup -n 50 --no-pager

# Or from local machine:
make backup

# Verify Wazuh agent registration
sudo /var/ossec/bin/agent_control -l
```

| Service | Logs |
|---|---|
| Grafana | `docker compose logs grafana` or `/opt/siem/data/grafana/grafana.log` |
| Loki | `docker compose logs loki` |
| Prometheus | `docker compose logs prometheus` |
| Infisical | `docker compose -f .../docker-compose.infisical.yml logs infisical` |
| PostgreSQL | `journalctl -u postgresql@16-main` |
| Redis | `/var/log/redis/redis-server.log` |
| pg-backup | `journalctl -u pg-backup` |
| Wazuh Manager | `/var/ossec/logs/ossec.log` |
| Alloy | `journalctl -u alloy` |

### Infisical — First Run

After deploying, create the initial admin account via the web UI:

1. Open `http://<siem-host>:8080` in a browser
2. Click **Sign up** and register the first admin user
3. Create an organization and project
4. Add secrets via the UI or Infisical CLI (`infisical secrets set`)

### Infisical — Upgrading

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

### Verification Checklist

```bash
# Grafana health
curl -s http://<siem-host>:3000/api/health

# From siem-host only (bound to 127.0.0.1):
ssh <user>@<siem-host> 'curl -s http://localhost:3100/ready'   # Loki
ssh <user>@<siem-host> 'curl -s http://localhost:9090/-/ready' # Prometheus

# Alloy self-metrics
curl -s http://<siem-host>:12345/metrics | head -5

# Wazuh agents
ssh <user>@<siem-host> 'sudo /var/ossec/bin/agent_control -l'

# Unifi syslog (after configuring Unifi)
# Grafana → Explore → Loki → {job="unifi"}
```

### Monitoring Thermal Throttling

The `rpi-metrics` script exposes these Prometheus metrics every 30 s:

| Metric | Meaning |
|---|---|
| `rpi_throttled_now` | 1 = currently throttling (bit 2) |
| `rpi_freq_capped` | 1 = frequency capped now (bit 1) |
| `rpi_undervoltage_detected` | 1 = undervoltage now (bit 0) |
| `rpi_temp_limited_now` | 1 = temp-limited now (bit 3) |
| `rpi_throttled_occurred` | 1 = throttled since last reboot (sticky, bit 18) |
| `rpi_temperature_celsius` | SoC temperature |

**Grafana (Explore → Prometheus):**
```promql
rpi_throttled_now == 1           # any node actively throttling
changes(rpi_throttled_now[1h])   # throttle events over time
rpi_throttled_occurred == 1      # has throttled since last reboot
```

**SSH quick-check:**
```bash
vcgencmd get_throttled
# 0x0     = all clear
# 0x4     = currently throttled
# 0x50000 = has throttled since boot
```
