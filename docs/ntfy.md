# ntfy Crash Alerts

ntfy provides push notifications for service crashes **independent of Grafana** — alerts fire
even when the monitoring stack itself is down.

---

## Architecture

```
All managed hosts
  systemd OnFailure= → notify-ntfy@.service → /usr/local/bin/ntfy-send
                                                        │
                                    active/passive failover (no duplicates)
                                                        │
                              ┌─────────────────────────┴────────────────────────┐
                              │                                                   │
                    1st try (3 s timeout)                           fallback (5 s timeout)
                    self-hosted ntfy (LAN)                          ntfy.sh (cloud free tier)
                    url= in /etc/ntfy-client.conf                   cloud_url= in conf
                              │                                                   │
                              └─────────────────────────┬────────────────────────┘
                                                        │
                                              phone / client app
                                         (subscribed to both topics)

siem_server only
  docker-event-notifier.service → watches `docker events --filter event=die/oom`
                                → same ntfy-send pipeline above
```

**Active/passive:** `ntfy-send` exits after the first successful delivery, so you receive exactly
one notification per event. The ntfy.sh topic fires only when the primary server is unreachable.

**Recovery watcher:** when called with `--watch-service`, `ntfy-send` spawns a background
`systemd-run` unit that polls until the service returns to active, then sends a "Service Up"
notification and clears the dedup lock automatically.

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

Set these in `.env` before running the playbook. They populate `/etc/ntfy-client.conf`
on each host (mode `0600`).

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

This deploys `ntfy_client` to every managed host (`ntfy-send`, `ntfy-clear` symlink,
`/etc/ntfy-client.conf`, systemd template unit, OnFailure drop-ins) and starts
`docker-event-notifier` on the SIEM server.

### 5. Rotate the token

```bash
ssh <user>@<ntfy-server> sudo ntfy token add --expires=0 admin
# update NTFY_TOKEN in .env (and in Infisical)
make deploy-ntfy-client   # updates /etc/ntfy-client.conf on all hosts only
```

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

## ntfy-send / ntfy-clear CLI

`/usr/local/bin/ntfy-send` is a general-purpose Python 3 notification CLI installed on
every managed host. `/usr/local/bin/ntfy-clear` is a symlink to the same script; the
action (`send` vs `clear`) is inferred from the name used to invoke it.

### Synopsis

```
ntfy-send [options] --message MSG
ntfy-clear --key KEY [--message MSG]
```

### Options

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--message MSG` | `-m` | _(required for send)_ | Notification body |
| `--title TITLE` | `-t` | `Alert` | Notification title |
| `--priority LEVEL` | `-p` | `default` | `min` / `low` / `default` / `high` / `urgent` or `1`–`5` |
| `--tags TAG …` | | | Space-separated ntfy tags (emoji shortcodes) |
| `--key KEY` | `-k` | | Deduplication key — suppresses duplicate sends until cleared |
| `--threshold N[m]` | | | Fire only after **N** occurrences, or after **Nm** minutes |
| `--force` | `-f` | | Send even when a dedup lock is active |
| `--watch-service UNIT` | | | After sending, auto-clear when UNIT recovers |
| `--host HOST` | | FQDN | Source hostname embedded in the message |
| `--action ACTION` | | _(from argv[0])_ | Override: `send`, `clear`, or `watch-clear` |
| `--verbose` | `-v` | | Debug output to stderr and log file |

### Config file: `/etc/ntfy-client.conf`

```ini
[ntfy]
url       = http://<ntfy-server>:2586/<topic>   # self-hosted primary
cloud_url = https://ntfy.sh/<cloud-topic>        # cloud fallback (optional)
token     = tk_xxxxxxxxxxxxxxxxxxxx              # bearer token (optional)
```

Environment variables `NTFY_URL`, `NTFY_CLOUD_URL`, and `NTFY_TOKEN` are accepted as
fallbacks for each field — useful for one-off CLI use without a config file.

### Deduplication

When `--key` is given, `ntfy-send` creates a lock file under `/var/run/ntfy_lock/`
on first successful delivery. Subsequent calls with the same key are silently skipped
until the lock is cleared.

```
/var/run/ntfy_lock/<md5(key+url)>.lck    # active-alert lock
/var/run/ntfy_lock/<md5(key+url)>.th     # threshold counter (transient)
```

The lock directory is ephemeral (`/var/run`) — it is recreated automatically on reboot,
which clears all dedup state. This is intentional: a reboot is itself a recovery event.

### Threshold gating

`--threshold N` (count) or `--threshold Nm` (minutes) delays the alert until the condition
has persisted long enough to be worth paging about.

```bash
# Alert only after the condition has occurred 3 times
ntfy-send -k disk-alert -m "Disk >90% on $(hostname)" --threshold 3

