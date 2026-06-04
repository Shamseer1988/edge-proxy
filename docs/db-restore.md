# Database restore — copy → restore → migrate → verify

Reusable runbook for restoring a PostgreSQL `pg_dump` (custom-format `.dump`)
into an app's LXC on Proxmox. Every gotcha hit during the first migration is
encoded here. Set the variables, then run the blocks.

> Works for all three apps — only the per-app values change (table at the bottom).

---

## Step A — copy the dump onto the CT

```cmd
:: on Windows, from the folder containing the dump
scp pug_web_db_2026-05-29_0646.dump root@192.168.100.10:/root/
```

```bash
# on the Proxmox HOST — push INTO the CT, to /tmp (so the postgres user can read it).
# VMID = the app's container: 112 corporate / 113 housing / 114 finance.
pct push 112 /root/pug_web_db_2026-05-29_0646.dump /tmp/pug_web_db_2026-05-29_0646.dump
```

---

## Step B — restore inside the CT

`pct enter 112` (or SSH in), set the variables, then run:

```bash
# ===== set these per app (see the values table) =====
DUMP=/tmp/pug_web_db_2026-05-29_0646.dump
DB=pug_holding
DBUSER=pug_user
APPUSER=pugweb
SVC="pugweb-backend"                                          # service(s) to stop
MIGRATE='cd /opt/pugweb/backend && .venv/bin/alembic upgrade head'
# =====================================================

# 1. stop the app so it isn't holding DB connections
systemctl stop $SVC

# 2. recreate the DB EMPTY + UTF-8
#    (restoring over a migrated/seeded DB => duplicate-key errors;
#     UTF-8 needs the locale generated on the CT, else the cluster is SQL_ASCII
#     and non-ASCII rows — em-dashes etc. — fail to restore)
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid<>pg_backend_pid();"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB;"
sudo -u postgres psql -c "CREATE DATABASE $DB OWNER $DBUSER ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;"

# 3. restore — --no-owner --role remaps the dump's original owner
#    (e.g. pug_website) to YOUR db user; --no-privileges skips foreign GRANTs
sudo -u postgres pg_restore --no-owner --role=$DBUSER --no-privileges -d $DB "$DUMP"

# 4. roll the schema forward to the running code's migration head
#    (the backup's schema is from its backup date)
sudo -u $APPUSER bash -lc "$MIGRATE"

# 5. start the app again
systemctl start $SVC
```

---

## Step C — verify, then clean up

```bash
sudo -u postgres psql -d $DB -c "\dt" | head
sudo -u postgres psql -d $DB -c "SELECT count(*) FROM users;"
rm "$DUMP"
```

Then reload the site — the restored content should be live.

---

## Per-app values

| App | VMID | `DB` | `DBUSER` | `APPUSER` | `SVC` (stop these) | `MIGRATE` |
|---|---|---|---|---|---|---|
| **Corporate** | 112 | `pug_holding` | `pug_user` | `pugweb` | `pugweb-backend` | `cd /opt/pugweb/backend && .venv/bin/alembic upgrade head` |
| **Housing** | 113 | `pug_accommodation` | `pug` | `housing` | `housing-backend housing-worker housing-beat` | `cd /opt/housing/backend && set -a && . ./.env && set +a && .venv/bin/flask --app wsgi migrate-all` |
| **Finance** | 114 | `pugfin_db` | `pugfin` | `pugfin` | `pugfin` | `cd /opt/pugfin && set -a && . ./.env && set +a && .venv/bin/flask --app "app:create_app()" db upgrade` |

---

## Why each step is the way it is

1. **Push to `/tmp`, not `/root`** — `sudo -u postgres` can't read root's home directory (`Permission denied`).
2. **Recreate the DB empty first** — restoring onto an already-migrated/seeded schema throws `duplicate key` / `already exists` on every table, and nothing lands.
3. **`ENCODING 'UTF8' … TEMPLATE template0`** — otherwise the DB inherits `SQL_ASCII` and any non-ASCII data fails with `UnicodeEncodeError`. Requires the UTF-8 locale to be generated on the CT first:
   ```bash
   apt install -y locales
   sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
   locale-gen && update-locale LANG=en_US.UTF-8
   ```
4. **`--no-owner --role=$DBUSER`** — the dump was created by a different role; this makes your app's user own every restored object.
5. **Migrate after restore** — the backup's schema matches its backup date; `alembic upgrade head` / `flask … upgrade` rolls it forward to match the running code.

### Troubleshooting
- `role "X" does not exist` during restore → harmless with `--no-owner`; objects are owned by `$DBUSER`.
- `permission denied for schema public` → the DB wasn't created `OWNER $DBUSER`; re-run the `CREATE DATABASE … OWNER` line.
- `Can't locate revision … in alembic_version` → the running code is *older* than the dump; `git pull` the app + reinstall deps, then migrate.
