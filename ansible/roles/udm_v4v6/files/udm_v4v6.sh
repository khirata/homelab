#!/usr/bin/env bash
# Managed by Ansible — do not edit manually.
# Source: roles/udm_v4v6/files/udm_v4v6.sh
#
# Reads the UDM-SE's WAN byte counters over SSH (read-only — nothing is
# installed on the UDM, firmware updates would wipe it) and writes them for
# Alloy's textfile collector as
# udm_wan_bytes_total{family="ipv4|ipv6", direction="rx|tx", site="…"}.
#
# The UDM side is a forced command in /root/.ssh/authorized_keys that prints
# every interface's counters, so this key can read counters and nothing else:
#   <if>/statistics/rx_bytes:<n>    from /sys/class/net
#   <if>:Ip6InOctets <n>            from /proc/net/dev_snmp6
# Whatever command this script asks for is ignored by the UDM.
#
# Modes (UDM_MODE):
#   native  IPv6 = Ip6{In,Out}Octets of UDM_WAN_IF
#           IPv4 = {rx,tx}_bytes of UDM_WAN_IF − IPv6
#   pppoe   same as native on UDM_PPP_IF (default ppp0)
#   mape    IPv4 = {rx,tx}_bytes of the MAP-E tunnel (UDM_TUNNEL_IF, or the
#           only ip6tnl* other than the ip6tnl0 fallback device)
#           IPv6 = Ip6{In,Out}Octets of UDM_WAN_IF − IPv4
#
# Accuracy: the derived family absorbs whatever the two counters disagree on.
#   native  {rx,tx}_bytes count every Ethernet frame on the wire; Ip6*Octets
#           count IPv6 packets after GRO/before GSO, i.e. one set of headers
#           per merged super-packet. IPv4 therefore also gets the L2 header of
#           every frame and the L3/L4 headers of merged IPv6 segments — a few
#           percent of IPv6 bulk traffic. Measured: docs/udm-v4v6.md.
#   pppoe   ppp0 counts PPP payload only (no Ethernet/PPPoE header), so only
#           the GRO/GSO effect remains.
#   mape    the 40-byte outer IPv6 header of each tunnelled packet stays in
#           the IPv6 figure.
#
# On any failure (SSH, parse, write) this exits non-zero and leaves the last
# .prom file in place. Alloy keeps exporting those old values, so staleness is
# told by udm_v4v6_last_success_timestamp_seconds: the Grafana udm-v4v6-stale
# alert fires once it is over 5 minutes old.
set -euo pipefail

: "${UDM_HOST:?UDM_HOST is not set (see /etc/default/udm_v4v6)}"
: "${TEXTFILE_DIR:?TEXTFILE_DIR is not set (see /etc/default/udm_v4v6)}"
UDM_USER=${UDM_USER:-root}
UDM_MODE=${UDM_MODE:-native}
UDM_WAN_IF=${UDM_WAN_IF:-}
UDM_PPP_IF=${UDM_PPP_IF:-ppp0}
UDM_TUNNEL_IF=${UDM_TUNNEL_IF:-}
UDM_KNOWN_HOSTS=${UDM_KNOWN_HOSTS:-/etc/udm_v4v6/known_hosts}
# systemd hands the key over via LoadCredential=; manual runs (as root) read it
# from /etc directly.
if [[ -n ${CREDENTIALS_DIRECTORY:-} ]]; then
  UDM_SSH_KEY=${UDM_SSH_KEY:-$CREDENTIALS_DIRECTORY/udm_key}
else
  UDM_SSH_KEY=${UDM_SSH_KEY:-/etc/udm_v4v6/id_ed25519}
fi
UDM_SITE=${UDM_SITE:-sakamoto}
PROM_FILE=$TEXTFILE_DIR/udm_v4v6.prom
STATE_FILE=${STATE_DIRECTORY:-/var/lib/udm_v4v6}/last

die() { echo "udm_v4v6: $*" >&2; exit 1; }

