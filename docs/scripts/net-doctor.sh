#!/usr/bin/env bash
#
# net-doctor.sh — find the cause of INTERMITTENT app disconnections on the
# Proxmox stack (tunnel healthy, sites drop in and out).
#
# It answers the question "is this an IP conflict, the network, or the apps?"
# by testing each layer separately and printing which one is actually flapping:
#
#   layer 1  duplicate IP / duplicate MAC on the LAN   <- the classic symptom
#   layer 2  bridge + NIC errors, packet loss to each CT
#   layer 3  app service restarts, OOM kills, DB drops
#   layer 4  nginx error.log classification (tells app-fault from net-fault)
#
# Run on the PROXMOX HOST as root:
#     scp docs/scripts/net-doctor.sh root@192.168.100.10:/root/
#     ssh root@192.168.100.10 'chmod +x /root/net-doctor.sh && /root/net-doctor.sh'
#
# Flags:
#     --watch      loop the IP-conflict + ping probes forever (catch a
#                  conflict that only appears when the rogue device wakes up)
#     --since S    journal window for the app checks (default '24 hours ago')
#
# Read-only. Changes nothing.
#
set -uo pipefail

BRIDGE=vmbr0
SUBNET=192.168.100.0/24
GATEWAY=192.168.100.1
# VMID:label:ip:"systemd units to watch"
CTS=(
  "110:cf-tunnel:192.168.100.49:cloudflared"
  "111:edge-nginx:192.168.100.50:nginx"
  "112:pugweb:192.168.100.51:pugweb-backend pugweb-frontend postgresql redis-server"
  "113:housing:192.168.100.52:housing-backend housing-frontend housing-worker housing-beat postgresql redis-server"
  "114:pugfin:192.168.100.53:pugfin postgresql"
  "115:zeroone:192.168.100.54:zbe zfe postgresql"
  "116:legal:192.168.100.55:pug-backend pug-frontend postgresql"
)
CT_NGINX=111

WATCH=0
SINCE="24 hours ago"
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1 ;;
    --since) SINCE="${2:-24 hours ago}"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\033[1;34m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; X=$'\033[0m'
else B=; G=; Y=; R=; X=; fi
FAILED=0
sec()  { echo; echo "${B}=== $* ===${X}"; }
ok()   { echo "  ${G}[ OK ]${X} $*"; }
warn() { echo "  ${Y}[WARN]${X} $*"; }
bad()  { echo "  ${R}[FAIL]${X} $*"; FAILED=$((FAILED+1)); }
fix()  { echo "         ${Y}fix:${X} $*"; }

inct() { pct exec "$1" -- bash -lc "$2" 2>/dev/null; }
ct_running() { [ "$(pct status "$1" 2>/dev/null)" = "status: running" ]; }

command -v pct >/dev/null || { echo "${R}run this on the Proxmox HOST, not in a container${X}"; exit 2; }
for p in arping arp-scan; do
  command -v $p >/dev/null || warn "$p missing — install for full coverage: apt install -y iputils-arping arp-scan"
done

# ============================================================ LAYER 1: IP conflict
layer1() {
sec "LAYER 1 — duplicate IP / duplicate MAC (the #1 cause of 'random' drops)"

# 1a. Does each managed IP answer with exactly ONE MAC?
#     Two MACs answering one IP == hard conflict. Traffic ping-pongs between
#     the two devices as the ARP cache flips, which looks exactly like
#     "the app disconnects every few minutes".
if command -v arping >/dev/null; then
  for entry in "${CTS[@]}"; do
    IFS=: read -r id label ip _units <<<"$entry"
    pct config "$id" >/dev/null 2>&1 || continue
    macs=$(arping -c 4 -w 3 -I "$BRIDGE" "$ip" 2>/dev/null \
           | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u)
    n=$(printf '%s\n' "$macs" | grep -c . )
    cfgmac=$(pct config "$id" | grep -oiE 'hwaddr=([0-9A-F]{2}:){5}[0-9A-F]{2}' | cut -d= -f2 | tr 'A-Z' 'a-z')
    case "$n" in
      0) warn "$ip ($label) did not answer ARP — CT stopped, or it is genuinely off the wire" ;;
      1) if [ -n "$cfgmac" ] && [ "$macs" != "$cfgmac" ]; then
           bad "$ip ($label) answers from $macs but CT $id is configured as $cfgmac — SOMETHING ELSE OWNS THIS IP"
           fix "find the rogue device and move it, or exclude .49-.55 from the router's DHCP pool"
         else ok "$ip ($label) -> $macs (unique)"; fi ;;
      *) bad "$ip ($label) answered by $n DIFFERENT MACs — CONFIRMED IP CONFLICT:"
         printf '%s\n' "$macs" | sed 's/^/           /'
         fix "one of these is CT $id ($cfgmac); the other is a rogue device on your LAN"
         fix "shrink the router's DHCP pool so it never hands out 192.168.100.49-.55" ;;
    esac
  done
