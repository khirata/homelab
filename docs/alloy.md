# Grafana Alloy

Alloy runs in three modes, all managed by **this repo** (`roles/alloy`, selected by `alloy_mode`):

- **Server mode** (`siem_server`) — receives Unifi syslog (UDP 514), ships to Loki; receives phone telemetry over the Loki push API (see [Phone telemetry](#phone-telemetry-loki-push-api)); exposes self-metrics on port 12345. See [unifi.md](unifi.md) for Unifi-specific setup.
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

## Phone telemetry (Loki push API)

The phone that tethers while travelling reports its own state (battery, temperature,
charging) straight to Loki, so a dead or overheating phone is distinguishable from a dead
home network.

```
Phone ──HTTPS──► phone-push.<domain>  (Cloudflare Access: service token required)
                   │  tunnel ingress passes only /loki/api/v1/(push|raw); everything else 404
                   ▼
cloudflared on siem-host ──► 127.0.0.1:3500  (Alloy loki.source.api "phone")
                   │  labelkeep job|site, add source="phone-push", keep device timestamps
                   ▼
                 Loki
```

The listener is bound to `127.0.0.1`, so the tunnel is the only way in — nothing on the LAN
can push to it either. Tunnel, DNS, Access application and the service token are managed in
[cloudflared-deployment](https://github.com/khirata/cloudflared-deployment) (`phone-push-token`
policy; credentials from `terraform output phone_push_token_id` /
`terraform output -raw phone_push_token_secret`).

**Request**

```
POST https://phone-push.<domain>/loki/api/v1/push
Content-Type: application/json
CF-Access-Client-Id: <phone_push_token_id>
CF-Access-Client-Secret: <phone_push_token_secret>

{"streams":[{"stream":{"job":"pixel6a","site":"lafayette"},
  "values":[["<unix-seconds>000000000","battery=87 temp=31.2 power=charging"]]}]}
```

A `204` means Loki accepted it. A `302`/`403` comes from Cloudflare Access (missing or wrong
headers) and never reached Alloy.

**Labels are server-controlled.** Only `job` and `site` survive from the client; any other
label is dropped, and every stream gets `source="phone-push"`. Query with
`{source="phone-push"}` — a client sending `job="journal"` still cannot blend into the real
journal streams.

**Timestamps are the phone's** (`use_incoming_timestamp`), so readings queued while offline
land when they were taken. Loki rejects entries older than its `reject_old_samples_max_age`
(default one week).

Smoke test from the siem host, bypassing the tunnel:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  http://127.0.0.1:3500/loki/api/v1/push \
  -d "{\"streams\":[{\"stream\":{\"job\":\"test\",\"site\":\"lafayette\"},\"values\":[[\"$(date +%s)000000000\",\"battery=0 temp=0 power=test\"]]}]}"
```

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