fetch_counters() {
  local out err rc=0
  err=$(mktemp)
  out=$(timeout 30 ssh -n -F /dev/null -i "$UDM_SSH_KEY" \
      -o IdentitiesOnly=yes -o BatchMode=yes \
      -o UserKnownHostsFile="$UDM_KNOWN_HOSTS" -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o LogLevel=ERROR \
      "$UDM_USER@$UDM_HOST" counters 2>"$err") || rc=$?
  if (( rc != 0 )); then
    echo "udm_v4v6: ssh $UDM_USER@$UDM_HOST failed (exit $rc): $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  # Normalise both formats to "<if> <counter> <value>".
  sed -nE \
    -e 's#^([^/: ]+)/statistics/([a-z_]+):([0-9]+)$#\1 \2 \3#p' \
    -e 's#^([^/: ]+):(Ip6[A-Za-z]+)[[:space:]]+([0-9]+)$#\1 \2 \3#p' <<<"$out"
}

# counter <if> <name> — prints the value, fails when the UDM did not report it.
counter() {
  awk -v i="$1" -v k="$2" '$1 == i && $2 == k { print $3; found = 1 } END { exit !found }' <<<"$COUNTERS" \
    || die "no $2 for interface $1 in the UDM's output — wrong UDM_WAN_IF/UDM_TUNNEL_IF or mode?"
}

COUNTERS=$(fetch_counters) || exit 1
[[ -n $COUNTERS ]] || die "UDM returned no counters — is the forced command in authorized_keys intact?"