fi

# 1b. Full-subnet sweep — arp-scan flags duplicates explicitly, and shows any
#     stranger sitting inside the static range.
if command -v arp-scan >/dev/null; then
  scan=$(arp-scan --interface="$BRIDGE" --retry=2 "$SUBNET" 2>/dev/null)
  if grep -qi "DUP" <<<"$scan"; then
    bad "arp-scan reports duplicate addresses on $SUBNET:"
    grep -i "DUP" <<<"$scan" | sed 's/^/           /'
  else
    ok "arp-scan found no duplicate addresses on $SUBNET"
  fi
  echo "         devices currently inside the static range .49-.55:"
  awk '/^192\.168\.100\.(49|5[0-5])\b/{print "           "$0}' <<<"$scan"
fi

# 1c. Kernel-level conflict detection — the host and the CTs log this outright.
dup=$(dmesg -T 2>/dev/null | grep -iE "duplicate address|arp.*conflict" | tail -5)
if [ -n "$dup" ]; then
  bad "kernel logged an address conflict on the host:"
  printf '%s\n' "$dup" | sed 's/^/           /'
else
  ok "no duplicate-address messages in the host kernel log"
fi
for entry in "${CTS[@]}"; do
  IFS=: read -r id label ip _u <<<"$entry"
  ct_running "$id" || continue
  d=$(inct "$id" "journalctl --no-pager --since '$SINCE' 2>/dev/null | grep -iE 'duplicate address|arp.*conflict' | tail -3")
  [ -n "$d" ] && { bad "CT $id ($label) logged an address conflict:"; printf '%s\n' "$d" | sed 's/^/           /'; }
done

# 1d. Duplicate MAC across CT configs — happens when a CT is cloned without
#     regenerating the NIC. Two CTs with one MAC = both flap.
macs=$(for entry in "${CTS[@]}"; do
         id="${entry%%:*}"; pct config "$id" 2>/dev/null | grep -oiE 'hwaddr=([0-9A-F]{2}:){5}[0-9A-F]{2}'
       done | cut -d= -f2 | tr 'A-Z' 'a-z' | sort)
dupmac=$(printf '%s\n' "$macs" | uniq -d)
if [ -n "$dupmac" ]; then
  bad "two containers share a MAC address: $dupmac"
  fix "pct set <VMID> --net0 name=eth0,bridge=$BRIDGE,hwaddr=<NEW>,ip=<IP>/24,gw=$GATEWAY"
else
  ok "all container MAC addresses are unique"
fi

# 1e. The gateway itself — a conflicted gateway drops everything at once.
if command -v arping >/dev/null; then
  gmacs=$(arping -c 4 -w 3 -I "$BRIDGE" "$GATEWAY" 2>/dev/null | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u | grep -c .)
  [ "${gmacs:-0}" -gt 1 ] && bad "the GATEWAY $GATEWAY answers from $gmacs MACs — two routers/APs are fighting" \
                          || ok "gateway $GATEWAY is unambiguous"
fi
}

