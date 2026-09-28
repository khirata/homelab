# Grafana LGTM Stack

Grafana, Loki, and Prometheus run as a Docker Compose stack on the SIEM server.

## UI URLs

| Service | URL | Notes |
|---|---|---|
| Grafana | http://\<siem-host\>:3000 | LAN: `admin` / `GRAFANA_ADMIN_PASSWORD`. Public (`grafana.<domain>`): Cloudflare Access, see below |
| Alloy UI | http://\<siem-host\>:12345 | Pipeline graph + component status |
| Prometheus | http://\<siem-host\>:9090 | SSH tunnel required — bound to 127.0.0.1 |

> **Prometheus tunnel:**
> ```bash
> ssh -L 9090:localhost:9090 <user>@<siem-host>
> ```

### Roles for Cloudflare Access users

With `CLOUDFLARE_TEAM_NAME` set, Grafana trusts the Cloudflare Access JWT and hides its own
login form, so the local `admin` account is unreachable from the public hostname. Users are
created on first sign-in, and their role is recomputed from the JWT email **on every login**:

- emails listed in `GRAFANA_ADMIN_EMAILS` (`.env`, comma-separated) → **Admin**
- everyone else → **Viewer**. Viewers can see dashboards but cannot open **Explore**.

Changing a role in the Grafana UI does not stick; it is overwritten at the next login.
Edit `GRAFANA_ADMIN_EMAILS`, then run `make deploy-siem`.

---

## Operations

```bash
ssh <user>@<siem-host>
cd /opt/siem/config

# Status
sudo docker compose -f docker-compose.lgtm.yml ps

# Logs
sudo docker compose -f docker-compose.lgtm.yml logs -f grafana
sudo docker compose -f docker-compose.lgtm.yml logs -f loki
sudo docker compose -f docker-compose.lgtm.yml logs -f prometheus

# Restart
sudo docker compose -f docker-compose.lgtm.yml restart
```

---

## Verification

```bash
# Grafana health
curl -s http://<siem-host>:3000/api/health

# Loki (from siem-host — bound to 127.0.0.1)
ssh <user>@<siem-host> 'curl -s http://localhost:3100/ready'

# Prometheus (from siem-host — bound to 127.0.0.1)
ssh <user>@<siem-host> 'curl -s http://localhost:9090/-/ready'

# Alloy self-metrics
curl -s http://<siem-host>:12345/metrics | head -5
```
