# Operations

## Quick Reference

### LGTM Stack

```bash
ssh <user>@<siem-host>
cd /opt/siem/config

sudo docker compose -f docker-compose.lgtm.yml ps
sudo docker compose -f docker-compose.lgtm.yml logs -f grafana
sudo docker compose -f docker-compose.lgtm.yml restart
```

### Infisical Stack

```bash
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml ps
sudo docker compose -f /opt/siem/config/docker-compose.infisical.yml logs -f infisical
```

### Systemd Services

```bash
# PostgreSQL
sudo systemctl status postgresql@16-main
sudo -u postgres psql -c '\l'

# Redis
sudo systemctl status redis-server
redis-cli ping

# Wazuh Manager
sudo systemctl status wazuh-manager
sudo journalctl -u wazuh-manager -f

# Alloy (server mode)
sudo systemctl status alloy
sudo journalctl -u alloy -f
```

---

## Log Locations

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

---

## Verification Checklist

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

---

## SSH Tunnels

Some services bind to `localhost` only and require an SSH tunnel for local access:

```bash
ssh -L 9090:localhost:9090 -L 55000:localhost:55000 <user>@<siem-host>
```

Then access:
- Prometheus: `http://localhost:9090`
- Wazuh API: `https://localhost:55000`