# ======================================================= LAYER 2: link + loss
layer2() {
sec "LAYER 2 — bridge, NIC errors, packet loss"
for i in $(ls /sys/class/net | grep -vE '^(lo|veth|fw|tap)'); do
  read -r rxe rxd txe txd < <(cat /sys/class/net/$i/statistics/rx_errors \
     /sys/class/net/$i/statistics/rx_dropped /sys/class/net/$i/statistics/tx_errors \
     /sys/class/net/$i/statistics/tx_dropped 2>/dev/null | tr '\n' ' ')
  tot=$(( ${rxe:-0} + ${txe:-0} ))
  if [ "$tot" -gt 100 ]; then
    bad "$i: rx_err=$rxe tx_err=$txe rx_drop=$rxd tx_drop=$txd — bad cable/port/duplex"
    fix "ethtool $i   # check 'Link detected', speed and duplex; reseat or replace the cable"
  else ok "$i: rx_err=${rxe:-0} tx_err=${txe:-0} rx_drop=${rxd:-0} tx_drop=${txd:-0}"; fi
done
command -v ethtool >/dev/null && for i in $(ls /sys/class/net | grep -E '^(en|eth)'); do
  echo "         $i: $(ethtool "$i" 2>/dev/null | grep -E 'Speed|Duplex|Link detected' | tr '\n' ' ')"
done

echo
echo "         100-packet loss/latency test per container (this takes ~30s):"
for entry in "${CTS[@]}"; do
  IFS=: read -r id label ip _u <<<"$entry"
  ct_running "$id" || continue
  res=$(ping -c 100 -i 0.2 -W 1 -q "$ip" 2>/dev/null | tail -3)
  loss=$(grep -oE '[0-9.]+% packet loss' <<<"$res" | grep -oE '^[0-9.]+')
  rtt=$(grep -oE 'min/avg/max[^ ]* = [^ ]+' <<<"$res" | awk '{print $3}')
  if [ -z "$loss" ]; then bad "$ip ($label) unreachable"
  elif awk "BEGIN{exit !(${loss:-0} > 1)}"; then
    bad "$ip ($label) ${loss}% packet loss  rtt=${rtt:-n/a}"
    fix "loss on a LOCAL bridge is not normal — see layer 1 (IP conflict) or a failing NIC"
  else ok "$ip ($label) ${loss}% loss  rtt=${rtt:-n/a}"; fi
done
}

# ================================================== LAYER 3: app-level stability
layer3() {
sec "LAYER 3 — service restarts, OOM kills, DB drops (window: $SINCE)"
for entry in "${CTS[@]}"; do
  IFS=: read -r id label ip units <<<"$entry"
  pct config "$id" >/dev/null 2>&1 || continue
  ct_running "$id" || { bad "CT $id ($label) is not running"; continue; }

  # memory pressure inside the CT — the top cause of "the app dies every hour"
  memline=$(inct "$id" "free -m | awk '/^Mem:/{print \$2, \$3}'")
  set -- ${memline:-0 0}
  memtot=${1:-0}; memuse=${2:-0}
  if [ "${memtot:-0}" -gt 0 ] && awk "BEGIN{exit !(${memuse}/${memtot} > 0.90)}"; then
    bad "CT $id ($label) memory ${memuse}/${memtot} MB (>90%) — OOM killer will reap workers"
    fix "pct set $id --memory $(( memtot * 2 ))   # then pct reboot $id"
  fi

  oom=$(inct "$id" "journalctl --no-pager --since '$SINCE' 2>/dev/null | grep -ciE 'out of memory|oom-kill|Killed process'")
  if [ "${oom:-0}" -gt 0 ] 2>/dev/null; then
    bad "CT $id ($label): ${oom} OOM-kill events — THIS is your disconnection"
    inct "$id" "journalctl --no-pager --since '$SINCE' | grep -iE 'oom-kill|Killed process' | tail -2" | sed 's/^/           /'
    fix "raise the CT memory (and swap), or cut gunicorn/next workers"
  fi

  for u in $units; do
    state=$(inct "$id" "systemctl is-active $u" || echo unknown)
    nr=$(inct "$id" "systemctl show $u -p NRestarts --value")
    since=$(inct "$id" "systemctl show $u -p ActiveEnterTimestamp --value")
    if [ "$state" != "active" ]; then
      bad "CT $id ($label) $u is '$state'"
      fix "pct exec $id -- journalctl -u $u -n 50 --no-pager"
    elif [ "${nr:-0}" -gt 2 ] 2>/dev/null; then
      bad "CT $id ($label) $u restarted ${nr}x — flapping (up since $since)"
      fix "pct exec $id -- journalctl -u $u --since '$SINCE' --no-pager | grep -iE 'error|traceback|killed'"
    else
      ok "CT $id ($label) $u active, ${nr:-0} restarts, since $since"
    fi
  done

  # Postgres dropping clients looks identical to a network drop from the app side
  if grep -q postgresql <<<"$units"; then
    pgerr=$(inct "$id" "grep -hiE 'terminating connection|server closed the connection|could not receive data|too many clients|unexpected EOF' /var/log/postgresql/*.log 2>/dev/null | tail -3")
    [ -n "$pgerr" ] && { bad "CT $id ($label) PostgreSQL is dropping client connections:"
                         printf '%s\n' "$pgerr" | sed 's/^/           /'
                         fix "raise max_connections / check the app's pool size, or see the OOM check above"; }
  fi
done

# host-level: unclean-shutdown damage and storage exhaustion
sec "LAYER 3b — host storage and filesystem health"
fserr=$(dmesg -T 2>/dev/null | grep -iE "EXT4-fs error|I/O error|ata[0-9]+:|blk_update_request" | tail -5)
if [ -n "$fserr" ]; then
  bad "host kernel reports storage errors (a power cut can leave real damage):"
  printf '%s\n' "$fserr" | sed 's/^/           /'
  fix "smartctl -a /dev/sdX   # and consider fsck on the affected volume from a maintenance boot"
else ok "no filesystem/IO errors in the host kernel log"; fi
if command -v lvs >/dev/null; then
  echo "         thin pool usage:"
  lvs -o lv_name,data_percent,metadata_percent 2>/dev/null | sed 's/^/           /'
  full=$(lvs --noheadings -o data_percent 2>/dev/null | awk '{gsub(/ /,""); if ($1+0 > 90) print $1}')
  [ -n "$full" ] && { bad "LVM thin pool over 90% full — writes will start failing"; fix "free space or extend the pool"; }
fi
df -h / /var/lib/vz 2>/dev/null | sed 's/^/           /'
}

