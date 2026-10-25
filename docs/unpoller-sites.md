# Unpoller sites

Each UniFi controller gets its own Unpoller container, so a controller that is
unreachable or rejects the login only blanks its own site's metrics.

Until 2026-10 one Unpoller process polled both controllers. A failed poll of
either one fails the whole collection (`metric fetch failed ... error
initializing inputs`) and Unpoller answers the scrape with an error, so when
Sakamoto's controller went unreachable on 2026-09-30 06:39 PDT, Lafayette's
metrics disappeared with it until 10-18.

Everything is driven by one list, `unpoller_sites` in
[`group_vars/all/vars.yml`](../ansible/group_vars/all/vars.yml):

| Per entry | Generated on the SIEM host |
|---|---|
| Compose service + container | `unpoller-<name>` in `docker-compose.lgtm.yml`, sharing the `x-unpoller` anchor |
| Unpoller config | `/opt/siem/config/unpoller/<name>.conf` (0600, holds the credentials) |
| Prometheus target | `/opt/siem/config/prometheus-targets/unpoller/<name>.yml` → `unpoller-<name>:9130`, label `site=<site>` |
| Alerting | nothing — the `unpoller-watchdog` rules group by `site` / `container_name` |

`prometheus.yml` reads the target directory through `file_sd_configs`, so it is
never edited per site.

---

## Current sites

| `name` | Container | `site` label | Controller | Credentials (Infisical) | URL (`.env`) |
|---|---|---|---|---|---|
| `laf` | `unpoller-laf` | `lafayette` | UCG-Fiber (local LAN) | `UNIFI_USERNAME_SITE1` / `UNIFI_PASSWORD_SITE1` | `UNIFI_CONTROLLER_URL_SITE1` |
| `sak` | `unpoller-sak` | `sakamoto` | UDM-SE (via Tailscale) | `UNIFI_USERNAME_SITE2` / `UNIFI_PASSWORD_SITE2` | `UNIFI_CONTROLLER_URL_SITE2` |

The `SITE1`/`SITE2` key names predate the list and are kept so Infisical needs
no migration. New sites use their own name (`UNIFI_USERNAME_USNEW`, …).

### Ports

Every container listens on `unpoller_port` (9130). Nothing is published on the
host: Prometheus reaches each one by container name on the `lgtm` network, so
the containers cannot collide and there is no port table to keep in sync. If a
site ever needs a host port for debugging, publish it on that one service and
record it here.

### `site` label values

Use the value Loki already uses for that location (`{job="unifi"}` syslog,
`loki_push_clients`) — `lafayette`, `sakamoto`. One `$site` then filters logs
and metrics alike. `name` is only the short ID in container and file names.

---

## Adding a site

Example: `usnew`.

1. **Read-only user on the controller** — Settings → Admins → Add Admin → Role:
   Read Only (UnifiOS). Older CloudKey / software controllers use port 8443.
2. **Credentials → Infisical** (prod): `UNIFI_USERNAME_USNEW`,
   `UNIFI_PASSWORD_USNEW`. Add both keys, blank, to
   [`infisical-secrets.template.env`](../infisical-secrets.template.env) so
   `make _infisical-check` enforces them.
3. **URL → `.env`** of the main checkout: `UNIFI_CONTROLLER_URL_USNEW=https://10.x.x.x:443`
   (and a placeholder line in `.env.example`).
4. **Entry → `unpoller_sites`**:

   ```yaml
     - name: usnew
       site: <same value as that site's Loki label>
       url: "{{ lookup('env', 'UNIFI_CONTROLLER_URL_USNEW') }}"
       user: "{{ lookup('env', 'UNIFI_USERNAME_USNEW') }}"
       pass: "{{ lookup('env', 'UNIFI_PASSWORD_USNEW') }}"
   ```

