# Cloudflare Tunnel recovery — "Error 1033" after a power cut

Symptom seen on 2026-08-04: every hostname (`pugfin.parisunitedgroup.com`,
`accommodation…`, `parisunitedgroup.com`, `legal…`) returns

> **Error 1033 — Cloudflare Tunnel error.** The host is configured as a
> Cloudflare Tunnel and Cloudflare is currently unable to resolve it.

and the Zero Trust dashboard shows tunnel **pug-tunnel** as *Degraded*.

**TL;DR — run this on the Proxmox host and it will name the broken link:**

```bash
scp docs/scripts/tunnel-doctor.sh root@192.168.100.10:/root/
ssh root@192.168.100.10 'chmod +x /root/tunnel-doctor.sh && /root/tunnel-doctor.sh'
# once you've read the findings, recover with:
ssh root@192.168.100.10 '/root/tunnel-doctor.sh --restart'
```

---

## 1. What Error 1033 actually means

1033 is emitted by the Cloudflare **edge**, before a single packet reaches
your house. It means: *the DNS name is routed to a tunnel, and that tunnel
currently has no usable connector registered.*

That narrows the fault to one place — **CT 110 (`cf-tunnel`, 192.168.100.49)
and its path out to Cloudflare.** It is *not* nginx, and it is *not* the apps:

| What is broken | What visitors see |
|---|---|
| cloudflared not connected to the edge | **Error 1033** ← you are here |
| cloudflared up, nginx (CT 111) down | 502 Bad Gateway |
| nginx up, app CT down | 502 from nginx |
| origin cert expired | Error 526 |

So: **your Proxmox apps are almost certainly fine.** Do not start debugging
nginx or Postgres until the tunnel shows *Healthy*.

`Degraded` alongside 1033 is the classic signature of a **flapping
connector** — cloudflared registers one or two of its four edge connections,
drops them, retries. Cloudflare keeps the tunnel record but has no stable
connection to send your request down.

## 2. Ranked causes, most likely first for *this* failure

Given "PC lost power → tunnel degraded", in the order I'd check them:

### 2.1 cloudflared was never a systemd service (most common)

If the tunnel was originally started by hand — `cloudflared tunnel run
pug-tunnel` in a terminal, or `cloudflared tunnel --url …` — it survives
reboots only until the machine actually reboots. A power cut is the first
event that tests this. Symptom: `systemctl status cloudflared` says
`Unit cloudflared.service could not be found`.

```bash
pct exec 110 -- systemctl is-enabled cloudflared     # expect: enabled
pct exec 110 -- systemctl is-active  cloudflared     # expect: active
```