# ================================================= LAYER 4: nginx's own verdict
layer4() {
sec "LAYER 4 — edge nginx error.log (this tells app-fault from network-fault)"
if ! ct_running "$CT_NGINX"; then bad "CT $CT_NGINX not running"; return; fi
log=$(inct "$CT_NGINX" "grep -h '' /var/log/nginx/error.log 2>/dev/null | tail -4000")
if [ -z "$log" ]; then warn "nginx error.log empty or unreadable"; return; fi

count() { grep -ciE "$1" <<<"$log"; }
c_closed=$(count "upstream prematurely closed connection")
c_refused=$(count "connect\(\) failed .*Connection refused")
c_noroute=$(count "No route to host|Network is unreachable|Host is unreachable")
c_timeout=$(count "upstream timed out")
c_reset=$(count "recv\(\) failed .*Connection reset by peer")

echo "         upstream prematurely closed .... $c_closed"
echo "         connection refused ............. $c_refused"
echo "         no route / unreachable ......... $c_noroute"
echo "         upstream timed out ............. $c_timeout"
echo "         connection reset by peer ....... $c_reset"
echo

[ "${c_noroute:-0}" -gt 0 ] && { bad "'No route to host' -> LAYER 1/2 problem. This is the ARP/IP-conflict signature."
                                 fix "go back to the layer-1 findings above — an IP conflict produces exactly this"; }
[ "${c_closed:-0}"  -gt 5 ] && { bad "'upstream prematurely closed' -> the APP is dying mid-request, not the network"
                                 fix "layer 3 above will show which unit is restarting or being OOM-killed"; }
[ "${c_refused:-0}" -gt 5 ] && { bad "'connection refused' -> the app process is down when nginx dials it (restart loop)"; }
[ "${c_timeout:-0}" -gt 5 ] && { bad "'upstream timed out' -> the app is alive but too slow (DB lock, swap thrash, or too few workers)"
                                 fix "raise proxy_read_timeout only after checking the app isn't swapping"; }
[ "${c_reset:-0}"   -gt 5 ] && warn "'connection reset by peer' -> often a keepalive race; check the app's keepalive timeout exceeds nginx's"

echo "         last 10 error.log lines:"
printf '%s\n' "$log" | tail -10 | sed 's/^/           /'
}

# ===================================================================== main
echo "${B}net-doctor${X}  $(date -Is)"
if [ "$WATCH" = 1 ]; then
  echo "watch mode — Ctrl-C to stop. Leave this running until a disconnection happens."
  while true; do layer1; layer2; echo; echo "--- sleeping 60s ---"; sleep 60; done
fi

layer1; layer2; layer3; layer4

sec "verdict"
if [ "$FAILED" = 0 ]; then
  echo "  ${G}Nothing broken right now.${X} Intermittent faults hide from point-in-time checks —"
  echo "  re-run during an outage, or leave './net-doctor.sh --watch' running until one hits."
else
  echo "  ${R}${FAILED} finding(s)${X} — fix by layer, lowest first. A layer-1 IP conflict"
  echo "  manufactures fake symptoms in every layer above it, so clear that before touching the apps."
fi
exit 0
