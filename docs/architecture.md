# Architecture

## SIEM Overview

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

Each remote node runs (managed via [dotconfig](https://github.com/khirata/dotconfig)):
- **Grafana Alloy** (systemd) — ships journal logs and node metrics to the SIEM server
- **Wazuh Agent** (systemd) — ships security events to Wazuh Manager

---

## Log Flows

### 1. Systemd Journal (remote nodes → Loki)

```
systemd journal  (local read, no port)
    │
    ▼
Alloy  loki.source.journal
    │  relabel:
    │    __journal__systemd_unit      → label "unit"
    │    __journal__systemd_unit      → label "service_name" (strips .service/.socket/.timer)
    │    __journal__syslog_identifier → label "service_name" (fallback: legacy syslog)
    │    __journal__transport         → label "service_name" (fallback: kernel/audit)
    │    __journal__comm              → label "service_name" (fallback: raw process)
    │    __journal__hostname          → label "host"
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
    "stream": { "unit": "ssh.service", "service_name": "ssh", "host": "<node>", "job": "journal", "instance": "<node>" },
    "values": [["1713441601000000000", "Failed password for invalid user admin from 10.0.0.1 port 54321 ssh2"]]
  }]
}
```

> **Minimal-mode nodes** (RAM-constrained): same journal → Loki path; node_exporter/metrics are skipped.

---

### 2. Unifi Gateway Syslog (→ Loki)

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

---

### 3. RPi Hardware Metrics (vcgencmd → Prometheus)

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

---

### 4. Node Metrics (system-level → Prometheus)

Same remote-write path as RPi metrics; collected in-process by Alloy (no textfile intermediary).

```
Alloy  prometheus.exporter.unix  [reads /proc, /sys]
    │
    ▼  HTTP POST  TCP 9090  (protobuf remote write)
<siem-host>:9090  (Prometheus)
```

---

### 5. Wazuh Security Events (→ Wazuh Manager)

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

---

## Port Summary

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
