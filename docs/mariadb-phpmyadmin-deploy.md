# CT 117 — MariaDB + phpMyAdmin (maria.parisunitedgroup.com)

A standalone MariaDB + phpMyAdmin container for ad-hoc/test database work,
fronted by the same edge-nginx CT (111) as every other site, on its own
subdomain. Sample PHP page included so you have something to hit besides
phpMyAdmin itself.

Follows the exact pattern used for CT 112–116 in `proxmox-deployment.html`
(Debian 12 template, static LAN IP, edge-nginx reverse proxy, Cloudflare
Tunnel, nftables lockdown). Read that file first if you haven't built a CT
this way before — this doc only covers what's different for this CT.

## 0. Where this fits — current fleet

| CT   | Hostname    | IP              | Role                              |
|------|-------------|-----------------|------------------------------------|
| 110  | cf-tunnel   | (dials out)     | cloudflared — the only public hop |
| 111  | edge-nginx  | 192.168.100.50  | TLS termination + reverse proxy   |
| 112  | pugweb      | 192.168.100.51  | Corporate site (Next.js/FastAPI)  |
| 113  | housing     | 192.168.100.52  | Employee Housing Portal           |
| 114  | pugfin      | 192.168.100.53  | Finance / PUG Accounts            |
| 115  | zeroone     | 192.168.100.54  | Hotel booking (teekey)            |
| 116  | legal       | 192.168.100.55  | Legal Case Filing                 |
| **117** | **mariadb** | **192.168.100.56** | **MariaDB + phpMyAdmin (this doc)** |

Next free slot after this one is CT **118** / **192.168.100.57**.
LAN: `192.168.100.0/24`, gateway `192.168.100.1`, bridge `vmbr0`, Proxmox
host `192.168.100.10`. `lxc/nginx.conf` in this repo has already been
updated with the `maria.parisunitedgroup.com` vhost (Host 6) and the
`mariadb_web` upstream pointing at `192.168.100.56:80` — deploy it to the
edge CT in Step 4 below.

## 1. Create the container (on the Proxmox host)

```bash
pct create 117 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname mariadb \
  --cores 2 --memory 2048 --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.100.56/24,gw=192.168.100.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 --onboot 1 \
  --password CHANGE_ME --start 1

pct enter 117
```

## 2. Install MariaDB, Apache, PHP, phpMyAdmin

```bash
apt update && apt full-upgrade -y
apt install -y mariadb-server apache2 php php-mysqli php-mbstring \
                php-zip php-gd php-json php-curl unzip

# non-interactive phpMyAdmin install (skips the dbconfig-common wizard —
# we point it at MariaDB by hand right after, same idea as the unattended
# installs elsewhere in this repo's runbook). reconfigure-webserver MUST
# name apache2, or the postinst skips writing the Apache conf snippet
# entirely and `a2enconf phpmyadmin` fails with "Conf does not exist".
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin

systemctl enable --now mariadb apache2

# belt-and-braces: some phpmyadmin package revisions still don't drop the
# conf snippet even with reconfigure-webserver set correctly. If
# `a2enconf phpmyadmin` errors "Conf phpmyadmin does not exist", write it
# by hand and enable it:
if [ ! -e /etc/apache2/conf-available/phpmyadmin.conf ]; then
  cat > /etc/apache2/conf-available/phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
</Directory>
EOF
fi
a2enconf phpmyadmin
systemctl reload apache2

# confirm PHP is actually wired into Apache (empty output => run
# `a2enmod php8.2` — or whatever `php -v` reports — then reload again)
apache2ctl -M | grep -i php
```

## 3. Secure MariaDB + create the sample DB/user

```bash
mysql_secure_installation
# set a strong root password, remove anonymous users, disallow remote
# root login, remove test DB, reload privileges — answer Y to all.

# Debian's MariaDB ships root@localhost on the `unix_socket` auth
# plugin, so it still logs in with NO password (as the Linux root
# user) even after mysql_secure_installation — and phpMyAdmin/PHP,
# which connects over TCP/localhost, can NEVER authenticate as root
# with a password until the plugin is switched. Log in via socket
# auth (no -p needed) and everything below runs in one session:
mysql -u root <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY 'CHANGE_ME_STRONG_ROOT_PW';

CREATE DATABASE sample_app CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'sample_user'@'localhost' IDENTIFIED BY 'CHANGE_ME_STRONG';
GRANT ALL PRIVILEGES ON sample_app.* TO 'sample_user'@'localhost';
FLUSH PRIVILEGES;

USE sample_app;
CREATE TABLE notes (id INT AUTO_INCREMENT PRIMARY KEY,
                     body VARCHAR(255) NOT NULL,
                     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
INSERT INTO notes (body) VALUES ('Hello from MariaDB on CT 117');
SQL
```

