# ntfy Crash Alerts

ntfy provides push notifications for service crashes **independent of Grafana** — alerts fire
even when the monitoring stack itself is down.

---

## Architecture

```
All managed hosts
  systemd OnFailure= → notify-ntfy@.service → /usr/local/bin/ntfy-notify.sh
                                                        │
                                    active/passive failover (no duplicates)
                                                        │
                              ┌─────────────────────────┴────────────────────────┐
                              │                                                   │
                    1st try (3 s timeout)                           fallback (5 s timeout)
                    $NTFY_SERVER_HOST:2586/$NTFY_TOPIC          ntfy.sh/$NTFY_CLOUD_TOPIC
                    (self-hosted, LAN)                           (cloud free tier)
                              │                                                   │
                              └─────────────────────────┬────────────────────────┘
                                                        │
                                              phone / client app
                                         (subscribed to both topics)

siem_server only
  docker-event-notifier.service → watches `docker events --filter event=die/oom`
                                → same ntfy-notify pipeline above
```

**Active/passive:** the script exits after the first successful delivery, so you receive exactly
one notification per event. The ntfy.sh topic fires only when the primary server is unreachable.

---

## What triggers an alert

| Service | Host | Trigger |
|---------|------|---------|
| `postgresql@16-main` | postgresql_server | systemd `OnFailure=` |
| `redis-server` | redis_server | systemd `OnFailure=` |
| `alloy` | all hosts | systemd `OnFailure=` |
| `wazuh-manager` | siem_server | systemd `OnFailure=` |
| `docker` daemon | siem_server | systemd `OnFailure=` |
| Grafana, Loki, Prometheus, Infisical, Unpoller | siem_server | Docker event notifier |

---

## Configuration

All vars are optional — omit `NTFY_TOKEN` to skip auth on the primary server,
omit `NTFY_CLOUD_TOPIC` to disable the cloud fallback.

| Env var | Default | Description |
|---------|---------|-------------|
| `NTFY_TOPIC` | `homelab` | Topic name on the self-hosted server |
| `NTFY_TOKEN` | _(empty)_ | Access token for the self-hosted ntfy server |
| `NTFY_CLOUD_TOPIC` | _(empty)_ | Topic on ntfy.sh (use a random suffix — see below) |

Set these in `.env` before running the playbook.

---

## Deployment

### 1. Deploy the ntfy server

```bash
make deploy LIMIT=ntfy_servers
# or
ansible-playbook ansible/site.yml --limit ntfy_servers
```

### 2. Bootstrap user and token (run once on the ntfy server)

```bash
# Create admin user (enter a password when prompted)
ssh <user>@<ntfy-server> sudo ntfy user add --role=admin admin

# Create a non-expiring access token
ssh <user>@<ntfy-server> sudo ntfy token add --expires=0 admin
# → prints:  token: tk_xxxxxxxxxxxxxxxxxxxx
```

Copy the printed token into `.env`:

```bash
NTFY_TOKEN=tk_xxxxxxxxxxxxxxxxxxxx
```

### 3. Set up the ntfy.sh cloud fallback topic

ntfy.sh topics are public — **anyone who knows the topic URL can read it**.
Use a random suffix to keep it private:

```bash
# Generate a random suffix
openssl rand -hex 4   # e.g. f3k9xp2m
```

Set in `.env`:

```bash
NTFY_CLOUD_TOPIC=homelab-f3k9xp2m
```

> Subscribe to `https://ntfy.sh/homelab-f3k9xp2m` in the client app.
> No account or token required for subscribing or publishing on the free tier.

### 4. Deploy all hosts

```bash
make deploy
```

This deploys `ntfy_client` to every managed host (notify script, systemd template unit,
OnFailure drop-ins) and starts `docker-event-notifier` on the SIEM server.

---

## Client setup (phone / desktop)

Install the **ntfy** app:

- **iOS**: [App Store](https://apps.apple.com/app/ntfy/id1625396347)
- **Android**: [Google Play](https://play.google.com/store/apps/details?id=io.heckel.ntfy) or [F-Droid](https://f-droid.org/en/packages/io.heckel.ntfy/)

### Subscribe to the self-hosted server (primary)

1. Open the app → **+** → **Subscribe to topic**
2. Set server: `http://<ntfy-server>:2586`
3. Topic: `homelab` (your `NTFY_TOPIC` value)
4. **Authentication**: enter `admin` and the password you set during bootstrap

> For access outside your LAN, expose the ntfy server via a Cloudflare Tunnel or VPN first.

### Subscribe to ntfy.sh (cloud fallback)

1. Open the app → **+** → **Subscribe to topic**
2. Leave server as `https://ntfy.sh` (default)
3. Topic: `homelab-f3k9xp2m` (your `NTFY_CLOUD_TOPIC` value)
4. No authentication required

With both subscriptions active, you receive one alert per event under normal conditions
(primary server delivers it). If the primary is unreachable, ntfy.sh delivers instead.

---

## Upgrading

ntfy is installed via APT. To upgrade:

```bash
ansible-playbook ansible/site.yml --limit ntfy_servers
```

To upgrade manually on the ntfy server:

```bash
ssh <user>@<ntfy-server> sudo apt update && sudo apt install --only-upgrade ntfy
```

---

## Operations

```bash
# Status
ssh <user>@<ntfy-server> sudo systemctl status ntfy

# Logs
ssh <user>@<ntfy-server> sudo journalctl -u ntfy -f

# List users / tokens
ssh <user>@<ntfy-server> sudo ntfy user list
ssh <user>@<ntfy-server> sudo ntfy token list

# Rotate token (generate new, update .env, redeploy)
ssh <user>@<ntfy-server> sudo ntfy token add --expires=0 admin
# update NTFY_TOKEN in .env
make deploy
```

---

## Verification

```bash
# Check ntfy server health
curl http://<ntfy-server>:2586/v1/health

# Send a test notification from siem_server
ssh <user>@<siem-host> bash -c '
  source /etc/ntfy-client.env
  curl -sf \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: Test" \
    --data "ntfy test from $(hostname)" \
    http://<ntfy-server>:2586/homelab
'

# Test systemd OnFailure & Recovery Monitor (redis example)
# Note: systemctl stop is a graceful shutdown and will NOT trigger an alert.
# We must forcefully kill the process to simulate a crash.
ssh <user>@<redis-host> sudo kill -9 \$(pidof redis-server)
# → "Service Down" notification should arrive within seconds.
# (If Redis is configured to Restart=always, systemd will restart it immediately).
# → "Service Up" recovery notification should arrive within ~10 seconds.

# Test Docker event notifier & Healthchecks
# Note: The "Up" alert only fires when the container becomes fully healthy.
ssh <user>@<siem-host> sudo docker kill grafana
# → "Container Down" notification should arrive within seconds.
ssh <user>@<siem-host> sudo docker start grafana
# → Wait ~15 seconds for Grafana to pass its healthcheck.
# → "Container Up" recovery notification should arrive.

# Verify docker-event-notifier service
ssh <user>@<siem-host> sudo systemctl status docker-event-notifier
```