# Per direction, two raw counters from the UDM: T, everything on the link, and
# K, one family measured directly. The other family is T − K.
#   native/pppoe  T = {rx,tx}_bytes        K = Ip6*Octets   (K is IPv6)
#   mape          T = Ip6*Octets of WAN    K = tunnel bytes (K is IPv4)
declare -A T=() K=()
case $UDM_MODE in
  native|pppoe)
    if [[ $UDM_MODE == pppoe ]]; then wan=$UDM_PPP_IF; else wan=$UDM_WAN_IF; fi
    [[ -n $wan ]] || die "UDM_WAN_IF is not set"
    T[rx]=$(counter "$wan" rx_bytes);     T[tx]=$(counter "$wan" tx_bytes)
    K[rx]=$(counter "$wan" Ip6InOctets);  K[tx]=$(counter "$wan" Ip6OutOctets)
    known=ipv6 other=ipv4
    ;;
  mape)
    wan=$UDM_WAN_IF
    [[ -n $wan ]] || die "UDM_WAN_IF is not set"
    tnl=$UDM_TUNNEL_IF
    if [[ -z $tnl ]]; then
      mapfile -t tnls < <(awk '$1 ~ /^ip6tnl/ && $1 != "ip6tnl0" && $2 == "rx_bytes" { print $1 }' <<<"$COUNTERS")
      (( ${#tnls[@]} == 1 )) || die "found ${#tnls[@]} MAP-E tunnels (${tnls[*]:-none}); set UDM_TUNNEL_IF"
      tnl=${tnls[0]}
    fi
    T[rx]=$(counter "$wan" Ip6InOctets);  T[tx]=$(counter "$wan" Ip6OutOctets)
    K[rx]=$(counter "$tnl" rx_bytes);     K[tx]=$(counter "$tnl" tx_bytes)
    known=ipv4 other=ipv6
    ;;
  *) die "unknown UDM_MODE '$UDM_MODE' (native | mape | pppoe)" ;;
esac
src="$UDM_MODE:$wan:${tnl:-}"

# The pushed counters are our own accumulators, advanced by each run's deltas
# of T and K — never T − K directly:
#  - T and K are read milliseconds apart, so T − K can step back a few KB.
#    Prometheus reads any decrease as a counter reset and rate() would count
#    the whole value, a spike of hundreds of GB. A negative remainder is
#    carried into the next run instead of being pushed.
#  - T and K can reset independently (UDM reboot, tunnel recreated on a
#    reconnect). A counter that went backwards contributes its new value — the
#    bytes since its reset — so the other family does not jump.
#  - A different mode or interface (src) restarts the deltas; the pushed
#    counters carry on.
# Missing state starts the counters at 0, which Prometheus treats as a reset
# without a spike.
# A carry beyond CARRY_LIMIT is not timing jitter: K outgrows T, so the
# interfaces do not match the mode. Fail (and so alert) rather than push
# a flat zero forever.
CARRY_LIMIT=$(( 256 * 1024 * 1024 ))
declare -A last=()
if [[ -r $STATE_FILE ]]; then
  while read -r k v; do
    if [[ $k == src || $v =~ ^-?[0-9]+$ ]]; then last[$k]=$v; fi
  done <"$STATE_FILE"
fi
same_src=0
if [[ ${last[src]:-} == "$src" ]]; then same_src=1; fi

declare -A save=([src]=$src) out=()
for d in rx tx; do
  dt=0 dk=0
  if (( same_src )) && [[ -n ${last[T_$d]:-} && -n ${last[K_$d]:-} ]]; then
    if (( T[$d] >= last[T_$d] )); then dt=$(( T[$d] - last[T_$d] )); else dt=${T[$d]}; fi
    if (( K[$d] >= last[K_$d] )); then dk=$(( K[$d] - last[K_$d] )); else dk=${K[$d]}; fi
  fi
  carry=$(( dt - dk + ${last[carry_$d]:-0} ))
  dother=0
  if (( carry >= 0 )); then dother=$carry; carry=0; fi
  (( carry >= -CARRY_LIMIT )) \
    || die "$d: $known bytes exceed the link total by $(( -carry )) B — UDM_MODE=$UDM_MODE does not match UDM_WAN_IF=$wan${tnl:+/UDM_TUNNEL_IF=$tnl}"
  out[${known}_$d]=$(( ${last[${known}_$d]:-0} + dk ))
  out[${other}_$d]=$(( ${last[${other}_$d]:-0} + dother ))
  save+=([T_$d]=${T[$d]} [K_$d]=${K[$d]} [carry_$d]=$carry)
done

# No timestamps in the file: the textfile collector rejects them.
lbl="site=\"$UDM_SITE\""
body=$(cat <<EOF
# HELP udm_wan_bytes_total UDM-SE WAN bytes by IP family (one family is derived, see udm_v4v6.sh).
# TYPE udm_wan_bytes_total counter
udm_wan_bytes_total{$lbl,family="ipv4",direction="rx"} ${out[ipv4_rx]}
udm_wan_bytes_total{$lbl,family="ipv4",direction="tx"} ${out[ipv4_tx]}
udm_wan_bytes_total{$lbl,family="ipv6",direction="rx"} ${out[ipv6_rx]}
udm_wan_bytes_total{$lbl,family="ipv6",direction="tx"} ${out[ipv6_tx]}
# HELP udm_v4v6_info Counter source in use by udm_v4v6.sh.
# TYPE udm_v4v6_info gauge
udm_v4v6_info{$lbl,mode="$UDM_MODE",wan_if="$wan",tunnel_if="${tnl:-}"} 1
# HELP udm_v4v6_last_success_timestamp_seconds When udm_v4v6.sh last read the UDM and wrote this file.
# TYPE udm_v4v6_last_success_timestamp_seconds gauge
udm_v4v6_last_success_timestamp_seconds{$lbl} $(date +%s)
EOF
)

# Written beside the target and renamed, so Alloy never reads a partial file;
# the collector only reads *.prom, so the dot-file is never picked up.
tmp=$TEXTFILE_DIR/.udm_v4v6.prom.tmp
printf '%s\n' "$body" >"$tmp" || die "cannot write $tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$PROM_FILE" || die "cannot rename $tmp to $PROM_FILE"

# Saved only after the file is in place, so the accumulators continue from what
# Alloy has actually exported.
for k in "${!out[@]}"; do save[$k]=${out[$k]}; done
for k in "${!save[@]}"; do echo "$k ${save[$k]}"; done >"$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
