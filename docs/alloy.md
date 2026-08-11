# Grafana Alloy

Alloy runs in three modes, all managed by **this repo** (`roles/alloy`, selected by `alloy_mode`):

- **Server mode** (`siem_server`) — receives Unifi syslog (UDP 514), ships to Loki; exposes self-metrics on port 12345. See [unifi.md](unifi.md) for Unifi-specific setup.
- **Node mode** (`nodes`, `postgresql_server`, `redis_server`) — ships journal logs + node metrics to the SIEM server
- **Minimal mode** — journal logs only, for RPi Zero 2W class hosts with too little RAM for node_exporter

```bash
make deploy-nodes    # re-apply Alloy + agents to the monitored nodes only
```

### Config ownership

`/etc/alloy/config.alloy` is owned by this repo alone. The
[dotconfig](https://github.com/khirata/dotconfig) repo used to write it too, for the hosts it
bootstraps, and the two copies drifted — dotconfig kept the SIEM address laf3 had before it was
rebuilt on an RPi5, so a dotconfig run on laf2 pointed Alloy at a dead host and every metric and
log line from it was dropped for a week. Nothing alerted: the unit stayed `active` and the failure
was a warn-level retry loop.

dotconfig no longer applies its `alloy` role to laf1/laf2. It still owns `rpi_metrics` on every
RPi — that role writes the `rpi_*` textfile metrics this repo's dashboards read but does not
itself manage. **If Alloy config appears on a node that this repo did not write, check dotconfig's
`site.yml` before assuming drift.**

To confirm a node is shipping to the right place:

```bash
sudo grep 'url = ' /etc/alloy/config.alloy
```

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
