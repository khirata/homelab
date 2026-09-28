# Grafana Alloy

Alloy runs in three modes, all managed by **this repo** (`roles/alloy`, selected by `alloy_mode`):

- **Server mode** (`siem_server`) — receives Unifi syslog (UDP 514), ships to Loki; receives off-site Loki pushes through Cloudflare Tunnel (see [Loki push clients](#loki-push-clients-via-cloudflare-tunnel)); exposes self-metrics on port 12345. See [unifi.md](unifi.md) for Unifi-specific setup.
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

## Loki push clients (via Cloudflare Tunnel)

Off-site clients push logs straight to Loki, each through its **own** hostname, service
token and Alloy listener. The first is the phone that tethers while travelling
(`visible`), which reports battery, temperature and charging state, so a dead or
overheating phone can be told apart from a dead home network.

```
Client ──HTTPS──► push-<name>.<domain>   Cloudflare Access: that client's service token only
                    │  tunnel ingress passes only /loki/api/v1/(push|raw); anything else 404
                    ▼
cloudflared on siem-host ──► 127.0.0.1:<port>   Alloy loki.source.api "push_<name>"
                    │  drop all client labels; set job, site, push_client=<name>, source="cf-push"
                    ▼
                  Loki
```

| Client | Hostname | Port | job | site |
|---|---|---|---|---|
| `visible` | `push-visible.hirata.dev` | 3501 | `pixel6a` | `lafayette` |

The listeners are bound to `127.0.0.1`, so the tunnel is the only way in, and nothing on
the LAN can push to them either.

**Labels belong to the server.** Every port serves exactly one client, so `job`, `site`
and `push_client` come from `loki_push_clients` in `group_vars/all/vars.yml`. Whatever the
client puts in `"stream": {...}` is discarded. A leaked token can only write under that one
client's labels, and it cannot pose as another client or as an internal job. Query everything
pushed from outside with `{source="cf-push"}`, or one client with `{push_client="visible"}`.

**Timestamps are the client's** (`use_incoming_timestamp`), so entries queued while
offline are stored at the time they were taken. Loki rejects entries older than
`reject_old_samples_max_age` (one week by default).

### Request

```
POST https://push-<name>.<domain>/loki/api/v1/push
Content-Type: application/json
CF-Access-Client-Id: <client id>
CF-Access-Client-Secret: <client secret>

{"streams":[{"stream":{},
  "values":[["<unix-seconds>000000000","battery=87 temp=31.2 power=charging"]]}]}
```

`stream` can be empty; any labels in it are ignored. A `204` means Loki accepted the
entries. A `302`/`403` comes from Cloudflare Access (missing or wrong headers) and never
reached Alloy.

Credentials come from cloudflared-deployment: `make tf-output-push HOST=push-<name>.<domain>`.

### Adding a client

The port is the one value the two repos must agree on.

1. **cloudflared-deployment**: add an ingress rule to `config/laf3.local.yml` with
   `service_token: true`, then `make tf-apply` and `make deploy LIMIT=laf3.local`:
   ```yaml
     - hostname: push-<name>.hirata.dev
       path: ^/loki/api/v1/(push|raw)$
       service: http://localhost:<port>
       service_token: true
   ```
2. **This repo**: append `{ name, port, job, site }` to `loki_push_clients`, then
   `make deploy-siem`.

### Revoking or removing a client

- **Rotate the credential and keep the endpoint:** in cloudflared-deployment,
  `make tf-rotate-push HOST=push-<name>.<domain>`. The old token stops working at once.
- **Remove the client:** delete the ingress rule, then `make tf-apply` (which deletes the
  DNS record, Access app, policy and token) and `make deploy LIMIT=laf3.local`. Drop
  the entry from `loki_push_clients` and `make deploy-siem`.

### Smoke test

Run this on the siem host; it bypasses the tunnel:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  http://127.0.0.1:3501/loki/api/v1/push \
  -d "{\"streams\":[{\"stream\":{\"job\":\"spoof\"},\"values\":[[\"$(date +%s)000000000\",\"battery=0 temp=0 power=test\"]]}]}"
```

Expect `204`. In Grafana, the line should appear under `{push_client="visible", job="pixel6a"}`
and not under `job="spoof"`.

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
