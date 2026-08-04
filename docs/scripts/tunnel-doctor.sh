#!/usr/bin/env bash
#
# tunnel-doctor.sh — one-shot health check for the Cloudflare Tunnel path
#     Internet -> Cloudflare edge -> cloudflared (CT 110) -> edge nginx (CT 111) -> app CTs
#
# Run this FIRST whenever you see "Error 1033 / Cloudflare Tunnel error" or the
# dashboard shows the tunnel as Degraded / Down. It walks the whole chain from
# the outside in and prints, for every broken link, the exact command that fixes
# it. Read-only by default — it changes nothing unless you pass --restart.
#
# Install on the PROXMOX HOST (not inside a CT), as root:
#     scp docs/scripts/tunnel-doctor.sh root@192.168.100.10:/root/tunnel-doctor.sh
#     chmod +x /root/tunnel-doctor.sh
#     /root/tunnel-doctor.sh
#
# Flags:
#     --restart     after diagnosing, start any stopped CT and restart
#                   cloudflared + nginx (the standard post-power-cut recovery)
#     --logs N      show the last N cloudflared log lines (default 25)
#
set -uo pipefail   # NOTE: no -e — a failing probe is a finding, not a crash

# ---- config (edit only if your layout differs) ----
CT_TUNNEL=110
CT_NGINX=111
NGINX_IP=192.168.100.50
# "VMID:label:ip:port[,port]" — the app CTs behind nginx
APP_CTS=(
  "112:pugweb:192.168.100.51:3000,8000"
  "113:housing:192.168.100.52:3000,5000"
  "114:pugfin:192.168.100.53:5000"
  "115:zeroone:192.168.100.54:3000,8000"
  "116:legal:192.168.100.55:3000,8000"
)

RESTART=0
LOGLINES=25
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1 ;;
    --logs)    LOGLINES="${2:-25}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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

command -v pct >/dev/null || { echo "${R}pct not found — run this on the Proxmox HOST, not inside a container.${X}"; exit 2; }

echo "${B}tunnel-doctor${X}  $(date -Is)"

# ---------------------------------------------------------------- 1. host clock
sec "1. Proxmox host clock (a wrong clock breaks the tunnel's TLS handshake)"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "clock synchronised — $(date -u +%FT%TZ) UTC"
else
  bad "host clock is NOT NTP-synchronised: $(date -u +%FT%TZ) UTC"
  fix "apt install -y chrony && systemctl enable --now chrony ; timedatectl set-ntp true"
  fix "if it drifts on every boot the CMOS battery is dead — replace it (CR2032)"
fi

# ------------------------------------------------------- 2. container boot state
sec "2. Container state and onboot flags"
for entry in "$CT_TUNNEL:cf-tunnel" "$CT_NGINX:edge-nginx" "${APP_CTS[@]}"; do
  id="${entry%%:*}"; rest="${entry#*:}"; label="${rest%%:*}"
  pct config "$id" >/dev/null 2>&1 || { warn "CT $id ($label) does not exist here — skipping"; continue; }
  onboot=$(pct config "$id" | awk -F': ' '/^onboot:/{print $2}')
  startup=$(pct config "$id" | awk -F': ' '/^startup:/{print $2}')
  if ct_running "$id"; then st="running"; else st="STOPPED"; fi

  if [ "$st" = "running" ]; then ok "CT $id ($label) running"
  else
    bad "CT $id ($label) is STOPPED"
    fix "pct start $id"
  fi
  if [ "${onboot:-0}" != "1" ]; then
    bad "CT $id ($label) has onboot=${onboot:-0} — it will NOT come back after a power cut"
    fix "pct set $id --onboot 1"
  fi
  [ -n "$startup" ] || warn "CT $id ($label) has no startup order set (see step 8)"
done

# ------------------------------------------------------------- 3. cloudflared CT
sec "3. CT $CT_TUNNEL — cloudflared service"
if ! ct_running "$CT_TUNNEL"; then
  bad "CT $CT_TUNNEL is not running — this alone causes Error 1033 on every hostname"
  fix "pct start $CT_TUNNEL"
