# Wazuh Manager

Wazuh Manager runs as a systemd service on the SIEM server and receives security events from Wazuh Agents on all monitored nodes.

## Ports

| Port | Proto | Purpose |
|---|---|---|
| 1514 | TCP | Agent event stream (continuous) |
| 1515 | TCP | Agent enrollment (one-time) |
| 55000 | HTTPS | REST API (localhost only) |

> **Wazuh REST API tunnel:**
> ```bash
> ssh -L 55000:localhost:55000 <user>@<siem-host>
> ```

---

## Operations

```bash
ssh <user>@<siem-host>

# Status
sudo systemctl status wazuh-manager

# Logs (live)
sudo journalctl -u wazuh-manager -f

# List registered agents
sudo /var/ossec/bin/agent_control -l
```

| Log path | Contents |
|---|---|
| `/var/ossec/logs/ossec.log` | Manager daemon log |
| `/var/ossec/logs/alerts/` | JSON alerts (post-rules) |
| `/var/ossec/queue/db/` | Event database |

---

## Verification

```bash
# Confirm agents are active
ssh <user>@<siem-host> 'sudo /var/ossec/bin/agent_control -l'

# Grafana → Dashboards → Wazuh (API plugin)
```
