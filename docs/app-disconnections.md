# Diagnosing intermittent app disconnections (tunnel healthy)

Once `pug-tunnel` reads **Healthy** in Zero Trust, any remaining "the app keeps
dropping" is *inside* the LAN. This is how to tell an **IP conflict** apart from
the other four things that produce identical symptoms.

```bash
scp docs/scripts/net-doctor.sh root@192.168.100.10:/root/
ssh root@192.168.100.10 'chmod +x /root/net-doctor.sh && apt install -y iputils-arping arp-scan && /root/net-doctor.sh'
```

Intermittent faults hide from point-in-time checks. If it comes back clean,
leave `./net-doctor.sh --watch` running in a terminal until a drop happens.

---

## 1. First, read nginx's error log — it names the layer for you

This is the fastest discriminator in the whole stack, because nginx sits
between the tunnel and the apps and logs *why* each upstream call failed:

```bash
pct exec 111 -- tail -200 /var/log/nginx/error.log
```

| Message | What it actually means | Layer |
|---|---|---|
| `connect() failed … No route to host` | ARP is broken — packets are going to the wrong MAC | **IP conflict** |
| `upstream prematurely closed connection` | the app process died mid-request | app / OOM |
| `connect() failed … Connection refused` | the app wasn't listening when nginx dialled | restart loop |
| `upstream timed out (110)` | app alive but too slow | DB lock / swap / too few workers |
| `recv() failed … Connection reset by peer` | keepalive race | tuning |

**`No route to host` on a LAN you control is the IP-conflict fingerprint.** If
you see it, go straight to §2. If you see `prematurely closed` instead, the
network is fine and it's §4.

## 2. Confirm or rule out an IP conflict

Your CTs use hard-coded static IPs `192.168.100.49`–`.55`. A conflict happens
when *anything else* on the LAN also claims one — a phone, a TV, a laptop that
got that address from the router's DHCP pool. The two devices then trade the
address in every other machine's ARP cache, so traffic lands on the wrong one
roughly half the time: connections stall, then work, then stall. Exactly what
"frequent disconnection" feels like.

### 2.1 Does each IP answer with exactly one MAC?

Run from the Proxmox host (which does *not* own these IPs):

```bash
apt install -y iputils-arping arp-scan
for ip in 49 50 51 52 53 54 55; do
  echo "--- 192.168.100.$ip"
  arping -c 4 -I vmbr0 192.168.100.$ip | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | sort -u
done
```

**One MAC per IP = no conflict. Two or more = confirmed conflict.**

Cross-check that the MAC is the container's own:

```bash
for id in 110 111 112 113 114 115 116; do
  echo "CT $id: $(pct config $id | grep -oE 'hwaddr=[^,]*')"
done
```

If an IP answers from a MAC that belongs to *no* container, a foreign device
has taken it outright.

### 2.2 Sweep the whole subnet

`arp-scan` flags duplicates itself:

```bash
arp-scan --interface=vmbr0 192.168.100.0/24
```

Any line marked `(DUP: 2)` is a conflict. Also look at **who else** appears in
the `.49`–`.55` window — nothing but your containers should be there.

### 2.3 Ask the kernel

Both the host and the containers log conflicts outright:

```bash
dmesg -T | grep -i "duplicate address"
for id in 110 111 112 113 114 115 116; do
  pct exec $id -- bash -lc 'journalctl --since "24 hours ago" | grep -i "duplicate address"'
done
```

### 2.4 The permanent fix

A conflict means your router's **DHCP pool overlaps your static range**. Fix it
at the router, not on the containers:

- Set the DHCP pool to something like `192.168.100.100–192.168.100.200`, so it
  can never hand out `.49`–`.55`.
- Or, better, create DHCP **reservations** for the seven container MACs so the
  router itself considers those addresses taken.

Until the pool is fixed the conflict *will* come back the next time that device
renews its lease — which is why the outage looks random and periodic.

### 2.5 Duplicate MAC (the other conflict)

If a container was ever cloned (`pct clone`) without regenerating its NIC, two
CTs can share one MAC and both flap:

```bash
for id in 110 111 112 113 114 115 116; do pct config $id | grep -oE 'hwaddr=[^,]*'; done | sort | uniq -d
```

Any output = duplicate. Fix:

```bash
pct set <VMID> --net0 name=eth0,bridge=vmbr0,ip=192.168.100.<N>/24,gw=192.168.100.1
# omitting hwaddr makes Proxmox generate a fresh one
pct reboot <VMID>
```

## 3. If ARP is clean — check the physical layer

A dying NIC, a marginal cable, or a duplex mismatch drops packets on a schedule
that also looks like "random disconnections".

```bash
ip -s link show vmbr0
ethtool eno1 | grep -E 'Speed|Duplex|Link detected'   # use your real NIC name
cat /sys/class/net/eno1/statistics/rx_errors
ping -c 100 -i 0.2 192.168.100.53                     # any loss at all is abnormal on a local bridge
```

**Loss between the Proxmox host and its own containers is never normal** — that
traffic doesn't leave the box. Non-zero loss there points back at §2 (ARP being
poisoned) rather than at cabling.

## 4. If the network is clean — the apps are restarting

The commonest non-network cause, especially after a power cut:

```bash
# is a service flapping?
pct exec 114 -- systemctl show pugfin -p NRestarts --value
pct exec 114 -- systemctl status pugfin --no-pager

# is the OOM killer reaping workers?
pct exec 114 -- bash -lc 'journalctl --since "24 hours ago" | grep -iE "oom-kill|Killed process"'
pct exec 114 -- free -m

# is Postgres dropping clients?
pct exec 114 -- bash -lc 'grep -iE "terminating connection|too many clients|unexpected EOF" /var/log/postgresql/*.log | tail'
```

CT 114 (`pugfin`) has only **2 GB** and CT 115/116 run a Next.js build plus
Postgres in **4 GB**. A Next.js production build in particular can transiently
need more than the CT has, and the OOM killer takes the app down with it —
which nginx then reports as `upstream prematurely closed connection`. Raise it:

```bash
pct set 114 --memory 4096 --swap 2048
pct reboot 114
```

Also make the services restart themselves rather than waiting for you:

```bash
pct exec 114 -- bash -lc '
mkdir -p /etc/systemd/system/pugfin.service.d
printf "[Service]\nRestart=always\nRestartSec=5\n" > /etc/systemd/system/pugfin.service.d/override.conf
systemctl daemon-reload'
```

## 5. If everything above is clean — storage damage from the power cut

An unclean shutdown can leave real filesystem or thin-pool damage that surfaces
as periodic IO stalls, which the apps experience as disconnections:

```bash
dmesg -T | grep -iE "EXT4-fs error|I/O error|blk_update_request"
lvs -o lv_name,data_percent,metadata_percent     # thin pool >90% = writes start failing
smartctl -a /dev/sda                              # apt install smartmontools
df -h / /var/lib/vz
```

## 6. Order of attack

Work bottom-up; a layer-1 fault fabricates symptoms in every layer above it, so
never tune nginx timeouts or app workers before ARP is proven clean.

1. `net-doctor.sh` on the host → read the layer-1 section first
2. Conflict found → fix the router's DHCP pool (§2.4), then re-test
3. No conflict → NIC/cable (§3)
4. Network clean → service restarts / OOM (§4)
5. All clean → storage (§5)
6. Still nothing → run `net-doctor.sh --watch` and wait for the fault to appear
