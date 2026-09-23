# Deepsel CMS — production image.
#
# The backend (FastAPI, port 8000) builds the Astro client at startup and then
# spawns it as a child process (port 4321). That means this single image needs
# both the Python runtime AND a Node.js runtime + npm (the backend runs
# `npm install` / `npm run build` into its data dir the first time it boots).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    NODE_MAJOR=22 \
    SHELL=/bin/bash \
    LOG_LEVEL=INFO

# System deps:
#   libpq-dev / libxml2-dev / libxmlsec1-dev / pkg-config  -> compile xmlsec (python3-saml)
#   build-essential                                        -> any wheels that need a compiler
#   lsof  -> ClientProcessManager._kill_stale_port() (stale client PID cleanup)
#   curl, ca-certificates
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        git \
        lsof \
        libpq-dev \
        libxml2-dev \
        libxmlsec1-dev \
        pkg-config \
        procps \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* /root/.npm

WORKDIR /app

# Install the framework from this repo (editable: the repo root IS the package),
# with the extras the CMS needs.
COPY pyproject.toml setup.py README.md main.py settings.py db.py log_config.yml ./
COPY deepsel ./deepsel
COPY client ./client
COPY themes ./themes
COPY packages ./packages
COPY package.json package-lock.json ./
COPY scripts ./scripts
COPY MANIFEST.in ./

RUN pip install --no-cache-dir -e ".[cms,server,storage,redis]"

# Infra helper scripts.
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/set_admin.py /usr/local/bin/set_admin.py
RUN chmod +x /usr/local/bin/entrypoint.sh

# 8000 = FastAPI backend, 4321 = Astro client spawned by the backend.
EXPOSE 8000 4321

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]