else
  if ! inct "$CT_TUNNEL" 'command -v cloudflared' >/dev/null; then
    bad "cloudflared binary not found on PATH inside CT $CT_TUNNEL"
    fix "pct exec $CT_TUNNEL -- apt install -y cloudflared   (see deployment guide step 3.2)"
  else
    ok "cloudflared $(inct "$CT_TUNNEL" 'cloudflared --version' | head -1)"
  fi

  enabled=$(inct "$CT_TUNNEL" 'systemctl is-enabled cloudflared' || echo missing)
  active=$( inct "$CT_TUNNEL" 'systemctl is-active  cloudflared' || echo inactive)

  case "$enabled" in
    enabled) ok "cloudflared.service is enabled (starts on boot)" ;;
    missing|"") bad "there is NO cloudflared systemd service in CT $CT_TUNNEL"
                fix "you were running cloudflared by hand in a shell — that dies at power-off."
                fix "install it as a service:  cloudflared service install <TUNNEL_TOKEN>"
                fix "then:  systemctl enable --now cloudflared" ;;
    *) bad "cloudflared.service is '$enabled' — it will NOT start on boot"
       fix "pct exec $CT_TUNNEL -- systemctl enable --now cloudflared" ;;
  esac

  if [ "$active" = "active" ]; then
    ok "cloudflared is running (uptime: $(inct "$CT_TUNNEL" "systemctl show cloudflared -p ActiveEnterTimestamp --value"))"
    nrestarts=$(inct "$CT_TUNNEL" 'systemctl show cloudflared -p NRestarts --value')
    if [ "${nrestarts:-0}" -gt 3 ] 2>/dev/null; then
      bad "cloudflared has restarted ${nrestarts} times — it is crash-looping, which is what shows as 'Degraded'"
    fi
  else
    bad "cloudflared is '$active' — no connector is registered, so Cloudflare answers 1033"
    fix "pct exec $CT_TUNNEL -- systemctl start cloudflared"
  fi

  # how is the tunnel configured?
  if inct "$CT_TUNNEL" 'test -f /etc/cloudflared/config.yml'; then
    ok "locally-managed tunnel: /etc/cloudflared/config.yml present"
    echo "         ingress hostnames configured:"
    inct "$CT_TUNNEL" "grep -E '^\s*-?\s*hostname:' /etc/cloudflared/config.yml" | sed 's/^/           /'
    tid=$(inct "$CT_TUNNEL" "awk -F': ' '/^tunnel:/{print \$2}' /etc/cloudflared/config.yml")
    if [ -n "${tid:-}" ]; then
      echo "         tunnel id: $tid   (DNS CNAMEs must point at ${tid}.cfargotunnel.com)"
      if inct "$CT_TUNNEL" "test -f /etc/cloudflared/${tid}.json"; then
        ok "credentials file /etc/cloudflared/${tid}.json present"
      else
        bad "credentials file /etc/cloudflared/${tid}.json is MISSING — cloudflared cannot authenticate"
        fix "copy the tunnel's JSON back into /etc/cloudflared/, or re-run: cloudflared tunnel create pug-tunnel"
      fi
    fi
  elif inct "$CT_TUNNEL" 'grep -q TunnelToken /etc/systemd/system/cloudflared.service'; then
    ok "remotely-managed tunnel (token in the systemd unit; routes live in the Zero Trust dashboard)"
    warn "public hostnames are NOT visible from here — check Zero Trust > Networks > Tunnels > pug-tunnel > Public Hostnames"
  else
    warn "could not determine whether the tunnel is locally- or remotely-managed"
  fi

  # ---- log triage
  sec "4. cloudflared logs (last $LOGLINES lines, CT $CT_TUNNEL)"
  logs=$(inct "$CT_TUNNEL" "journalctl -u cloudflared --no-pager -n 400 --since '-30 min'")
  if [ -z "$logs" ]; then
    warn "no cloudflared journal output in the last 30 minutes"
  else
    echo "$logs" | tail -n "$LOGLINES" | sed 's/^/    /'
    echo
    grep -qi "Registered tunnel connection"        <<<"$logs" && ok "connector registered with the Cloudflare edge at least once"
    conns=$(grep -ci "Registered tunnel connection" <<<"$logs")
    [ "${conns:-0}" -gt 0 ] && [ "${conns:-0}" -lt 4 ] && \
      warn "only ${conns} of 4 edge connections registered — this is exactly what the dashboard calls 'Degraded'"
    if grep -qiE "x509: certificate has expired|certificate is not yet valid|Handshake did not complete in time" <<<"$logs"; then
      bad "TLS handshake failures — almost always a WRONG SYSTEM CLOCK in the CT or on the host"
      fix "pct exec $CT_TUNNEL -- bash -c 'apt install -y chrony; systemctl enable --now chrony; timedatectl set-ntp true'"
    fi
    if grep -qiE "Unauthorized|token is invalid|tunnel not found|failed to find tunnel" <<<"$logs"; then
      bad "Cloudflare rejected this connector's credentials, or the tunnel no longer exists"
      fix "the tunnel was deleted/recreated in the dashboard. Re-install with the CURRENT token:"
      fix "  cloudflared service uninstall && cloudflared service install <NEW_TOKEN> && systemctl enable --now cloudflared"
    fi
    if grep -qiE "failed to dial to edge|context deadline exceeded|no such host|dial tcp.*i/o timeout" <<<"$logs"; then
      bad "cloudflared cannot reach the Cloudflare edge — DNS or outbound 443/7844 is blocked"
      fix "check step 5 below; if UDP is the problem force TCP: add  protocol: http2  to config.yml,"
      fix "  or for a token install:  systemctl edit cloudflared  ->  ExecStart= ... --protocol http2"
    fi
    if grep -qiE "connection refused|error proxying request|dial tcp 192\.168\.100\.50.*refused" <<<"$logs"; then
      warn "the tunnel is UP but the origin (nginx on $NGINX_IP) refused it — see step 6 (that is a 502, not a 1033)"
    fi
  fi

  # ---- ARP conflict on the tunnel CT's own address
  #      A contested .49 makes cloudflared flap forever and reads as "Degraded".
  #      This was the real cause of the 2026-08-04 outage — check it before
  #      blaming DNS or the clock. See docs/app-disconnections.md.
  sec "5a. CT $CT_TUNNEL address uniqueness (IP conflict = permanent 'Degraded')"
  tun_ip=$(pct config "$CT_TUNNEL" | grep -oE 'ip=[0-9.]+' | head -1 | cut -d= -f2)
  tun_ip=${tun_ip:-192.168.100.49}
  if command -v arping >/dev/null; then
    macs=$(arping -c 6 -w 4 -I vmbr0 "$tun_ip" 2>/dev/null \
           | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u)
    n=$(printf '%s\n' "$macs" | grep -c .)
    if [ "${n:-0}" -gt 1 ]; then
      bad "$tun_ip is claimed by $n DIFFERENT MACs — IP CONFLICT, cloudflared cannot stay connected:"
      printf '%s\n' "$macs" | sed 's/^/           /'
      fix "BC:24:11:* is the Proxmox OUI (your CT); anything else is a rogue device"
      fix "move the router's DHCP pool clear of the whole .49-.55 static range"
      fix "full procedure: docs/app-disconnections.md"
    elif [ "${n:-0}" -eq 1 ]; then
      ok "$tun_ip answered by a single MAC ($macs)"
    else
      warn "$tun_ip did not answer ARP (CT stopped?)"
    fi
  else
    warn "arping not installed — cannot rule out an IP conflict on $tun_ip"
    fix "apt install -y iputils-arping && rerun (this was the 2026-08-04 root cause)"
  fi

  # ---- egress
  sec "5b. CT $CT_TUNNEL outbound reachability"
  if inct "$CT_TUNNEL" 'getent hosts region1.v2.argotunnel.com' >/dev/null; then
    ok "DNS resolves region1.v2.argotunnel.com"
  else
    bad "DNS resolution failing inside CT $CT_TUNNEL"
    fix "pct set $CT_TUNNEL --nameserver 1.1.1.1 && pct reboot $CT_TUNNEL"
  fi
  for probe in "198.41.192.167 7844 (edge, TCP)" "1.1.1.1 443 (internet, TCP)"; do
    set -- $probe
    if inct "$CT_TUNNEL" "timeout 5 bash -c '</dev/tcp/$1/$2'"; then ok "outbound TCP $1:$2 reachable  ${3:-}"
    else bad "outbound TCP $1:$2 BLOCKED  ${3:-}"
         fix "your router/firewall rebooted into a state that blocks it — allow outbound 443 + 7844 (TCP and UDP) from $CT_TUNNEL"; fi
  done
  if inct "$CT_TUNNEL" "timeout 5 bash -c '</dev/tcp/$NGINX_IP/443'"; then
    ok "cloudflared can reach the origin $NGINX_IP:443"
  else
    bad "cloudflared CANNOT reach the origin $NGINX_IP:443 (this yields 502, after the 1033 is cleared)"
  fi
