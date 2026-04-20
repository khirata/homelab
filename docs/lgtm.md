# Grafana LGTM Stack

Grafana, Loki, and Prometheus run as a Docker Compose stack on the SIEM server.

## UI URLs

| Service | URL | Notes |
|---|---|---|
| Grafana | http://\<siem-host\>:3000 | Login: `admin` / `GRAFANA_ADMIN_PASSWORD` |
| Alloy UI | http://\<siem-host\>:12345 | Pipeline graph + component status |
| Prometheus | http://\<siem-host\>:9090 | SSH tunnel required — bound to 127.0.0.1 |

> **Prometheus tunnel:**
> ```bash
> ssh -L 9090:localhost:9090 <user>@<siem-host>
> ```

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
