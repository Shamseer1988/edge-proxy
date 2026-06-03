# edge-proxy — standalone TLS terminator for the PUG host

This is a self-contained compose stack that runs nginx in front of one
or more app stacks on the same Docker host. It terminates TLS using a
Cloudflare Origin Certificate, enforces a Cloudflare-edge IP allowlist
(so direct-IP probes are dropped), and reverse-proxies into each app
over the shared external network `pug_edge`.

## Layout

```
edge-proxy/
├── docker-compose.yml          # one service: nginx, binds 80/443
├── Dockerfile.nginx            # bakes nginx.conf + snippets into image
├── nginx.conf                  # vhost + upstream definitions
├── snippets/                   # shared include files
│   ├── proxy-common.conf
│   ├── security-headers.conf
│   └── ssl-common.conf
├── ssl/                        # Cloudflare Origin Cert files (you paste)
│   ├── README.txt
│   ├── origin.crt              # YOU CREATE — gitignored
│   └── origin.key              # YOU CREATE — gitignored
├── .gitignore
└── README.md                   # this file
```

## One-time setup

```cmd
:: 1. Create the shared bridge network (idempotent — error if exists is OK).
docker network create pug_edge

:: 2. Paste your Cloudflare Origin Cert into ssl/origin.crt + ssl/origin.key
::    (see ssl/README.txt for the minting recipe)

:: 3. Build + start
docker compose up -d --build
docker compose ps
```

Expect `Up (healthy)` on the nginx service within ~30 seconds.

## Daily ops

```cmd
:: Live reload after editing nginx.conf or snippets/*:
docker compose build nginx
docker compose up -d nginx

:: Live cert rotation (drop new files into ssl/ first):
docker compose exec nginx nginx -s reload

:: Verify config syntactically:
docker compose exec nginx nginx -t

:: Tail logs:
docker compose logs -f nginx
```

## How upstream apps plug in

Each app stack joins the same `pug_edge` external network and exposes
its HTTP service under a stable alias. The aliases this nginx
references in `nginx.conf` are:

| Alias              | Used by                                 |
|--------------------|-----------------------------------------|
| `housing-backend`  | Employee Housing Portal — Flask         |
| `housing-frontend` | Employee Housing Portal — Next.js       |
| `pugfin-backend`   | Finance app — Flask (planned)           |
| `pugfin-frontend`  | Finance app — Next.js (planned)         |
| `pugweb-api`       | Corporate site — FastAPI (planned)     |
| `pugweb-frontend`  | Corporate site — Next.js (planned)     |

Each app stack declares the alias under its `networks: edge: aliases:`
block. See the Employee Housing Portal repo's `docker-compose.prod.yml`
for the canonical example.

## Migrating off the old in-stack nginx

If you're moving from the prior "nginx inside the housing compose
stack" setup, the transition is:

```cmd
:: 1. Make sure the housing stack is up on the refactored compose
::    (already joins pug_edge):
cd C:\Apps\Employee-Housing-Control-Portal
docker compose -f docker-compose.prod.yml up -d

:: 2. Remove the orphan nginx container from the old stack:
docker rm -f pug-accommodation-prod-nginx-1

:: 3. Bring this edge proxy up (takes over 80/443):
cd C:\Apps\edge-proxy
docker compose up -d --build

:: 4. Verify from outside:
curl -I https://accommodation.parisunitedgroup.com/health
```

Brief gap on 80/443 between steps 2 and 3 (typically ~5 seconds).
For zero-downtime, bring the new edge proxy up on a different host
port first, then swap, then stop the old one.

## Maintenance — keeping Cloudflare IP ranges fresh

Cloudflare occasionally adds new edge subnets. Quarterly check:

```cmd
curl -s https://www.cloudflare.com/ips-v4 -o cf-v4.txt
:: Diff against the set_real_ip_from + geo blocks at the top of nginx.conf
:: Update both blocks if anything changed, then:
docker compose build nginx && docker compose up -d nginx
```