Fix (remotely-managed / token tunnel — this is what "connected via the
dashboard" means):

```bash
pct exec 110 -- bash
cloudflared service install <TUNNEL_TOKEN_FROM_DASHBOARD>
systemctl enable --now cloudflared
systemctl status cloudflared --no-pager
```

Fix (locally-managed / `config.yml` tunnel):

```bash
cloudflared --config /etc/cloudflared/config.yml service install
systemctl enable --now cloudflared
```

### 2.2 CT 110 itself did not come back up

The deployment guide creates every container with `--onboot 1`, but that only
applies if the CT was actually created with that flag — verify, don't assume:

```bash
pct list                      # is 110 'running'?
pct config 110 | grep onboot  # expect: onboot: 1
pct set 110 --onboot 1        # if it was missing
pct start 110
```

### 2.3 System clock skew → TLS handshake to the edge fails

A power cut plus a tired CMOS battery leaves the host hours or years off.
cloudflared's TLS handshake to the Cloudflare edge then fails with
`x509: certificate has expired or is not yet valid`, it retries forever, and
the tunnel sits at *Degraded*. This is the single most common
"it worked before the outage" cause after 2.1.

```bash
timedatectl                                   # on the host AND in CT 110
apt install -y chrony && systemctl enable --now chrony
timedatectl set-ntp true
```

If the host clock is wrong on **every** boot, replace the motherboard CR2032.

### 2.4 The router came back in a state that blocks QUIC (UDP 7844)

cloudflared prefers QUIC over **UDP 7844**. Plenty of consumer routers come
back from a power cut with UDP filtering or a broken conntrack table, and
cloudflared then half-connects — again *Degraded*. Force it onto TCP:

```bash
# token install:
systemctl edit cloudflared
#   [Service]
#   ExecStart=
#   ExecStart=/usr/bin/cloudflared --no-autoupdate --protocol http2 tunnel run --token <TOKEN>
systemctl daemon-reload && systemctl restart cloudflared
```

```yaml
# locally-managed — /etc/cloudflared/config.yml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
protocol: http2          # <— add this
```

Verify outbound reachability first:

```bash
pct exec 110 -- bash -c 'timeout 5 bash -c "</dev/tcp/198.41.192.167/7844" && echo TCP7844-OK'
pct exec 110 -- getent hosts region1.v2.argotunnel.com
```

### 2.5 Tunnel name / ID mismatch — `pug-tunnel` vs `pug-edge`

You describe the tunnel as **`pug-tunnel`**; this repo's deployment guide
(`docs/proxmox-deployment.html`, step 3.3) creates and routes DNS for a tunnel
named **`pug-edge`**:

```
cloudflared tunnel create pug-edge
cloudflared tunnel route dns pug-edge pugfin.parisunitedgroup.com
```

If the tunnel was deleted and recreated at some point, the DNS CNAMEs may
still point at the **old** tunnel's `<UUID>.cfargotunnel.com`. Cloudflare then
resolves the hostname to a tunnel with zero connectors — a permanent 1033 that
no amount of restarting cloudflared will clear, even while the dashboard shows
your *new* tunnel as healthy.

Check, per hostname, in **DNS → Records**: the CNAME target UUID must equal the
tunnel ID shown in **Zero Trust → Networks → Tunnels → pug-tunnel**.

```bash
# repoint them all (locally-managed):
cloudflared tunnel route dns pug-tunnel pugfin.parisunitedgroup.com
cloudflared tunnel route dns pug-tunnel accommodation.parisunitedgroup.com
cloudflared tunnel route dns pug-tunnel legal.parisunitedgroup.com
cloudflared tunnel route dns pug-tunnel parisunitedgroup.com
cloudflared tunnel route dns pug-tunnel www.parisunitedgroup.com
cloudflared tunnel route dns pug-tunnel teekeyhospitality.com
cloudflared tunnel route dns pug-tunnel www.teekeyhospitality.com
cloudflared tunnel route dns pug-tunnel zeroone.teekeyhospitality.com
```

Each record must stay **Proxied (orange cloud)**. A grey-clouded CNAME to
`cfargotunnel.com` cannot resolve and also produces 1033.

### 2.6 Stale credentials after a token rotation

If the tunnel was recreated or its token rotated, the connector authenticates
with a dead credential. Logs show `Unauthorized` / `failed to find tunnel`.

```bash
cloudflared service uninstall
cloudflared service install <CURRENT_TOKEN>
systemctl enable --now cloudflared
```

## 3. Real config gaps in this repo (found during review)

These are not the cause of today's outage, but they *will* bite you:

1. **Ingress list is stale.** `docs/proxmox-deployment.html` step 3.3 documents
   ingress rules for only four hostnames — `accommodation`, `pugfin`, the apex
   and `www`. Since then the edge nginx (`lxc/nginx.conf`) grew vhosts for
   `legal.parisunitedgroup.com`, `teekeyhospitality.com` (+`www`) and
   `zeroone.teekeyhospitality.com`. On a locally-managed tunnel those four
   hostnames fall through to the catch-all `service: http_status:404`. Add a
   rule per hostname — all of them point at `https://192.168.100.50:443` with
   `noTLSVerify: true`.

2. **Port-80 vhost `server_name` is stale too.** `lxc/nginx.conf:60` lists only
   the original four names on the `listen 80` redirect block. The legal and
   teekey names aren't there, so a plain-HTTP request for them lands in the
   443 default server instead of being redirected. Harmless today (the tunnel
   always dials 443) but wrong.

3. **No startup ordering.** Every `pct create` in the guide sets `--onboot 1`,
   but none sets `--startup`. After a power cut the containers boot in an
   arbitrary order, so cloudflared can register with Cloudflare seconds before
   Postgres/nginx are listening — visitors get 502s during the window, which
   looks like a broken recovery. Set an explicit order (see §4).

4. **No unattended clock discipline documented.** Nothing in the guide installs
   `chrony`. See §2.3 — this is the difference between a self-healing power cut
   and a manual recovery.

5. **No watchdog.** `cloudflared.service` ships with `Restart=on-failure`,
   which does not cover the case where the process is alive but has zero
   registered connections. See §4 for the metrics-based watchdog.

## 4. Make the next power cut self-healing

Run once on the Proxmox host — boot the data plane first, the tunnel last:

```bash
pct set 112 --startup order=1,up=15
pct set 113 --startup order=1,up=15
pct set 114 --startup order=1,up=15
pct set 115 --startup order=1,up=15
pct set 116 --startup order=1,up=15
pct set 111 --startup order=2,up=10      # edge nginx
pct set 110 --startup order=3            # cloudflared last
for id in 110 111 112 113 114 115 116; do pct set $id --onboot 1; done
```

Time sync everywhere:

```bash
apt install -y chrony && systemctl enable --now chrony          # host
for id in 110 111 112 113 114 115 116; do
  pct exec $id -- bash -lc 'apt-get install -y chrony >/dev/null && systemctl enable --now chrony'
done
```

Harden the connector — restart always, and expose metrics so a watchdog can
tell "process alive" from "actually connected":

```bash
pct exec 110 -- bash
mkdir -p /etc/systemd/system/cloudflared.service.d
cat > /etc/systemd/system/cloudflared.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
systemctl daemon-reload && systemctl restart cloudflared
```

Add `--metrics 127.0.0.1:2000` to the ExecStart, then a watchdog timer that
restarts the service when no connection is registered:

```bash
cat > /usr/local/bin/cf-watchdog.sh <<'EOF'
#!/usr/bin/env bash
# restart cloudflared if it reports zero registered edge connections
n=$(curl -sf --max-time 5 http://127.0.0.1:2000/metrics \
    | awk '/^cloudflared_tunnel_ha_connections /{print $2}')
[ -n "$n" ] && [ "${n%.*}" -ge 1 ] || systemctl restart cloudflared
EOF
chmod +x /usr/local/bin/cf-watchdog.sh
cat > /etc/systemd/system/cf-watchdog.service <<'EOF'
[Unit]
Description=cloudflared connectivity watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-watchdog.sh
EOF
cat > /etc/systemd/system/cf-watchdog.timer <<'EOF'
[Unit]
Description=Run cloudflared watchdog every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now cf-watchdog.timer
```

Finally, a UPS on the Proxmox box turns "power cut" into "clean shutdown" and
removes the whole class of failure (`apt install nut` / `apcupsd`).

## 5. Verification, from the inside out

```bash
# 1. connector registered? expect 4x "Registered tunnel connection"
pct exec 110 -- journalctl -u cloudflared -n 40 --no-pager

# 2. origin reachable from the tunnel CT?
pct exec 110 -- bash -c 'timeout 5 bash -c "</dev/tcp/192.168.100.50/443" && echo ORIGIN-OK'

# 3. nginx serving the vhost directly (bypassing Cloudflare)?
pct exec 111 -- curl -ksI https://192.168.100.50 -H 'Host: pugfin.parisunitedgroup.com'

# 4. the app itself
pct exec 114 -- curl -sI http://192.168.100.53:5000/

# 5. end to end
curl -sI https://pugfin.parisunitedgroup.com/
```

Dashboard check: **Zero Trust → Networks → Tunnels → pug-tunnel** should read
*Healthy* with 4 connections. Anything less than 4 is *Degraded* and means the
connector is still flapping — go back to §2.3 / §2.4.
