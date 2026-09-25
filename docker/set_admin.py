"""Update the seeded Deepsel admin user from environment variables.

The default admin (username `admin` / password `1234`) is baked into
`deepsel/apps/core/data/user.csv` as a bcrypt hash. This script lets a
deployment override the username, password and email via the container
environment (DS_ADMIN_USERNAME / DS_ADMIN_PASSWORD / DS_ADMIN_EMAIL) without
touching the seed files.

It must run AFTER the seed step (the ONLY_MIGRATE boot) so `admin_user` exists.
The row is matched by its stable `string_id` (`admin_user`).
"""

import os
import sys

# The app code (settings.py, db.py) lives in the image WORKDIR (/app). When this
# script is run directly (docker compose exec ... python /usr/local/bin/set_admin.py)
# its own directory is on sys.path instead of cwd, so make the app dir importable.
sys.path.insert(0, os.getcwd())
sys.path.insert(0, "/app")

from passlib.context import CryptContext

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

username = os.getenv("DS_ADMIN_USERNAME") or "admin"
password = os.getenv("DS_ADMIN_PASSWORD")
email = os.getenv("DS_ADMIN_EMAIL")
if not password and not email and username == "admin":
    print("[set_admin] no DS_ADMIN_* overrides set, leaving seeded admin as-is")
    raise SystemExit(0)

try:
    from sqlalchemy import create_engine, text
    from sqlalchemy.orm import Session
except ImportError:
    create_engine = None

if create_engine is None:
    print("[set_admin] sqlalchemy not importable, skipping")
    raise SystemExit(0)

from settings import DATABASE_URL

engine = create_engine(DATABASE_URL)
updates = {"username": username}
if password:
    updates["hashed_password"] = pwd_context.hash(password)
    print("[set_admin] password updated for", username)
if email:
    updates["email"] = email

sql = f"""
UPDATE "user"
SET {", ".join(f'"{k}" = :{k}' for k in updates)}
WHERE string_id = 'admin_user'
"""
with Session(engine) as db:
    result = db.execute(text(sql), updates)
    db.commit()
    print(f"[set_admin] updated {result.rowcount} row(s) for admin_user")
engine.dispose()