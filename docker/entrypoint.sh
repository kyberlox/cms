#!/usr/bin/env bash
# Deepsel container entrypoint (self-healing / zero-config).
#
# 1. Waits for PostgreSQL, falling back to the compose service name `db` if
#    DB_HOST/DB_PORT can't be reached (e.g. a wrong value in .env).
# 2. Reconciles the DB: creates the app role + database + grants if needed
#    (docker/db_ensure.py), so POSTGRES_USER vs DB_USER mismatches don't matter.
# 3. RUN_MIGRATIONS=true (default): boots uvicorn once with ONLY_MIGRATE=true so
#    the framework creates the schema, seeds core/cms data and warms the Astro
#    client build in the persistent data volume. If that boot fails it does NOT
#    crash-loop the container — the main server boot re-tries migrations.
# 4. Applies the admin credentials (username / password / email) to the seeded
#    `admin_user` (only after a successful migration so the row exists).
# 5. Starts the real server (uvicorn), which spawns the Astro client internally.
set -euo pipefail

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"

# Self-heal a wrong DB_HOST from .env: if the primary host is unreachable and
# `db` is not the same value, switch to the compose service name `db`.
_can_connect() {
    python - "$1" "$2" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    ok = True
except Exception:
    ok = False
finally:
    s.close()
sys.exit(0 if ok else 1)
PY
}

echo "[deepsel] entrypoint: waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} ..."
if [ "$DB_HOST" != "db" ] && ! _can_connect "$DB_HOST" "$DB_PORT" && _can_connect "db" "$DB_PORT"; then
    echo "[deepsel] DB_HOST=$DB_HOST unreachable; falling back to db (compose service name)"
    export DB_HOST=db
fi

until _can_connect "$DB_HOST" "$DB_PORT"; do
    echo "[deepsel] PostgreSQL is not ready yet, retrying in 2s..."
    sleep 2
done
echo "[deepsel] PostgreSQL is ready."

python /usr/local/bin/db_ensure.py || echo "[deepsel] WARNING: db_ensure failed (continuing)"

if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    echo "[deepsel] Running schema migration + seed data (ONLY_MIGRATE boot)..."
    if ONLY_MIGRATE=true uvicorn main:app --host 0.0.0.0 --port 8000 --log-config log_config.yml; then
        echo "[deepsel] Migration + first client build finished."

        if [ -n "${DS_ADMIN_USERNAME:-}" ] || [ -n "${DS_ADMIN_PASSWORD:-}" ] || [ -n "${DS_ADMIN_EMAIL:-}" ]; then
            echo "[deepsel] Applying admin credentials from environment..."
            python /usr/local/bin/set_admin.py || echo "[deepsel] WARNING: set_admin failed (ignored)"
        fi
    else
        echo "[deepsel] WARNING: migration boot exited non-zero; the main boot below will retry. Check 'docker compose logs deepsel'."
    fi
fi

echo "[deepsel] Starting FastAPI backend (it spawns the Astro client on :${CLIENT_PORT:-4321})..."
exec uvicorn main:app --host 0.0.0.0 --port 8000 --log-config log_config.yml ${UVICORN_ARGS:-}