5. **Reachability** — the controller must be routable from the SIEM host
   (`ip route get <controller-ip>` on the SIEM host; see [Reachability](#reachability)).
6. `make check`, then `make deploy-siem`, from the main checkout (never a
   worktree — it has no `.env`).
7. [Verify](#verifying).

Re-running the deploy is idempotent: the list is rendered, not appended to, so a
site cannot be added twice. An empty list, a duplicate `name`, a `name` outside
`[a-z0-9]+`, a `site` outside `[A-Za-z0-9_-]+`, or an empty `url`/`user`/`pass`
(a missing `.env` or Infisical key) stops the lgtm role before it writes
anything. The error names the bad entries, never their values.

The deploy recreates the LGTM containers (the existing `Restart LGTM stack`
handler), so Grafana, Loki and Prometheus restart once.

## Removing a site

1. Delete its entry from `unpoller_sites`.
2. `make deploy-siem`. The deploy deletes `unpoller/<name>.conf`, the target
   file, and the `unpoller-<name>` container.
3. Remove its keys from `infisical-secrets.template.env`, `.env` and
   `.env.example`, then from Infisical.

Container removal is explicit (`docker rm -f` of `unpoller*` containers not in
the list), **not** `docker compose up --remove-orphans`. The LGTM, Infisical
and Wazuh compose files all live in `/opt/siem/config` and therefore share the
compose project `config`; `--remove-orphans` on one file deletes the other
two's containers.

Expect one ntfy "Container Down … die (exit 137)" push for the removed
container — `docker rm -f` kills it, and docker-event-notifier reports every
non-zero exit. The first deploy of this layout sends one for the legacy
`unpoller` container.

Its series stay in Prometheus until retention (30d) drops them. The Prometheus
alerts stop at the next evaluation, since they only see registered targets; a
firing `unpoller-fetch-failing` resolves within ~10 min, when its log lines age
out of the window.

---

## Verifying

```bash
ssh <user>@<siem-host>

# Containers and their last polls
sudo docker ps --filter name=unpoller --format '{{.Names}}\t{{.Status}}'
sudo docker logs --tail 3 unpoller-laf

# Targets Prometheus discovered, with site and health
curl -s localhost:9090/api/v1/targets?state=active \
  | jq -r '.data.activeTargets[] | select(.labels.job=="unpoller") | [.labels.site, .labels.instance, .health, .lastError] | @tsv'

# Device count per site — every site should be non-zero
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=count by (site) (unifi_device_uptime_seconds)' | jq -r '.data.result[] | "\(.metric.site) \(.value[1])"'
```

## Alerts

Group `unpoller-watchdog` (Grafana folder Homelab), labelled `notify=ntfy`, so
they go to ntfy as well as email/Discord, one push per site:

| uid | Fires when | For |
|---|---|---|
| `unpoller-fetch-failing` | `unpoller-<name>` logs `metric fetch failed` more than 3× in 10 min (Loki) | 5m |
| `unpoller-scrape-down` | `up{job="unpoller"} == 0` for a site, or no unpoller target exists at all | 5m |
| `unpoller-data-missing` | a site has a target but no `unifi_device_uptime_seconds` for 5 min | 15m |

A controller that has never accepted a login (new site with a wrong URL or
user) never gets as far as polling: unpoller does not open `:9130` until its
first login succeeds, so the scrape is refused and only `unpoller-scrape-down` /
`unpoller-data-missing` fire — `unpoller-fetch-failing` needs a poll to fail.

Thresholds and why they are what they are: comments in
[`grafana-alerting-rules.yaml.j2`](../ansible/roles/lgtm/templates/grafana-alerting-rules.yaml.j2).

---

## Reachability

As of 2026-10-25 the SIEM host reaches Sakamoto's LAN only over Tailscale:

- `sak2` is the sole subnet router advertising Sakamoto's three /24s; the SIEM
  host accepts routes (`RouteAll: true`), which puts them in table 52, ahead of
  the main table.
- The SIEM host ↔ sak2 path is relayed through DERP (Tokyo), ~135 ms RTT; no direct
  connection is established.
- The UniFi site-to-site WireGuard path (main table, via the UCG-Fiber) no
  longer answers — it is the path that failed on 2026-09-30.

So `unpoller-sak` depends on sak2 being up. A sak2 outage shows up as
`unpoller-scrape-down` / `unpoller-fetch-failing` for `site="sakamoto"` only.

### Lafayette subnet routers must not accept their own LAN's route

laf3 and laf2 both advertise the Lafayette /24s (HA pair; laf3 is primary).
A node that advertises a subnet **and** accepts routes installs the peer's
advertisement of that same subnet in table 52, ahead of `main` — so it sends
replies to its own LAN neighbours into `tailscale0`, and LAN traffic between the
two breaks. Until 2026-10-25 laf2 had `--accept-routes` on: every laf3 → laf2
LAN connection (docker-event-notifier → primary ntfy, Grafana → ntfy) timed out,
and container alerts reached the phone only through the ntfy.sh fallback.

laf2 now runs `--accept-routes=false`. laf3 keeps it on, since it needs
Sakamoto's routes for `unpoller-sak`. That is safe only while laf3 is the
*primary* router for the Lafayette /24s — a node is never sent its own
prefixes from a standby. **Latent risk:** primaries are sticky, so if laf3's
tailscaled restarts while laf2 is up, laf2 can take over as primary, and laf3
then installs laf2's copy of `10.77.3.0/24` and loses its own LAN the same way.
Unresolved; the clean fix is for laf2 to stop advertising the Lafayette /24s
(giving up HA), since Tailscale cannot accept routes per prefix.

Check from either host:

```bash
ip route get <other-host-LAN-IP>    # must say dev eth0, not dev tailscale0
```