fi

# --------------------------------------------------------------- 6. edge nginx
sec "6. CT $CT_NGINX — edge nginx"
if ! ct_running "$CT_NGINX"; then
  bad "CT $CT_NGINX is not running"
  fix "pct start $CT_NGINX"
else
  if [ "$(inct "$CT_NGINX" 'systemctl is-active nginx')" = "active" ]; then ok "nginx is running"
  else bad "nginx is not running"; fix "pct exec $CT_NGINX -- systemctl enable --now nginx"; fi
  if inct "$CT_NGINX" 'nginx -t' >/dev/null 2>&1; then ok "nginx config syntax OK"
  else bad "nginx -t FAILS:"; inct "$CT_NGINX" 'nginx -t 2>&1' | sed 's/^/         /'; fi
  inct "$CT_NGINX" "ss -lnt | grep -q ':443 '" && ok "listening on :443" || bad "nothing listening on :443"
  for crt in /etc/nginx/ssl/origin.crt /etc/nginx/ssl/teekey-origin.crt; do
    if inct "$CT_NGINX" "test -f $crt"; then
      end=$(inct "$CT_NGINX" "openssl x509 -enddate -noout -in $crt | cut -d= -f2")
      if inct "$CT_NGINX" "openssl x509 -checkend 604800 -noout -in $crt" >/dev/null; then ok "$crt valid until $end"
      else bad "$crt expires within 7 days ($end)"; fix "mint a fresh Origin Certificate in Cloudflare > SSL/TLS > Origin Server"; fi
    else warn "$crt not present"; fi
  done