# Alert only if the condition persists for more than 10 minutes
ntfy-send -k disk-alert -m "Disk >90% on $(hostname)" --threshold 10m
```

The counter resets on successful delivery. A `ntfy-clear` also resets it.

### Recovery watcher (`--watch-service`)

When called with `--watch-service UNIT`, `ntfy-send` spawns a transient
`systemd-run` unit (`ntfy-recovery-<unit>`) immediately after sending the alert.
That unit polls `systemctl is-active` every 5 seconds for up to 10 minutes. When
the service returns to active, it sends a "Service Up" notification and removes
the dedup lock.

The systemd `notify-ntfy@.service` template uses this flag automatically:

```ini
ExecStart=/usr/local/bin/ntfy-send \
  --key "%i" \
  --title "Service Down" \
  --message "Service %i failed on %H" \
  --priority high \
  --tags warning \
  --watch-service "%i"
```

### Usage examples

```bash
# One-shot alert (no dedup)
ntfy-send -m "Backup failed on $(hostname)" -p high --tags warning

# Deduplicated alert — won't repeat until ntfy-clear or reboot
ntfy-send -k httpd -t "Web server down" -m "httpd failed on $(hostname)" -p urgent --tags rotating_light

# Alert only after 3 occurrences (e.g. from a cron check script)
ntfy-send -k disk-alert -m "Disk >90% on $(hostname)" --threshold 3

# Alert only if condition persists more than 10 minutes
ntfy-send -k disk-alert -m "Disk >90% on $(hostname)" --threshold 10m

# Manual recovery: send "up" and clear the lock
ntfy-clear -k httpd -t "Web server up" -m "httpd recovered on $(hostname)"

# Manual recovery: just clear the lock silently (no notification)
ntfy-clear -k httpd

# Force re-send even with an active lock (e.g. escalation)
ntfy-send -k httpd -m "httpd STILL down — escalating" -p urgent --force

# From a monitoring script with self-hosted + cloud failover
NTFY_URL=http://laf2.local:2586/homelab \
NTFY_CLOUD_URL=https://ntfy.sh/homelab-f3k9xp2m \
ntfy-send -k my-check -m "Check failed" -p high
```

---

## Upgrading

ntfy server is installed via APT. To upgrade:

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

# ntfy-send log (on any managed host)
ssh <user>@<host> sudo tail -f /var/log/ntfy-send.log

# List users / tokens
ssh <user>@<ntfy-server> sudo ntfy user list
ssh <user>@<ntfy-server> sudo ntfy token list

# Active dedup locks on a host
ssh <user>@<host> sudo ls -lh /var/run/ntfy_lock/

# Clear all dedup locks (e.g. after maintenance window)
ssh <user>@<host> sudo rm -f /var/run/ntfy_lock/*.lck

# View active recovery watchers
ssh <user>@<host> sudo systemctl list-units 'ntfy-recovery-*'
```

---

## Verification

```bash
# Check ntfy server health
curl http://<ntfy-server>:2586/v1/health

# Send a test notification from any managed host
ssh <user>@<host> sudo ntfy-send -t "Test" -m "ntfy-send test from $(hostname)" -v

# Confirm cloud fallback (bring down primary first, or use a bad URL)
ssh <user>@<host> sudo NTFY_URL=http://127.0.0.1:1 ntfy-send \
  -t "Fallback test" -m "should arrive via ntfy.sh"

# Test systemd OnFailure & Recovery Monitor (redis example)
# Note: systemctl stop is graceful and will NOT trigger OnFailure.
# Kill the process directly to simulate a crash.
ssh <user>@<redis-host> sudo kill -9 $(pidof redis-server)
# → "Service Down" notification arrives within seconds.
# → Redis restarts (Restart=always). Recovery watcher detects it.
# → "Service Up" notification arrives within ~10 seconds.

# Inspect recovery watcher lifecycle
ssh <user>@<redis-host> sudo systemctl status 'ntfy-recovery-redis*'
ssh <user>@<redis-host> sudo journalctl -u 'ntfy-recovery-*' --no-pager

# Test Docker event notifier (siem_server only)
ssh <user>@<siem-host> sudo docker kill grafana
# → "Container Down" notification arrives within seconds.
ssh <user>@<siem-host> sudo docker start grafana
# → Wait ~15 seconds for Grafana to pass its healthcheck.
# → "Container Up" notification arrives.

# Verify docker-event-notifier service
ssh <user>@<siem-host> sudo systemctl status docker-event-notifier
```
