"""Self-healing database provisioning (runs as root inside the deepsel container).

Deepsel connects with DB_USER/DB_PASSWORD, but the Postgres container creates
only POSTGRES_USER. Any mismatch between *.env values (or typos) used to break
the boot with "role does not exist" / "password authentication failed". This
script reconciles everything BEFORE migrations so the app always connects:

  * creates the DB_USER role (LOGIN) if missing, else syncs its password,
  * creates DB_NAME if it does not exist,
  * grants the role ownership-style access (DB + PUBLIC schema) so migrations
    and the auto-generated CRUD API can create tables.

It is idempotent and safe to run on every container start.
"""

import os
from urllib.parse import quote_plus

from sqlalchemy import create_engine, text

POSTGRES_DB = os.getenv("POSTGRES_DB", "deepsel")
POSTGRES_USER = os.getenv("POSTGRES_USER", "deepsel")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "deepsel") or "deepsel"
DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME") or POSTGRES_DB
DB_USER = os.getenv("DB_USER") or POSTGRES_USER
DB_PASSWORD = os.getenv("DB_PASSWORD") or POSTGRES_PASSWORD


def ident(value: str) -> str:
    return f'"{value.replace(chr(34), chr(34) * 2)}"'


if not (POSTGRES_USER and POSTGRES_PASSWORD and DB_USER and DB_PASSWORD):
    print("[db_ensure] skipping: POSTGRES_*/DB_* credentials not fully set")
    raise SystemExit(0)

super_url = (
    f"postgresql+psycopg://{quote_plus(POSTGRES_USER)}:{quote_plus(POSTGRES_PASSWORD)}"
    f"@{quote_plus(DB_HOST)}:{DB_PORT}/postgres"
)

# CREATE ROLE / CREATE DATABASE cannot run inside a transaction -> autocommit.
engine = create_engine(super_url, isolation_level="AUTOCOMMIT")

with engine.connect() as conn:
    # --- app role ---------------------------------------------------------
    exists = conn.execute(
        text("SELECT 1 FROM pg_roles WHERE rolname = :r"), {"r": DB_USER}
    ).scalar()
    if not exists:
        conn.execute(
            text(f'CREATE ROLE {ident(DB_USER)} LOGIN PASSWORD :p'), {"p": DB_PASSWORD}
        )
        print(f"[db_ensure] created role {DB_USER}")
    else:
        conn.execute(
            text(f'ALTER ROLE {ident(DB_USER)} WITH LOGIN PASSWORD :p'),
            {"p": DB_PASSWORD},
        )
        print(f"[db_ensure] role {DB_USER} ready (password synced)")

    # --- database ----------------------------------------------------------
    db_exists = conn.execute(
        text("SELECT 1 FROM pg_database WHERE datname = :d"), {"d": DB_NAME}
    ).scalar()
    if not db_exists:
        conn.execute(text(f'CREATE DATABASE {ident(DB_NAME)} OWNER {ident(DB_USER)}'))
        print(f"[db_ensure] created database {DB_NAME}")
    else:
        print(f"[db_ensure] database {DB_NAME} exists")

    # --- grants -------------------------------------------------------------
    conn.execute(
        text(f'GRANT ALL PRIVILEGES ON DATABASE {ident(DB_NAME)} TO {ident(DB_USER)}')
    )
    db_conn = create_engine(
        (
            f"postgresql+psycopg://{quote_plus(DB_USER)}:{quote_plus(DB_PASSWORD)}"
            f"@{quote_plus(DB_HOST)}:{DB_PORT}/{quote_plus(DB_NAME)}"
        ),
        isolation_level="AUTOCOMMIT",
    )
    with db_conn.connect() as dconn:
        # PG15+ restricts CREATE on the public schema to the DB owner; migrations
        # run as DB_USER, so make its own schema usable.
        dconn.execute(text(f"GRANT ALL ON SCHEMA public TO {ident(DB_USER)}"))
        try:
            dconn.execute(
                text(f"ALTER SCHEMA public OWNER TO {ident(DB_USER)}")
            )
        except Exception:  # noqa: BLE001 - owner may already be the app user
            pass
    print(f"[db_ensure] grants applied for {DB_USER} on {DB_NAME}")

engine.dispose()
print("[db_ensure] done")