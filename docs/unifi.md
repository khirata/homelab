# Unifi Integration

Two separate pipelines collect data from Unifi:

| Pipeline | Transport | Destination |
|---|---|---|
| Syslog (gateway logs) | UDP 514 → Alloy | Loki |
| Metrics (controller API) | HTTP poll → Unpoller (Docker) | Prometheus |

---

## Syslog → Loki

Grafana Alloy (server mode) listens on UDP 514 and parses RFC3164 syslog from the Unifi gateway.

**Configure the Unifi controller:**
Settings → System → Logging → Remote Syslog → `<SIEM_SERVER_IP>:514` UDP

Logs appear in Grafana → Explore → Loki → `{job="unifi"}`.

### Labels

Each site gets its own listener port so the `site` label is indexed at ingest:

| Label | Source | Example |
|---|---|---|
| `job` | static | `unifi` |
| `site` | listener port (514 = lafayette, 515 = sakamoto) | `lafayette` |
| `host` | `__syslog_message_hostname`, else parsed from the message body | `UCG-Fiber` |

Without a `host` label the syslog streams carry only `{job, site}`, so gateways
never appear in the **Host** dropdown of the Log Explorer dashboard — the logs
arrive fine, they are just unattributed. If gateways go missing from that
dropdown again, start with the two stages below in `alloy-server.alloy.j2`.

`host` is populated in two stages, because Unifi's RFC3164 output is
inconsistent:

1. `loki.relabel "unifi_syslog"` promotes `__syslog_message_hostname`. Measured
   against live traffic this covers only about **a third** of lines.
2. `loki.process "unifi_syslog"` recovers the rest from the start of the message
   body, which always begins with the device name. `stage.match` restricts this
   to lines the parser could not resolve, since on lines it *did* resolve the
   body may begin with the process tag instead (`hostapd[10291]: …`).

Stage 1 alone would be worse than no label at all: the dropdown would look
functional while silently hiding two thirds of each device's logs. Verified
after deploy — 100% of Unifi lines carry a `host`, and the only values present
are real device names.

There is no `appname` label. `__syslog_message_app_name` is never populated for
this RFC3164 traffic, and no alert or dashboard needs it — the VPN rules match
on line content instead.

---

## Metrics → Prometheus (Unpoller)

Unpoller polls each Unifi controller's API and exposes metrics in Prometheus format.
Prometheus scrapes Unpoller at `:9130`.

**Configure controllers** via `.env`:

```bash
UNIFI_CONTROLLER_URL_SITE1=https://10.x.x.x:443
UNIFI_USERNAME_SITE1=unpoller
UNIFI_PASSWORD_SITE1=changeme

UNIFI_CONTROLLER_URL_SITE2=https://10.x.x.x:443
UNIFI_USERNAME_SITE2=unpoller
UNIFI_PASSWORD_SITE2=changeme
```

Create a **read-only local user** in each Unifi controller for Unpoller:
- UnifiOS (UDM / Dream Machine): Settings → Admins → Add Admin → Role: Read Only
- Older CloudKey / software controller: port 8443 instead of 443

**Operations:**

```bash
ssh <user>@<siem-host>

sudo docker compose -f /opt/siem/config/docker-compose.lgtm.yml ps unpoller
sudo docker compose -f /opt/siem/config/docker-compose.lgtm.yml logs -f unpoller
```

Metrics appear in Grafana → Dashboards → Unifi WAN / Node Traffic.

---

## VPN monitoring

The inter-site VPN is **WireGuard**. Four tunnel interfaces appear in the
gateway syslog:

| Interface | Role | Notes |
|---|---|---|
| `wgclt1` | WireGuard **client**, Lafayette → Sakamoto | carries devices policy-routed to exit at Sakamoto (e.g. the TV) |
| `wgsts1000` | UniFi **Magic Site-to-Site** WireGuard | GW-to-GW, self-heals via UniFi cloud coordination |
| `wgsrv1` | WireGuard **server** on each GW | roaming laptops/phones |
| `tunovpnc4` | NordVPN OpenVPN client (Lafayette) | unrelated to the inter-site VPN — do not use it to reason about site connectivity |

