# =============================================================================
# Deepsel CMS — Makefile (Docker compose + git helpers)
#
# Requires: docker (compose v2), make, git.
# Configuration lives in `.env` (copy `.env.example` -> `.env` via `make setup`).
# =============================================================================

-include .env
export

COMPOSE   := docker compose
DC        := $(COMPOSE) -f docker-compose.yaml
DCD       := $(COMPOSE) -f docker-compose.dev.yaml

STAGING_FLAG := $(if $(filter true,$(CERTBOT_STAGING)),--staging,)

.PHONY: help setup setup-git \
        dev dev-build dev-up dev-down dev-restart dev-rebuild dev-ps \
        dev-logs dev-logs-deepsel dev-logs-db dev-logs-nginx \
        deploy up build down restart restart-deepsel rebuild ps migrate exec \
        logs logs-deepsel logs-db logs-nginx logs-certbot \
        bootstrap-cert ssl-init ssl-renew \
        commit push pull git-status git-log

help:
	@echo "Deepsel CMS — available commands"
	@echo "=============================================================="
	@echo ""
	@echo "Setup:"
	@echo "  make setup            Create .env from .env.example + configure git remote"
	@echo "  make setup-git        (Re)set your git remote from GIT_REMOTE in .env"
	@echo ""
	@echo "Development (docker-compose.dev.yaml, project 'deepsel-dev'):"
	@echo "  make dev              Build + start the dev stack (db, deepsel, nginx)"
	@echo "  make dev-up           Start the dev stack (no rebuild)"
	@echo "  make dev-down         Stop the dev stack"
	@echo "  make dev-restart      Restart the dev stack"
	@echo "  make dev-rebuild      Rebuild images + recreate containers"
	@echo "  make dev-ps           Show dev container status"
	@echo "  make dev-logs         Follow ALL dev logs"
	@echo "  make dev-logs-deepsel Follow dev backend logs"
	@echo "  make dev-logs-db      Follow dev database logs"
	@echo "  make dev-logs-nginx   Follow dev nginx logs"
	@echo ""
	@echo "Production / deploy (docker-compose.yaml, project 'deepsel'):"
	@echo "  make deploy           Build images + start the prod stack (first run on a server)"
	@echo "  make build            Build prod images only"
	@echo "  make up               Start the prod stack (no rebuild)"
	@echo "  make down             Stop the prod stack"
	@echo "  make restart          Restart the whole prod stack"
	@echo "  make restart-deepsel  Restart only the deepsel service"
	@echo "  make rebuild          Rebuild + full recreate of the prod stack"
	@echo "  make ps               Show prod container status"
	@echo "  make migrate          Run ONLY the schema migration + seed data"
	@echo "  make exec            Open a shell inside the deepsel container"
	@echo ""
	@echo "Logs:"
	@echo "  make logs             Follow ALL prod logs"
	@echo "  make logs-deepsel     Follow backend logs"
	@echo "  make logs-db          Follow database logs"
	@echo "  make logs-nginx       Follow nginx logs"
	@echo "  make logs-certbot     Follow certbot logs"
	@echo ""
	@echo "SSL (Let's Encrypt / certbot):"
	@echo "  make ssl-init         Obtain the real TLS certificate for \$$(DOMAIN)"
	@echo "  make ssl-renew        Force a certificate renewal"
	@echo ""
	@echo "Git:"
	@echo "  make commit \"message\"  Stage all + commit (falls back to a dated message)"
	@echo "  make push             Push to \$$(GIT_REMOTE_NAME) / \$$(GIT_BRANCH)"
	@echo "  make pull             Pull from upstream (fallback: your remote)"
	@echo "  make git-status       git status"
	@echo "  make git-log          Recent commits"

# ------------------------------------------------------------------- Setup
setup:
	@test -f .env || cp .env.example .env
	@echo "[make] .env is ready."
	@echo "[make] Generated credentials live in .env (DS_ADMIN_PASSWORD, POSTGRES_PASSWORD, APP_SECRET)."
	@$(MAKE) setup-git

setup-git:
	@if [ -n "$(GIT_REMOTE)" ]; then \
		git remote remove $(GIT_REMOTE_NAME) 2>/dev/null || true; \
		git remote add $(GIT_REMOTE_NAME) "$(GIT_REMOTE)" && echo "[make] git remote $(GIT_REMOTE_NAME) -> $(GIT_REMOTE)"; \
	else \
		echo "[make] GIT_REMOTE is empty in .env — skipping remote setup (see git remote -v)."; \
	fi
	@git remote -v

# ------------------------------------------------------------------- Develop
dev-build:
	$(DCD) build

dev:
	@test -f .env || (echo "[make] No .env — run 'make setup' first."; exit 1)
	$(DCD) up -d --build

dev-up:
	$(DCD) up -d

dev-down:
	$(DCD) down

dev-restart:
	$(DCD) restart

