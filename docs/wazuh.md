# Wazuh SIEM

## Architecture

```
Agents (laf1, laf2)
    │  TCP 1514 (events)
    │  TCP 1515 (enrollment)
    ▼
Wazuh Manager (systemd, laf3)
    │  HTTPS → 127.0.0.1:9200 (native indexer output — no Filebeat needed)
    │  also writes /var/ossec/logs/alerts/alerts.json (local archive)
    ▼
wazuh-indexer  (OpenSearch, Docker, 127.0.0.1:9200)
    ▲
    │ HTTPS 9200
wazuh-dashboard (OpenSearch Dashboards, Docker, internal only)
    ▲
    │ HTTP 5601 (Docker internal network)
nginx-cf-proxy (Docker, 127.0.0.1:5600)
    │  validates Cf-Access-Jwt-Assertion via njs
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

### Proxy auth design notes

- **`opensearch_security.multitenancy.enabled: false`** — required. With proxy auth the login form
  never appears, so `user_requested_tenant` is always null. The security plugin fails silently before
  the Wazuh browser plugin can register its apps, producing "Application Not Found".
- **`opensearch.customHeaders: x-forwarded-for: "127.0.0.1"`** — required. OpenSearch Security proxy
  auth resolves the client's "real IP" from the XFF chain. Without this header every backend call
  returns a null username and the request is rejected.
- **`opensearch.requestHeadersWhitelist`** must include `x-proxy-user`, `x-proxy-roles`, and
  `x-forwarded-for`. By default OSD only forwards `authorization`; omitting the others causes the
  indexer to see a null user and return 401.
- **nginx `proxy_set_header` inheritance** — server-level `proxy_set_header` directives are
  **not inherited** when the `location` block defines its own `proxy_set_header` entries. All identity
  headers (`x-proxy-user`, `x-proxy-roles`, `X-Forwarded-For`) must be set inside `location /`.

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
| 5602 | HTTP | `0.0.0.0` | LAN debug — no JWT check, fixed proxy user (**disabled by default**) |

---

## Bootstrap: first deploy

### 1. Generate bcrypt hashes

Before running `make deploy-siem`, generate hashes for the two indexer users and load them into
Infisical:

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
| `WAZUH_API_PASSWORD` | Wazuh Manager REST API password |
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

After both are set, navigating to `https://wazuh.yourdomain.com` will prompt for Cloudflare Access
SSO once, then land directly in the Wazuh Dashboard.

### 4. Deploy

```bash
make deploy-siem
```

TLS certs are generated automatically on first deploy (`siem_config_dir/wazuh-indexer/certs/`).
OpenSearch security config is applied once via `securityadmin.sh`; subsequent runs skip it unless
`config.yml` changes (tracked by checksum sentinel).

---

## Agents

The agent package on the nodes (laf1, laf2) is installed out of band — `roles/wazuh_agent`
manages only the systemd surface around it (start timeout, `OnFailure` ntfy drop-in, enabled
+ running). The role is a no-op on hosts where `wazuh-agent.service` is absent.

Enrollment state lives in `/var/ossec/etc/client.keys` on both the manager and the agent, and is
**not** managed by Ansible. After a manager rebuild, verify the restored keys match the agents
rather than assuming enrollment succeeded — a mismatch does not always surface as an obvious error:

```bash
# On the manager and each agent — the hashes must match per agent
sudo awk '{print $2, $4}' /var/ossec/etc/client.keys | \
  while read n k; do echo "$n $(echo -n $k | sha256sum | cut -c1-16)"; done
```

Agent IDs are also a signal: preserved IDs mean the keys were restored, whereas IDs restarting
from `001` mean the agents re-enrolled from scratch.

---

## Operations