`wgclt1`, `wgsts1000` and `tunovpnc4` are all attached to **wanFailover** as WAN
interfaces. wanFailover emits a matched pair per tunnel:

```
wf-interfaces-container releases 'wgclt1' as a WAN interface   → down
wf-interfaces-container controls 'wgclt1' as a WAN interface   → up
```

**This pair is the reliable health signal.** A healthy blip pairs them within
~90 s; a stuck tunnel leaves an unmatched `releases`.

### The failure mode: silent leak, not outage

On 2026-07-27 21:44:34 the Sakamoto end re-established on a new UDP source port
and every tunnel dropped. `wgsts1000` and `wgsrv1` recovered on their own within
~90 s. `wgclt1` did **not** — it was released from WAN and never re-resolved its
DDNS peer, staying down **47 hours** until it was restarted manually on 07-29
20:24.

Nothing appeared "down" during those 47 hours. Devices policy-routed over
`wgclt1` simply fell back to the local Lafayette WAN and kept working, just
egressing from the wrong site. That is why it was only noticed via geo-located
content on the TV, and why no volume-based alert could have caught it — total
syslog volume was completely normal throughout.

> **Do not build VPN alerts on tunnel create/delete/reconfigure events.**
> `wireguard-interface-controller: Creating|Deleting`, and
> `has to be reconfigured because … was resolved to`, are emitted by the manual
> restart that *fixes* the problem. An alert keyed on them fires only after the
> outage is already over.

**Dashboard:** Grafana → Dashboards → **VPN Health** (`vpn-health`).

### Alerting: withdrawn

**There is currently no alerting on VPN health.** The `vpn-watchdog` group was
removed on 2026-08-11. Nothing pages when an inter-site tunnel drops — the
dashboard above is the only signal, and it has to be looked at deliberately.

The group held three rules, keyed on wanFailover attachment state
(`releases` minus `controls`) and on peer session balance, both over a 7d window:
`vpn-wan-tunnel-released`, `vpn-peer-lost`, `vpn-peer-flapping`.

They were not wrong. Every firing corresponded to a real tunnel drop, and the two
state rules independently corroborated each other within ~4 minutes on each
occasion. They were withdrawn because the *signal was not actionable*: the link
drops and recovers on its own, so the pages arrived for events that needed no
human response, and the noise cost exceeded the value.

That distinction matters for whatever replaces them. The detection worked; what
is missing is a way to tell a self-healing blip from an outage that will persist.
Candidates:

- **Wait before firing.** The 2026-07-27 outage lasted 47h; the 08-06 one
  self-healed in ~12h. A `for:` of several hours would have caught the first and
  ignored the second. Simple, and it fits the existing rules unchanged.
- **Probe the path instead of the logs.** A blackbox probe egressing through the
  tunnel answers the question that actually matters — is traffic leaving from the
  right site — and would also catch a tunnel that stays attached but stops
  passing traffic. Needs a probe target at the far end.
- **Alert on impact, not on state.** Detect that a policy-routed device is
  egressing from the wrong WAN, which is the condition anyone actually cares
  about.

The removed rules are recoverable from git history if the `for:`-duration route
is taken — see the `vpn-watchdog` group prior to its removal for the working
LogQL, including the `A - (B or (A * 0))` form needed to stop the subtraction
inner-joining away the very tunnel it is meant to catch.

**Useful queries:**

```logql
{job="unifi"} |~ `wf-interfaces-container (releases|controls) 'wg`
```

```logql
{job="unifi"} |~ `via wg(clt|sts)[0-9]+ .*\) (dis)?connected`
```

Two traps when tracing an incident:

- Inbound `PortForward DNAT [... openvpn]` lines on UDP 1194 are internet
  background scanning, not tunnel activity.
- A bare `connected` filter also matches `disconnected` — anchor on the closing
  paren (`\) connected`).

---

**Note:** The Docker healthcheck is disabled for unpoller. The image is a minimal Go binary without `wget` or `curl`, so any `CMD`-based healthcheck fails with `executable file not found`. Liveness is observable via Prometheus scrape gaps in Grafana instead. See [PR #27](https://github.com/khirata/homelab/pull/27).
