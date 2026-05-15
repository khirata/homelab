# Wazuh SIEM

## Architecture

```
Agents (laf1, laf2)
    │  TCP 1514 (events)
    │  TCP 1515 (enrollment)
    ▼
Wazuh Manager (systemd, laf3)
    │  writes  /var/ossec/logs/alerts/alerts.json
    │  HTTPS → 127.0.0.1:9200 (indexer output)
    ▼
wazuh-filebeat ─────────────────────────────────────────────┐
                                                             │ HTTPS 9200
wazuh-indexer  (OpenSearch, Docker, 127.0.0.1:9200) ◄───────┘
    ▲
    │ HTTPS 9200
wazuh-dashboard (OpenSearch Dashboards, Docker, internal only)
    ▲
    │ HTTP 5601 (Docker internal network)
nginx-cf-proxy (Docker, 127.0.0.1:5600)
    │  validates Cf-Access-Jwt-Assertion
    │  injects x-proxy-user / x-proxy-roles
    ▲
    │ HTTP (loopback)
Cloudflare Tunnel → Cloudflare Access SSO → User
```

### Auth flow (no second login)

1. User hits `https://wazuh.yourdomain.com` → Cloudflare Access prompts for SSO (once per session)
2. Cloudflare Tunnel forwards request to `127.0.0.1:5600` with `Cf-Access-Jwt-Assertion` header
3. nginx njs decodes the JWT payload, extracts `email` claim
4. nginx injects `x-proxy-user: <email>` and `x-proxy-roles: admin` before proxying to dashboard
5. Dashboard uses OpenSearch Security proxy auth mode — trusts those headers, shows no login form

---

## Ports

| Port | Proto | Bound to | Purpose |
|---|---|---|---|
| 1514 | TCP | `0.0.0.0` | Agent event stream |
| 1515 | TCP | `0.0.0.0` | Agent enrollment |
| 55000 | HTTPS | `localhost` | Manager REST API |
| 9200 | HTTPS | `127.0.0.1` | Indexer (OpenSearch) |
| 5600 | HTTP | `127.0.0.1` | nginx CF proxy (Cloudflare Tunnel ingress) |
| 5601 | HTTP | Docker internal | Dashboard (not published to host) |

---

## Bootstrap: first deploy

### 1. Generate bcrypt hashes

Before running `make deploy-siem`, generate hashes for the two indexer users and load them into Infisical:

```bash
# Generate hash for WAZUH_INDEXER_ADMIN_PASSWORD
docker run --rm wazuh/wazuh-indexer:4.14.5 \
  bash plugins/opensearch-security/tools/hash.sh -p '<your-admin-password>'

# Generate hash for WAZUH_KIBANASERVER_PASSWORD
docker run --rm wazuh/wazuh-indexer:4.14.5 \
  bash plugins/opensearch-security/tools/hash.sh -p '<your-kibanaserver-password>'
```

Store the resulting `$2y$12$...` strings as `WAZUH_INDEXER_ADMIN_HASH` and
`WAZUH_KIBANASERVER_HASH` in Infisical (prod environment).

### 2. Set Infisical secrets

| Key | Description |
|---|---|
| `WAZUH_INDEXER_ADMIN_PASSWORD` | OpenSearch admin password |
| `WAZUH_KIBANASERVER_PASSWORD` | kibanaserver service account password |
| `WAZUH_INDEXER_ADMIN_HASH` | bcrypt hash of admin password |
| `WAZUH_KIBANASERVER_HASH` | bcrypt hash of kibanaserver password |
| `WAZUH_DASHBOARD_EXTERNAL_URL` | e.g. `https://wazuh.yourdomain.com` |

### 3. Cloudflare setup

In the Cloudflare dashboard (one.dash.cloudflare.com):

1. **Tunnel config** — add a public hostname:
   - Hostname: `wazuh.yourdomain.com`
   - Service: `http://127.0.0.1:5600`

2. **Access application** — create a Self-Hosted app:
   - Domain: `wazuh.yourdomain.com`
   - Policy: email domain or specific emails
   - Identity provider: your SSO (Google, GitHub, etc.)