`ALTER USER ... IDENTIFIED BY` implicitly switches root's plugin from
`unix_socket` to `mysql_native_password`, so `root` / the password above
now works from phpMyAdmin too. For the public sample site, prefer logging
into phpMyAdmin as `sample_user` day-to-day and keep the root password for
emergencies only.

`bind-address` in `/etc/mysql/mariadb.conf.d/50-server.cnf` defaults to
`127.0.0.1` on Debian — leave it that way. MariaDB is never reachable over
the LAN; only Apache (same CT, over the loopback) talks to it.

## 4. Sample test website

phpMyAdmin already lives at `/phpmyadmin` (Debian's package wires that up
via `a2enconf`). Drop a minimal page at the document root so
`https://maria.parisunitedgroup.com/` shows something other than the
default Apache page:

```bash
cat > /var/www/html/index.php <<'PHP'
<?php
$mysqli = new mysqli('localhost', 'sample_user', 'CHANGE_ME_STRONG', 'sample_app');
if ($mysqli->connect_errno) {
    http_response_code(500);
    die('DB connection failed: ' . $mysqli->connect_error);
}
$result = $mysqli->query('SELECT id, body, created_at FROM notes ORDER BY id DESC');
?>
<!doctype html>
<html><head><title>MariaDB test — CT 117</title></head>
<body style="font-family: sans-serif; max-width: 640px; margin: 40px auto;">
  <h1>MariaDB test site</h1>
  <p>Connected to <code>sample_app</code> on <code>192.168.100.56</code>.</p>
  <ul>
    <?php while ($row = $result->fetch_assoc()): ?>
      <li>#<?= $row['id'] ?> — <?= htmlspecialchars($row['body']) ?> (<?= $row['created_at'] ?>)</li>
    <?php endwhile; ?>
  </ul>
  <p><a href="/phpmyadmin">Open phpMyAdmin</a></p>
</body></html>
PHP

rm -f /var/www/html/index.html
chown www-data:www-data /var/www/html/index.php
```

Verify locally on the CT before wiring the proxy:

```bash
curl -fsS http://127.0.0.1/ | grep -o '<h1>.*</h1>'
curl -o /dev/null -s -w '%{http_code}\n' http://127.0.0.1/phpmyadmin/
```

## 5. Deploy the edge-nginx vhost

`lxc/nginx.conf` in this repo already has the `maria.parisunitedgroup.com`
server block (Host 6) and the `mariadb_web` upstream. Ship it to the edge
CT (111):

```bash
# from your workstation / wherever you keep this repo checked out
scp lxc/nginx.conf root@192.168.100.50:/etc/nginx/conf.d/default.conf

# on the edge CT (111)
pct enter 111   # or ssh
nginx -t && systemctl reload nginx
```

From the edge CT, confirm it can reach the new app CT over the LAN:

```bash
curl -fsS http://192.168.100.56/ | grep -o '<h1>.*</h1>'
```

## 6. Cloudflare Tunnel — route the new hostname

Same tunnel that already carries `accommodation`, `pugfin`, `legal`, etc.
— just add one more public hostname, service is always the edge CT.

**Dashboard route** (if the tunnel is managed there): Zero Trust →
Networks → Tunnels → your tunnel → Public Hostname → Add:
- Hostname: `maria.parisunitedgroup.com`
- Service: `HTTPS` → `192.168.100.50:443`
- Additional settings → TLS → **No TLS Verify: OFF** (the wildcard PUG
  origin cert covers this subdomain, so real verification passes).

**Or config.yml route** (on CT 110), add an ingress rule before the
catch-all `service: http_status:404`:

```yaml
- hostname: maria.parisunitedgroup.com
  service: https://192.168.100.50:443
  originRequest:
    originServerName: maria.parisunitedgroup.com
```

```bash
cloudflared tunnel route dns pug-edge maria.parisunitedgroup.com
systemctl restart cloudflared   # only if you edited config.yml by hand
```

## 7. Cloudflare SSL/TLS mode — "Full (strict)"

Dashboard → SSL/TLS → Overview → confirm the zone is set to **Full
(strict)** (it already is, for the other subdomains — this is a
zone-wide setting, not per-hostname, so nothing to change here). Full
(strict) means Cloudflare validates the origin cert on every hop to
`192.168.100.50:443`; because `maria.parisunitedgroup.com` is covered by
the same wildcard Origin CA cert already loaded in `ssl/origin.crt` on
the edge CT, this just works — no new certificate to mint.

