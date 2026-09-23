#!/usr/bin/env bash
# Deepsel container entrypoint.
#
# 1. Waits for PostgreSQL.
# 2. RUN_MIGRATIONS=true (default): boots uvicorn once with ONLY_MIGRATE=true so
#    the framework creates the schema, seeds core/cms data and warms the Astro
#    client build in the persistent data volume. The process then exits cleanly.
# 3. Applies the admin credentials (username / password / email) from .env to
#    the seeded `admin_user`.
# 4. Starts the real server (uvicorn), which spawns the Astro client internally.
set -euo pipefail

echo "[deepsel] entrypoint: waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} ..."
until python - <<'PY' ${DB_HOST} ${DB_PORT}
import os, socket, sys
host = os.environ.get("DB_HOST", "db")
port = int(os.environ.get("DB_PORT", "5432"))
s = socket.socket()
s.settimeout(3)
try:
    s.connect((host, port))
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
do
    echo "[deepsel] PostgreSQL is not ready yet, retrying in 2s..."
    sleep 2
done
echo "[deepsel] PostgreSQL is ready."

if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    echo "[deepsel] Running schema migration + seed data (ONLY_MIGRATE boot)..."
    ONLY_MIGRATE=true uvicorn main:app --host 0.0.0.0 --port 8000 --log-config log_config.yml
    echo "[deepsel] Migration + first client build finished."

    if [ -n "${DS_ADMIN_USERNAME:-}" ] || [ -n "${DS_ADMIN_PASSWORD:-}" ] || [ -n "${DS_ADMIN_EMAIL:-}" ]; then
        echo "[deepsel] Applying admin credentials from environment..."
        python /usr/local/bin/set_admin.py
    fi
fi

echo "[deepsel] Starting FastAPI backend (it spawns the Astro client on :${CLIENT_PORT:-4321})..."
exec uvicorn main:app --host 0.0.0.0 --port 8000 --log-config log_config.yml ${UVICORN_ARGS:-}