After both are set, navigating to `https://wazuh.yourdomain.com` will prompt for Cloudflare Access SSO once, then land directly in the Wazuh Dashboard.

### 4. Deploy

```bash
make deploy-siem
```

TLS certs are generated automatically on first deploy (`siem_config_dir/wazuh-indexer/certs/`).
OpenSearch security config is applied once via `securityadmin.sh`; subsequent runs skip it.

---

## Operations

```bash
ssh <user>@<siem-host>

# Wazuh Manager (systemd)
sudo systemctl status wazuh-manager
sudo journalctl -u wazuh-manager -f

# Indexer / Dashboard / Filebeat / nginx (Docker)
docker compose -f /opt/siem/config/docker-compose.wazuh.yml ps
docker compose -f /opt/siem/config/docker-compose.wazuh.yml logs -f wazuh-indexer
docker compose -f /opt/siem/config/docker-compose.wazuh.yml logs -f wazuh-filebeat

# List registered agents
sudo /var/ossec/bin/agent_control -l

# Indexer health
curl -sk -u admin:<WAZUH_INDEXER_ADMIN_PASSWORD> \
  https://127.0.0.1:9200/_cluster/health | jq .
```

### Logs

| Path | Contents |
|---|---|
| `/var/ossec/logs/ossec.log` | Manager daemon log |
| `/var/ossec/logs/alerts/alerts.json` | Structured alerts (shipped to indexer) |
| `/var/ossec/queue/db/` | Agent event database |

---

## Custom rules (local_rules.xml)

| Rule ID | Level | Description | Triggers active-response |
|---|---|---|---|
| 100100 | 12 | SSH brute-force ≥8 failures/2 min (invalid user) | firewall-drop 10 min |
| 100101 | 12 | SSH brute-force ≥8 failures/2 min (valid user) | firewall-drop 10 min |
| 100200 | 8 | Sudo command executed | — |
| 100201 | 10 | Command run as root via sudo | — |
| 100300 | 10 | Port scan: 20+ connection events/60 s from same IP | — |

### Active-response whitelist

IPs in `wazuh_active_response_whitelist` (group_vars/all/vars.yml) are never blocked.
Default: `["127.0.0.1"]`. Add your admin workstation IP to avoid accidental self-lockout.

To unblock an IP manually:
```bash
sudo iptables -D INPUT -s <ip> -j DROP
sudo iptables -D FORWARD -s <ip> -j DROP
```

### Manager REST API tunnel

```bash
ssh -L 55000:localhost:55000 <user>@<siem-host>
# Then: curl -k -u wazuh:<WAZUH_API_PASSWORD> https://localhost:55000/
```

---

## Cert rotation

Certs are self-signed with a 10-year TTL. To regenerate:

```bash
ssh <user>@<siem-host>
sudo rm /opt/siem/config/wazuh-indexer/certs/root-ca.pem
sudo rm /opt/siem/config/wazuh-indexer/.security_applied
```

Then re-run `make deploy-siem`. Existing data is preserved; only certs are replaced.

---

## Troubleshooting

**Indexer won't start — `max virtual memory areas` error**
```bash
sudo sysctl -w vm.max_map_count=262144   # already set by Ansible; verify with sysctl vm.max_map_count
```

**Dashboard stuck on loading — can't reach indexer**
```bash
docker logs wazuh-dashboard | grep -i error
# Check indexer health first:
curl -sk -u admin:<pw> https://127.0.0.1:9200/_cluster/health
```

**Filebeat not shipping alerts**
```bash
docker logs wazuh-filebeat | tail -50
# Verify the mount exists on the host:
ls -la /var/ossec/logs/alerts/alerts.json
```

**nginx returns 401 — Cloudflare JWT missing**
```bash
docker logs wazuh-nginx-cf-proxy
# Ensure Cloudflare Tunnel is configured to send to http://127.0.0.1:5600
# and the Access application covers the correct hostname.
```

**Active-response blocked legitimate IP**
```bash
sudo iptables -L INPUT -n | grep DROP
sudo iptables -D INPUT -s <ip> -j DROP
```