## 8. Lock the CT down (recommended)

Only the edge CT should reach port 80 on `.56`; MariaDB (3306) never
leaves loopback so it needs no rule.

```bash
apt install -y nftables
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        tcp dport 22 ip saddr 192.168.100.0/24 accept
        tcp dport 80 ip saddr 192.168.100.50 accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFT
systemctl enable --now nftables
```

**Strongly recommended before this goes live:** phpMyAdmin on a public
hostname is a standing attack target even behind Cloudflare. Pick one of
the two layers below — Step 9 covers HTTP basic auth (already wired into
`lxc/nginx.conf` Host 6 in this repo), Step 9-alt covers Cloudflare Access
as the alternative.

## 9. Add HTTP basic auth in front of /phpmyadmin

This is done **on the edge-nginx CT (111)**, not on the mariadb CT — nginx
is what's terminating TLS and routing the hostname, so it's the layer that
has to prompt for credentials before the request ever reaches phpMyAdmin.

**9.1 — Install the htpasswd tool** (on CT 111):

```bash
pct enter 111
apt update && apt install -y apache2-utils
```

**9.2 — Create the credentials file** (still on CT 111):

```bash
htpasswd -c /etc/nginx/.htpasswd-maria admin
# prompts for a password twice, writes the hash to the file
chmod 640 /etc/nginx/.htpasswd-maria
chown root:www-data /etc/nginx/.htpasswd-maria 2>/dev/null || true
```

`-c` creates a **new** file — use it only the first time. To add a second
user later, run `htpasswd /etc/nginx/.htpasswd-maria another-user`
(no `-c`, or it wipes the first user).

**9.3 — Deploy the updated `lxc/nginx.conf`**

The `location /phpmyadmin/ { auth_basic ...; }` block is already in this
repo's `lxc/nginx.conf` (Host 6), ahead of the catch-all `location /`, so
only `/phpmyadmin/` prompts for a password — the sample site at `/` stays
open. Ship it and reload:

```bash
# from your workstation, in this repo
scp lxc/nginx.conf root@192.168.100.50:/etc/nginx/conf.d/default.conf

# on CT 111
nginx -t && systemctl reload nginx
```

**9.4 — Verify**

```bash
# sample site: no prompt, 200
curl -I https://maria.parisunitedgroup.com/

# phpMyAdmin: 401 without credentials
curl -I https://maria.parisunitedgroup.com/phpmyadmin/

# phpMyAdmin: 200/302 with credentials
curl -I -u admin:YOUR_PASSWORD https://maria.parisunitedgroup.com/phpmyadmin/
```

In a browser, `https://maria.parisunitedgroup.com/phpmyadmin/` should now
show a browser-native basic-auth login dialog *before* the phpMyAdmin
login page itself — two layers of credentials.

## 9-alt. Cloudflare Access instead (skip if you did Step 9)

If you'd rather gate access at Cloudflare's edge (adds SSO/email-OTP,
audit log, no shared password to leak) instead of nginx basic auth:

1. Cloudflare dashboard → **Zero Trust** → **Access** → **Applications** → **Add an application** → **Self-hosted**.
2. Application domain: `maria.parisunitedgroup.com`, Path: `/phpmyadmin*`.
3. Add a policy — e.g. **Allow** where **Emails** = your work email(s).
4. Save. Visiting `/phpmyadmin` now redirects to a Cloudflare login page
   (email OTP or your configured identity provider) before it ever reaches
   the tunnel.

Don't run both Step 9 and 9-alt at once unless you want double auth
prompts — pick one.

## 10. Verify end-to-end

```bash
# DNS resolves through Cloudflare (orange-cloud)
dig +short maria.parisunitedgroup.com

# public HTTPS, redirect, and both pages
curl -I http://maria.parisunitedgroup.com          # expect 301 -> https
curl -I https://maria.parisunitedgroup.com/health  # expect 200 "ok"
curl -I https://maria.parisunitedgroup.com/         # expect 200, sample site
curl -I https://maria.parisunitedgroup.com/phpmyadmin/   # expect 200/401 (see Step 8)
```

Open `https://maria.parisunitedgroup.com/` in a browser — you should see
the sample page's one seeded note, and `/phpmyadmin` should log in with
`sample_user` / the password from Step 3 (or `root` for full admin).