dev-rebuild:
	$(DCD) up -d --build --force-recreate

dev-ps:
	$(DCD) ps

dev-logs:
	$(DCD) logs -f --tail=100

dev-logs-deepsel:
	$(DCD) logs -f --tail=100 deepsel

dev-logs-db:
	$(DCD) logs -f --tail=100 db

dev-logs-nginx:
	$(DCD) logs -f --tail=100 nginx

# ------------------------------------------------------------------- Deploy
deploy:
	@test -f .env || (echo "[make] No .env — run 'make setup' first."; exit 1)
	@test -n "$(DOMAIN)" || (echo "[make] DOMAIN is empty in .env."; exit 1)
	@$(MAKE) bootstrap-cert
	$(DC) up -d --build
	@echo "[make] Stack started. Open: https://$(DOMAIN)"
	@echo "[make] Use 'make ssl-init' to replace the bootstrap cert with a real Let's Encrypt one."

build:
	$(DC) build

up:
	$(DC) up -d

down:
	$(DC) down

restart:
	$(DC) restart

restart-deepsel:
	$(DC) restart deepsel

rebuild:
	$(DC) up -d --build --force-recreate

ps:
	$(DC) ps

migrate:
	$(DC) exec deepsel sh -lc 'ONLY_MIGRATE=true uvicorn main:app --host 0.0.0.0 --port 8000 --no-access-log'

exec:
	$(DC) exec deepsel bash

# -------------------------------------------------------------------- Logs
logs:
	$(DC) logs -f --tail=100

logs-deepsel:
	$(DC) logs -f --tail=100 deepsel

logs-db:
	$(DC) logs -f --tail=100 db

logs-nginx:
	$(DC) logs -f --tail=100 nginx

logs-certbot:
	$(DC) logs -f --tail=100 certbot

# ------------------------------------------------------------------ SSL
# Generates a throwaway self-signed cert into the live ACME path so nginx can
# start before `make ssl-init` has issued the real certificate.
bootstrap-cert:
	@if [ -z "$(DOMAIN)" ]; then echo "[make] DOMAIN is not set in .env"; exit 1; fi
	@echo "[make] Ensuring a TLS certificate exists for $(DOMAIN) ..."
	$(COMPOSE) -f docker-compose.yaml run --rm --no-deps --entrypoint sh certbot -c \
	  'if [ ! -f "/etc/letsencrypt/live/$(DOMAIN)/fullchain.pem" ]; then \
	     mkdir -p "/etc/letsencrypt/live/$(DOMAIN)"; \
	     openssl req -x509 -nodes -newkey rsa:2048 -days 825 -subj "/CN=$(DOMAIN)" \
	       -keyout "/etc/letsencrypt/live/$(DOMAIN)/privkey.pem" \
	       -out "/etc/letsencrypt/live/$(DOMAIN)/fullchain.pem"; \
	     echo "[make] Generated self-signed bootstrap cert for $(DOMAIN)"; \
	   else echo "[make] Certificate already present, nothing to do."; fi'

ssl-init:
	@test -n "$(DOMAIN)" || (echo "[make] DOMAIN is empty in .env."; exit 1)
	@test -n "$(CERTBOT_EMAIL)" || (echo "[make] CERTBOT_EMAIL is empty in .env."; exit 1)
	$(DC) up -d nginx
	$(COMPOSE) -f docker-compose.yaml run --rm --entrypoint certbot certbot certonly \
		--webroot -w /var/www/certbot \
		--email $(CERTBOT_EMAIL) -d $(DOMAIN) \
		$(STAGING_FLAG) --agree-tos --non-interactive --force-renewal
	$(DC) exec nginx nginx -s reload
	@echo "[make] TLS certificate installed for $(DOMAIN)."

ssl-renew:
	$(COMPOSE) -f docker-compose.yaml run --rm --entrypoint certbot certbot renew \
		--webroot -w /var/www/certbot --force-renewal
	$(DC) exec nginx nginx -s reload

# --------------------------------------------------------------------- Git
commit:
	@msg="$(msg)"; \
	if [ -z "$$msg" ]; then msg="$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))"; fi; \
	if [ -z "$$msg" ]; then msg="chore: update $(shell date +%F)"; fi; \
	echo "[make] Committing: $$msg"; \
	git add -A && git commit -m "$$msg"

push:
	@git push "$(GIT_REMOTE_NAME)" "$(GIT_BRANCH)"

pull:
	@if git remote | grep -q upstream; then \
		echo "[make] Pulling from upstream $(GIT_BRANCH)..."; \
		git pull --ff-only upstream "$(GIT_BRANCH)"; \
	else \
		echo "[make] Pulling from $(GIT_REMOTE_NAME) $(GIT_BRANCH)..."; \
		git pull --ff-only "$(GIT_REMOTE_NAME)" "$(GIT_BRANCH)"; \
	fi

git-status:
	git status

git-log:
	git log --oneline -15