#!/usr/bin/env bash
#
# legal-deploy.sh — redeploy / update the PUG Legal Case Filing System on CT 116
# (legal.parisunitedgroup.com). Pulls the latest code, refreshes backend deps +
# DB schema, rebuilds the Next.js frontend, and restarts the systemd services.
# Idempotent — safe to re-run.
#
# Install on the legal CT (as root):
#     cp /opt/pug-legal/... or scp this file to  /opt/deploy.sh
#     chmod +x /opt/deploy.sh
#     /opt/deploy.sh
#
# Optional env toggles:
#     SKIP_BACKUP=1     skip the pre-migrate Postgres dump
#     SKIP_BACKEND=1    leave the backend untouched (no deps/migrate/restart)
#     SKIP_FRONTEND=1   leave the frontend untouched (no rebuild/restart)
#
# NOTE: this updates the APP on CT 116 only. Edge nginx changes (lxc/nginx.conf)
# are deployed separately on the edge CT (.50): git pull -> cp -> nginx -t -> reload.
#
set -euo pipefail

# ---- config (edit only if your paths differ) ----
APP_DIR=/opt/pug-legal
APP_USER=pug
ENV_FILE=/etc/pug-legal/.env
DB_NAME=pug_legal
BACKUP_DIR=/var/backups/pug-legal
BACKEND_SVC=pug-backend
FRONTEND_SVC=pug-frontend

if [ -t 1 ]; then B=$'\033[1;34m'; Y=$'\033[1;33m'; X=$'\033[0m'; else B=; Y=; X=; fi
log()  { echo "${B}==> $*${X}"; }
warn() { echo "${Y}WARN: $*${X}" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

git_app()   { sudo -u "$APP_USER" git -C "$APP_DIR" "$@"; }
build_app() { sudo -u "$APP_USER" bash -lc "$1"; }

# ---- preflight ----
[ "$(id -u)" -eq 0 ]   || die "run as root (this restarts systemd services)."
[ -d "$APP_DIR/.git" ] || die "$APP_DIR is not a git checkout."
[ -f "$ENV_FILE" ]     || die "missing $ENV_FILE."
command -v npm >/dev/null 2>&1 || die "npm not found on PATH."
if [ "${SKIP_FRONTEND:-0}" != 1 ] && [ ! -f "$APP_DIR/frontend/.env.production" ]; then
  die "missing $APP_DIR/frontend/.env.production — NEXT_PUBLIC_API_URL would bake wrong.
     Create it (NEXT_PUBLIC_API_URL=https://legal.parisunitedgroup.com) or set SKIP_FRONTEND=1."
fi

# ---- 0. normalize ownership (self-heal) ----
# A stray root-run 'git'/edit under $APP_DIR leaves root-owned files that block
# the pug-user pull/build (e.g. "cannot open '.git/FETCH_HEAD': Permission
# denied"). Re-own anything misowned, skipping node_modules/.venv (npm ci / pip
# rebuild those as $APP_USER, so chowning them would just be wasted work).
log "Normalizing ownership under $APP_DIR"
find "$APP_DIR" \
     -path "$APP_DIR/frontend/node_modules" -prune -o \
     -path "$APP_DIR/backend/.venv" -prune -o \
     ! -user "$APP_USER" -print0 | xargs -0r chown -h "$APP_USER:$APP_USER"

# ---- 1. pre-migrate DB backup (rollback safety) ----
if [ "${SKIP_BACKUP:-0}" != 1 ] && [ "${SKIP_BACKEND:-0}" != 1 ]; then
  log "Backing up database '$DB_NAME'"
  mkdir -p "$BACKUP_DIR"
  ts=$(date +%Y%m%d-%H%M%S)
  sudo -u postgres pg_dump "$DB_NAME" | gzip > "$BACKUP_DIR/predeploy-$ts.sql.gz"
  echo "    -> $BACKUP_DIR/predeploy-$ts.sql.gz"
  find "$BACKUP_DIR" -name 'predeploy-*.sql.gz' -mtime +14 -delete 2>/dev/null || true
else
  log "Skipping DB backup"
fi

# ---- 2. pull latest code ----
log "Pulling latest code in $APP_DIR"
before=$(git_app rev-parse --short HEAD)
git_app pull --ff-only
after=$(git_app rev-parse --short HEAD)
if [ "$before" = "$after" ]; then echo "    already at $after (no new commits)"; else echo "    $before -> $after"; fi

# ---- 3. backend: venv + deps + schema ----
if [ "${SKIP_BACKEND:-0}" != 1 ]; then
  log "Updating backend (deps + migrations)"
  build_app "
    set -euo pipefail
    set -a; . '$ENV_FILE'; set +a
    cd '$APP_DIR/backend'
    [ -d .venv ] || python3 -m venv .venv
    .venv/bin/pip install -q --upgrade pip wheel
    .venv/bin/pip install -q -e '.[reports]'
    .venv/bin/alembic upgrade head
  "
else
  log "Skipping backend"
fi

# ---- 4. frontend: install + production build (no-lint) ----
if [ "${SKIP_FRONTEND:-0}" != 1 ]; then
  log "Building frontend (next build --no-lint)"
  build_app "
    set -euo pipefail
    cd '$APP_DIR/frontend'
    npm ci
    npm run build -- --no-lint
  "
else
  log "Skipping frontend"
fi

# ---- 5. restart services ----
svcs=()
[ "${SKIP_BACKEND:-0}"  != 1 ] && svcs+=("$BACKEND_SVC")
[ "${SKIP_FRONTEND:-0}" != 1 ] && svcs+=("$FRONTEND_SVC")
if [ "${#svcs[@]}" -gt 0 ]; then
  log "Restarting: ${svcs[*]}"
  systemctl restart "${svcs[@]}"
  for s in "${svcs[@]}"; do echo "    $s: $(systemctl is-active "$s")"; done
fi

# ---- 6. health checks ----
check() {  # label  url
  for _ in $(seq 1 15); do
    if curl -fsS -o /dev/null "$2"; then echo "    OK   $1"; return 0; fi
    sleep 2
  done
  echo "    FAIL $1  ($2)"; return 1
}
log "Health checks"
rc=0
[ "${SKIP_BACKEND:-0}"  != 1 ] && { check "backend  /api/v1/health" http://127.0.0.1:8000/api/v1/health || rc=1; }
[ "${SKIP_FRONTEND:-0}" != 1 ] && { check "frontend :3000"          http://127.0.0.1:3000              || rc=1; }

echo
if [ "$rc" -eq 0 ]; then
  log "Deploy complete — now at $after"
  echo "    public:  curl -I https://legal.parisunitedgroup.com/health   # expect 200"
else
  die "one or more health checks failed — inspect: journalctl -u $BACKEND_SVC -n 50 --no-pager"
fi
