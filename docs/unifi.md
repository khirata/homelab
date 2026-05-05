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

**Note:** The Docker healthcheck is disabled for unpoller. The image is a minimal Go binary without `wget` or `curl`, so any `CMD`-based healthcheck fails with `executable file not found`. Liveness is observable via Prometheus scrape gaps in Grafana instead. See [PR #27](https://github.com/khirata/homelab/pull/27).
