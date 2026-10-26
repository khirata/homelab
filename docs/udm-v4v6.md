# UDM-SE WAN traffic by IPv4 / IPv6

Unpoller reads WAN traffic through the UniFi API, which has no IP-family
split. To fill that gap, the SIEM server (laf3) reads the Sakamoto UDM-SE's
kernel counters over SSH every minute and leaves them for Alloy's textfile
collector:

```
laf3: udm_v4v6.timer ──ssh (Tailscale → sak2 subnet route, SNAT)──▶ UDM-SE 10.77.11.1
  │                                                        forced command prints counters
  ▼
/var/lib/node_exporter/textfile_collector/udm_v4v6.prom
  ──▶ Alloy prometheus.exporter.unix (job="node") ──remote write──▶ Prometheus ──▶ Grafana
```

Nothing is installed on the UDM — UniFi OS updates would wipe it. Its only
change is one restricted line in `/root/.ssh/authorized_keys`. No port is
opened anywhere: laf3 pulls, the same way `unpoller-sak` reaches Sakamoto.

| Piece | Where |
|---|---|
| Script, env file, systemd units | `ansible/roles/udm_v4v6/` → laf3 `/usr/local/bin/udm_v4v6.sh`, `/etc/default/udm_v4v6`, `udm_v4v6.{service,timer}` |
| Settings | `ansible/group_vars/siem_server/vars.yml` (`udm_v4v6_*`) |
| Output | `udm_v4v6.prom` in the textfile directory of `alloy-server.alloy.j2` |
| Dashboard | **UDM WAN IPv4 / IPv6** (`ansible/roles/lgtm/files/dashboards/udm-wan-v4v6.json`) |
| Alert | `udm-v4v6-stale` in `grafana-alerting-rules.yaml.j2` (ntfy + default channels) |

**Dependency:** the path to the UDM is sak2's Tailscale subnet route
(laf3 accepts routes). sak2 SNATs, so the UDM sees laf3's connection from
sak2's own LAN address — that is what the key's `from=` lists. If sak2 is
down, this alerts together with `unpoller-sak`.

## Metrics

| Metric | Labels | |
|---|---|---|
| `udm_wan_bytes_total` | `family` = `ipv4`/`ipv6`, `direction` = `rx`/`tx`, `site` | counter |
| `udm_v4v6_info` | `mode`, `wan_if`, `tunnel_if`, `site` | always 1 |
| `udm_v4v6_last_success_timestamp_seconds` | `site` | Unix time of the last successful run |

All also carry `job="node"` and `instance="laf3"` from Alloy. On a failed run
the file is left as it was, so the counters stay flat and only the timestamp
ages.