fi

# ----------------------------------------------------------------- 7. app CTs
sec "7. Application containers behind nginx"
for entry in "${APP_CTS[@]}"; do
  IFS=: read -r id label ip ports <<<"$entry"
  pct config "$id" >/dev/null 2>&1 || continue
  if ! ct_running "$id"; then bad "CT $id ($label) stopped"; fix "pct start $id"; continue; fi
  for p in ${ports//,/ }; do
    if timeout 5 bash -c "</dev/tcp/$ip/$p" 2>/dev/null; then ok "CT $id ($label) $ip:$p answering"
    else bad "CT $id ($label) $ip:$p not answering"
         fix "pct exec $id -- systemctl --failed --no-pager   # then start/enable the unit (Postgres first)"; fi
  done
done

# -------------------------------------------------------------- 8. boot order
sec "8. Power-cut resilience (startup order)"
missing_order=0
for entry in "$CT_TUNNEL:x" "$CT_NGINX:x" "${APP_CTS[@]}"; do
  id="${entry%%:*}"
  pct config "$id" >/dev/null 2>&1 || continue
  pct config "$id" | grep -q '^startup:' || missing_order=1
done
if [ "$missing_order" = 1 ]; then
  warn "no startup order configured — after a power cut the CTs race, and cloudflared can register before its origin exists"
  fix "pct set 114 --startup order=1,up=15   # and 112 113 115 116 the same"
  fix "pct set $CT_NGINX --startup order=2,up=10"
  fix "pct set $CT_TUNNEL --startup order=3"
else
  ok "startup order is configured on all containers"
fi

# ------------------------------------------------------------------ 9. restart
if [ "$RESTART" = 1 ]; then
  sec "9. --restart: bringing the stack back up in dependency order"
  for entry in "${APP_CTS[@]}"; do
    id="${entry%%:*}"
    pct config "$id" >/dev/null 2>&1 || continue
    ct_running "$id" || { echo "  starting CT $id"; pct start "$id"; }
  done
  ct_running "$CT_NGINX" || { echo "  starting CT $CT_NGINX"; pct start "$CT_NGINX"; sleep 5; }
  inct "$CT_NGINX" 'systemctl restart nginx' && ok "nginx restarted"
  ct_running "$CT_TUNNEL" || { echo "  starting CT $CT_TUNNEL"; pct start "$CT_TUNNEL"; sleep 5; }
  inct "$CT_TUNNEL" 'systemctl restart cloudflared' && ok "cloudflared restarted"
  echo "  waiting 20s for the connector to register..."
  sleep 20
  inct "$CT_TUNNEL" "journalctl -u cloudflared --no-pager -n 15 --since '-1 min'" | sed 's/^/    /'
fi

# ------------------------------------------------------------------ verdict
sec "verdict"
if [ "$FAILED" = 0 ]; then
  echo "  ${G}No failures found.${X} If visitors still see 1033, the break is between Cloudflare"
  echo "  and this tunnel: check that each hostname's DNS record is the orange-clouded CNAME to"
  echo "  <TUNNEL_ID>.cfargotunnel.com, and that Zero Trust > Tunnels > pug-tunnel lists it."
else
  echo "  ${R}${FAILED} check(s) failed${X} — fix them top-down; the first failure usually explains the rest."
  echo "  Full recovery walkthrough: docs/tunnel-recovery.md in the edge-proxy repo."
fi
exit 0