```bash
ssh <user>@<siem-host>

# Wazuh Manager (systemd)
sudo systemctl status wazuh-manager
sudo journalctl -u wazuh-manager -f

# Indexer / Dashboard / nginx (Docker)
docker compose -f /opt/siem/config/docker-compose.wazuh.yml ps
docker compose -f /opt/siem/config/docker-compose.wazuh.yml logs -f wazuh-indexer
docker compose -f /opt/siem/config/docker-compose.wazuh.yml logs -f wazuh-dashboard

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
| `/var/ossec/logs/alerts/alerts.json` | Structured alerts (local archive) |
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

## LAN debug endpoint (disabled by default)

A second nginx server block on port 5602 bypasses Cloudflare JWT validation and injects a fixed
`x-proxy-user: debug@local` / `x-proxy-roles: admin` identity. Useful for isolating auth issues
from dashboard issues without needing a valid CF Access token.

**To re-enable:**

1. In `ansible/roles/wazuh_stack/templates/nginx-cf-proxy.conf.j2`, remove the
   `{% if false %}` / `{% endif %}` wrapper around the debug server block.
2. In `ansible/roles/wazuh_stack/templates/docker-compose.wazuh.yml.j2`, uncomment the
   `wazuh_debug_port` line in the `nginx-cf-proxy` ports list.
3. Re-deploy: `make deploy-siem`

Access at `http://<siem-host>:5602` — no authentication required. **Do not expose on a public
interface in production.**

---

## Troubleshooting

**Agent shows `Active` on the manager but produces no alerts**

The most misleading failure in this stack. `agent_control -l` reports `Active` based on keepalives
from `wazuh-agentd` alone, so an agent whose `wazuh-logcollector` is dead still looks perfectly
healthy while dropping every log-based security event.

Root cause seen on laf2 (broken for four weeks before anyone noticed): the packaged unit is
`Type=forking` with `TimeoutSec=45`, and `wazuh-control start` brings the daemons up one at a time.
On a slow boot the sequence overran 45s, systemd terminated the unit mid-start, and
`wazuh-logcollector` / `wazuh-modulesd` never launched — while the already-started `wazuh-agentd`
kept running orphaned and kept sending keepalives.

Always check the daemon set, not just the unit or the manager's agent list:

```bash
sudo /var/ossec/bin/wazuh-control status   # all five daemons must be running
```

`wazuh-logcollector` missing is the tell. `roles/wazuh_agent` now raises `TimeoutStartSec` and wires
an `OnFailure` ntfy drop-in so this fails loudly instead of silently.

To confirm collection end to end, generate an event on the agent and look for it on the manager:

```bash
# On the agent
sudo -k; sudo /usr/bin/id >/dev/null

# On the manager — rule 100200, within a few seconds
sudo grep '"name":"<agent>"' /var/ossec/logs/alerts/alerts.json | tail -5
```

**"Application Not Found" after login**

In Wazuh 4.14.x the main dashboard app ID changed from `wazuh` to `wz-home`. If the deployed
`opensearch_dashboards.yml` still has `defaultRoute: /app/wazuh`, every browser session lands on
OSD's "Application Not Found" page because no app with that ID is registered.

```bash
grep defaultRoute /opt/siem/config/wazuh-dashboard/opensearch_dashboards.yml
# Must be: uiSettings.overrides.defaultRoute: /app/wz-home
```

Fix without a full re-deploy:
```bash
sudo sed -i 's|/app/wazuh|/app/wz-home|' /opt/siem/config/wazuh-dashboard/opensearch_dashboards.yml
cd /opt/siem/config && sudo docker compose -f docker-compose.wazuh.yml restart wazuh-dashboard
```

**CSP "inline script blocked" in browser DevTools**

Expected and harmless. OSD ships an intentional inline `<script>` in its HTML. A
CSP-compliant browser blocks it — OSD detects the block and considers the browser "secure". If you
add `'unsafe-inline'` to `script-src` to silence the DevTools warning, OSD's browser check inverts
and shows **"Your browser does not meet the security requirements"**. Leave the CSP alone.

**Dashboard returns 401 / session cookie immediately expires**

Caused by nginx `proxy_set_header` inheritance. When a `location` block sets any
`proxy_set_header` directive, it **cancels all server-level** `proxy_set_header` directives for that
location. The result is that `x-proxy-user` and `x-proxy-roles` are stripped, the indexer sees a
null user, and it clears the auth cookie (`Max-Age=0`).

Fix: ensure all identity headers are inside `location /`, not at the `server` block level.

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