How each mode derives the two families (all on the UDM's WAN interface):

| `udm_v4v6_mode` | IPv6 | IPv4 |
|---|---|---|
| `native` (today) | `Ip6{In,Out}Octets` from `/proc/net/dev_snmp6/<wan_if>` | `{rx,tx}_bytes` of `<wan_if>` − IPv6 |
| `pppoe` | same, on `ppp_if` (default `ppp0`) | same, on `ppp_if` |
| `mape` | `Ip6{In,Out}Octets` of `<wan_if>` − IPv4 | `{rx,tx}_bytes` of the MAP-E tunnel (`ip6tnl*`) |

Accuracy: the derived family absorbs whatever the two counters disagree on.
In `native`, `{rx,tx}_bytes` count every Ethernet frame on the wire while
`Ip6*Octets` count IPv6 packets after GRO / before GSO — one set of headers per
merged super-packet. So IPv4 also receives the L2 header of every frame and
the L3/L4 headers of merged IPv6 segments: a few percent of IPv6 bulk
traffic. `ppp0` counts PPP payload only, so in `pppoe` only the GRO/GSO part
remains. In `mape` the 40-byte outer IPv6 header of each tunnelled packet stays
in IPv6. See [Verifying the split](#verifying-the-split) for a measurement.

The exported counters are the script's own accumulators, advanced each minute by
the deltas of the raw counters, never raw `total − IPv6`:

- The two raw counters are read milliseconds apart, so `total − IPv6` can
  step back a few KB. Prometheus would read that as a counter reset and count
  the whole value (a spike of hundreds of GB); the negative remainder is
  carried to the next minute instead.
- Raw counters can reset independently (UDM reboot, MAP-E tunnel recreated on
  a reconnect). A counter that went backwards contributes its new value, so
  the other family does not jump.
- A different mode or interface restarts the deltas; the exported counters
  carry on. Lost state restarts them at 0, which `rate()` handles.
- If one family outgrows the link total by more than 256 MiB, the interfaces
  do not match the mode: the script fails (and so alerts) instead of writing.

State: `/var/lib/udm_v4v6/last` on laf3. The service runs as the system user
`udm-v4v6` (not `DynamicUser`: laf3's nsswitch has no `libnss-systemd`, and ssh
refuses to run under a UID without a passwd entry). It can write only its
state directory and, through an ACL, the textfile directory; it writes
`.udm_v4v6.prom.tmp` and renames it, so Alloy never reads a partial file.

## Line changes

Edit `udm_v4v6_*` in `ansible/group_vars/siem_server/vars.yml`, then `make deploy-udm-v4v6`.
The UDM key needs no change: its forced command prints every interface.

| Change | Set |
|---|---|
| eo光, PPPoE on the UDM | `udm_v4v6_mode: pppoe` (and `udm_v4v6_ppp_if` if the UDM names it other than `ppp0`). If IPv6 arrives over IPoE on the physical port rather than inside PPPoE, the PPP interface carries IPv4 only — check `ip -br addr` on the UDM and adjust |
| MAP-E terminated on the UDM | `udm_v4v6_mode: mape`; `udm_v4v6_wan_if` stays the physical port. Tunnel is auto-detected as the single `ip6tnl*` that is not `ip6tnl0`; set `udm_v4v6_tunnel_if` if there are several |
| Different WAN port (e.g. WAN2 = `eth8`) | `udm_v4v6_wan_if` |
| sak2 gets a new LAN address | `udm_v4v6_from` and the `from=` in the UDM's authorized_keys line |
| Another Sakamoto subnet router | add its LAN address to both `from=` lists — whichever router carries the route SNATs to its own address |

Confirm with the dashboard's **Mode** panel or `journalctl -u udm_v4v6 -n 5`
on laf3. The exported counters carry on across a mode change.

## Setup (once, or after the UDM lost the key)

1. `make deploy-udm-v4v6`. The first run creates `/etc/udm_v4v6/id_ed25519` on
   laf3, prints the authorized_keys line, and stops at "known_hosts is
   missing" if the UDM's host key is not pinned yet.
2. Pin the host key after comparing fingerprints with what a trusted session
   to the UDM shows (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` there):
   ```bash
   ssh laf3 'ssh-keyscan -t ed25519 10.77.11.1 | sudo tee /etc/udm_v4v6/known_hosts && sudo ssh-keygen -lf /etc/udm_v4v6/known_hosts'
   ```
3. Append the printed line to `/root/.ssh/authorized_keys` on the UDM. It has
   the form below; `restrict` drops PTY/forwarding and the forced command
   ignores whatever the client asks to run.
   ```
   restrict,from="10.77.12.181,10.77.12.182",command="cd /sys/class/net && grep -H . */statistics/rx_bytes */statistics/tx_bytes; cd /proc/net/dev_snmp6 && grep -HE '^Ip6(In|Out)Octets' *" ssh-ed25519 AAAA… udm_v4v6@laf3
   ```
4. `make deploy-udm-v4v6` again (or `sudo systemctl start udm_v4v6` on laf3).

## Troubleshooting

`udm-v4v6-stale` fires when `udm_v4v6_last_success_timestamp_seconds` is over
5 min old, or when the series is missing altogether.

```bash
ssh laf3 'journalctl -u udm_v4v6 -n 20 --no-pager'
```

| Log line | Cause |
|---|---|
| `ssh root@10.77.11.1 failed (exit 255): … Permission denied` | The UDM's authorized_keys lost the line (UniFi OS update/restore). Setup step 3 |
| `… REMOTE HOST IDENTIFICATION HAS CHANGED` / `Host key verification failed` | UDM was reset or replaced. Re-pin (setup step 2) only after confirming why |
| `no Ip6InOctets for interface …` | `udm_v4v6_wan_if` / mode does not match the UDM's interfaces |
| `rx: ipv6 bytes exceed the link total by …` | Same: the measured family outgrows the interface it is subtracted from |
| `ssh … failed (exit 255): … Connection timed out` / `No route to host` | sak2 (the subnet router) or Tailscale is down — `unpoller-sak` alerts too |
| `ssh … failed (exit 255): … Permission denied` right after a Sakamoto network change | the UDM sees a source not in `from=` (e.g. a new subnet router carries the route) |
| `cannot write …/.udm_v4v6.prom.tmp` | the textfile directory lost its ACL (recreated?) — re-run `make deploy-udm-v4v6` |

## Verifying the split

Compare a packet capture on the UDM's WAN with the metrics over the same
window. Read-only; run from a host that can SSH to the UDM as root. The awk
runs on the UDM so only the totals cross the network; the MAC is eth9's
(`ip -br link show eth9`), which tells tx from rx.

```bash
ssh root@10.77.11.1 'timeout 600 tcpdump -i eth9 -nn -q -e 2>/dev/null | awk -v mac=0c:ea:14:c6:34:2a "{ d = (\$2 == mac) ? \"tx\" : \"rx\"; f = \$5; sub(/,/, \"\", f); n = \$7; sub(/:/, \"\", n); b[f \" \" d] += n } END { for (k in b) print k, b[k] }"'
```

Frame lengths include the 14-byte Ethernet header, as `{rx,tx}_bytes` do. Then
query Prometheus for the same 10 minutes (samples land once a minute, so align
the window to the capture within a minute):

```
sum by (direction) (increase(udm_wan_bytes_total{site="sakamoto", family="ipv4"}[10m]))
  / sum by (direction) (increase(udm_wan_bytes_total{site="sakamoto"}[10m]))
```
