# Grafana Alloy

Alloy runs in two modes:

- **Server mode** (this repo) — receives Unifi syslog (UDP 514), ships to Loki; exposes self-metrics on port 12345. See [unifi.md](unifi.md) for Unifi-specific setup.
- **Node mode** (managed via [dotconfig](https://github.com/khirata/dotconfig)) — ships journal logs + node metrics from each monitored host

---

## Operations

```bash
ssh <user>@<siem-host>

# Status
sudo systemctl status alloy

# Logs (live)
sudo journalctl -u alloy -f
```

| Item | Path |
|---|---|
| Config | `/etc/alloy/config.alloy` |
| Self-metrics | `http://<siem-host>:12345/metrics` |
| UI (pipeline graph) | `http://<siem-host>:12345` |

---

## RPi Thermal Metrics

The `rpi-metrics` script writes Prometheus text format to
`/var/lib/node_exporter/textfile_collector/rpi.prom` every 30 seconds via a systemd timer.
Alloy reads this via `prometheus.exporter.unix` and remote-writes to Prometheus.

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
