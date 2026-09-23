# Deepsel CMS — self-hosted deployment (Docker + Nginx + PostgreSQL)

Развёртывание [Deepsel](https://github.com/DeepselSystems/deepsel) — open-source
CMS на FastAPI + SQLAlchemy + Astro — в собственном инфраструктурном стеке:
**Docker, Nginx, PostgreSQL**, с SSL через **certbot / Let's Encrypt**.

Репо представляет собой клон `DeepselSystems/deepsel` (весь исходный код
бэкенда, админки и тем) плюс слой деплоя: `Dockerfile`, два
`docker-compose*.yaml`, конфиги `nginx/`, `.env`, `Makefile`, `README.md`.

## Что за система

- **Бэкенд** — Python 3.12 / FastAPI. На старте сам мигрирует схему PostgreSQL,
  заливает seed-данные и **автоматически генерирует REST API** (`POST /api/v1/<table>/search`,
  CRUD для каждой модели, CSV export/import) и GraphQL. Swagger-документация — на
  `/` (порт 8000).
- **Фронтенд** — Astro (SSR). Один и тот же процесс отдаёт и публичный сайт, и
  админку `/admin`. Бэкенд при старте собирает клиент (`npm install` + `npm run build`)
  и запускает его как дочерний процесс (порт 4321).
- **Темы** — `.astro`-темы в `themes/` (по умолчанию `paper`, `claw_code`).
  В админке можно редактировать файлы темы (HTML/CSS/JS, Tailwind, любые
  стили/анимации) — сохранение пересобирает клиент. Можно подключать Bootstrap,
  Tailwind и любые CSS-фреймворки.
- **AI / «вайбкодинг» фронтенда** — в админке есть генерация страниц, шаблонов
  (Jinja2), текстов, chatbox и переводы через LLM. Подробнее — в разделе «AI».

## Архитектура контейнеров

| Сервис | Порт внутр. | Назначение |
|---|---|---|
| `db` | 5432 | PostgreSQL 16 |
| `deepsel` | 8000 (API) + 4321 (клиент) | FastAPI бэкенд + Astro клиент |
| `nginx` | 80 / 443 | reverse proxy, TLS, ACME-webroot |
| `certbot` | — | выпуск и автообновление сертификатов |

Тома: `pgdata` (БД), `deepsel-data` (собранный клиент, темы, оверлеи орг. —
`~/.local/share/deepsel-cms`), `deepsel-files` (загруженные файлы при
`FILESYSTEM=local`), `certbot-www` / `certbot-certs` / `certbot-certs-data` (TLS).

## Требования

- Docker 24+ с compose v2 (`docker compose version`)
- `make`, `git`
- Домен, указывающий A/AAAA-записью на IP сервера (для продакшена)
- Трафик наружу: в контейнерах нужен доступ к npm-реестрам (первая сборка
  клиента), PyPI (сборка образа), Let's Encrypt и OpenRouter (для AI-функций)

## Быстрый старт

### 1. Конфигурация

```bash
make setup          # создаст .env из .env.example (+ настроит git remote)
nano .env           # домен, пароли, CERTBOT_EMAIL
```

Минимально правим: `DOMAIN`, `CERTBOT_EMAIL`, `DS_ADMIN_PASSWORD`,
`POSTGRES_PASSWORD` (и `DS_ADMIN_USERNAME`/`DS_ADMIN_EMAIL` при желании).

### 2. Локальная разработка

```bash
make dev            # сборка + старт dev-стека (db, deepsel с --reload, nginx)
```

| Что | URL |
|---|---|
| Сайт + админка (через nginx) | http://localhost:8080 |
| Админка напрямую (клиент) | http://localhost:4321/admin |
| Бэкенд / API / Swagger | http://localhost:8000 |
| PostgreSQL | localhost:5432 (логин/пароль из .env) |

В dev-режиме исходники примонтированы в контейнер (`.:/app`), uvicorn работает
с `--reload` — правки Python-кода подхватываются сразу. Клиент пересобирается
бэкендом при старте или из админки (редактор тем). Секьюрные cookie отключены
(`SESSION_COOKIE_SECURE=false`), т.к. dev работает по HTTP.

Первая миграция и сборка клиента занимают несколько минут — это нормально,
потом кэш лежит в томах.

### 3. Продакшен-деплой

```bash
make deploy         # bootstrap-сертификат + подъём стека
make ssl-init       # выпустить настоящий SSL у Let's Encrypt
```

`make deploy` поднимает стек даже без выпущенного сертификата: генерируется
временный self-signed сертификат, чтобы nginx стартовал. Затем `make ssl-init`
выпускает настоящий сертификат через ACME-webroot и перечитывает nginx.
Дальше certbot-контейнер сам продлевает сертификат каждые 12 часов.

```bash
make up             # просто запустить (без пересборки)
make down           # остановить
make restart        # перезапустить
make ps             # статус
```

## Переменные окружения (.env)

| Переменная | Описание |
|---|---|
| `DOMAIN` | Публичный домен CMS (например `cms.hyperlowx.tech`) |
| `CERTBOT_EMAIL` | Email для Let's Encrypt |
| `CERTBOT_STAGING` | `true` = тестовая CA (без лимитов, фейковые серты) |
| `POSTGRES_DB/USER/PASSWORD` | Создаются в контейнере PostgreSQL |
| `DB_HOST/PORT/NAME/USER/PASSWORD` | Параметры подключения бэкенда (внутри сети `DB_HOST=db`) |
| `DS_ADMIN_USERNAME/PASSWORD/EMAIL` | Логин для `/admin` (применяется контейнерным скриптом `docker/set_admin.py`) |
| `APP_SECRET` | Секрет JWT/сессий и шифрования API-ключей (`openssl rand -hex 32`) |
| `FRONTEND_URL` | Публичный URL (ссылки в письмах, canonical) |
| `CORS_ALLOWED_ORIGINS` | Разрешённые origin'ы запятой |
| `FILESYSTEM` | `local` \| `s3` \| `azure` (хранение загрузок) |
| `UPLOAD_SIZE_LIMIT` | Макс. размер загрузки, МБ (у nginx лимит 20m — поднимите при необходимости) |
| `SESSION_STORE` | `postgres` (по умолчанию) \| `redis` \| `filesystem` |
| `SESSION_COOKIE_SECURE` | `true` в проде (HTTPS) |
| `INSTALLED_APPS` | `core,cms` |
| `ENABLE_GRAPHQL` / `ENABLE_DOCS` | Вкл. GraphQL и Swagger (на `/` бэкенда) |
| `LOG_LEVEL` | `INFO` / `WARNING` / `DEBUG` |
| `GIT_REMOTE` / `GIT_REMOTE_NAME` / `GIT_BRANCH` | Для `make push/pull/setup-git` |

Полный список поддерживаемых бэкенд-переменных (S3/Azure, ClamAV, OIDC и т.д.) —
в `settings.py` репозитория.

## Команды Makefile

**Разработка**

```bash
make dev                  # сборка + старт dev-стека
make dev-up / dev-down    # старт / стоп без пересборки
make dev-restart          # рестарт
make dev-logs             # логи всех сервисов
make dev-logs-deepsel     # логи бэкенда
make dev-logs-db          # логи БД
make dev-logs-nginx       # логи nginx
make dev-ps               # статус
```

**Деплой**

```bash
make deploy               # сборка + старт прод-стека (делает bootstrap-cert)
make build                # пересобрать образы
make up / down / restart  # старт / стоп / рестарт
make restart-deepsel      # рестарт только бэкенда (после правок тем/моделей)
make rebuild              # пересборка + --force-recreate
make ps                   # статус
make migrate              # прогон миграций без перезапуска сервиса
make exec                 # bash внутри контейнера deepsel
```

**Логи**

```bash
make logs                 # все прод-сервисы (follow)
make logs-deepsel         # бэкенд
make logs-db              # PostgreSQL
make logs-nginx           # nginx
make logs-certbot         # certbot
```

**Git**

```bash
make commit "feat: ..."   # git add -A + commit (без сообщения — подставится дата)
make push                 # push в свой remote
make pull                 # pull из upstream (или своего remote)
make git-status / git-log # статус / история
```

**SSL**

```bash
make ssl-init             # выпустить настоящий сертификат для DOMAIN
make ssl-renew            # принудительное продление
```

## Обновление системы

```bash
make pull                 # подтянуть свежий код deepsel
make rebuild              # пересобрать образы и пересоздать контейнеры
```

Персистентность в томах (`pgdata`, `deepsel-data`, `deepsel-files`, `certbot-*`)
сохраняется. Бэкенд при старте сам выполнит миграции схемы и seed-обновления.

## AI / LLM: подключение нейросети (в т.ч. своей)

Все AI-функции (генерация страниц, Jinja2-шаблонов для сайта, автодополнение,
чат, переводы) работают через **OpenRouter** — единый OpenAI-совместимый
API-прокси, за которым лежат OpenAI, DeepSeek, Google Gemini, Anthropic и сотни
других моделей.

- Ключ **OpenRouter** и выбор моделей задаются **в админке**: настройки
  организации (Organization settings). Ключ хранится зашифрованным в БД
  (env-переменной для него нет — сознательно).
- Чтобы использовать **локальную/свою нейросеть** (DeepSeek через свой
  инстанс, Ollama, vLLM и т.п.), поднимите любой OpenAI-совместимый шлюз и
  добавьте в БД/админке запись модели с нужным `string_id` и URL — бэкенд
  ходит в OpenRouter-совместимый `/api/v1/chat/completions`. См.
  `deepsel/apps/cms/models/openrouter_model.py` и `routers/chat.py`.
- «Генерация кода» сайта: в админке (страницы / шаблоны / темы) можно
  попросить LLM сгенерировать Jinja2-шаблон или контент — и сохранить его в
  редакторе темы для пересборки сайта.

## REST API и сложная логика

Deepsel сам генерирует CRUD API для всех моделей: `POST /api/v1/<table>/search`,
`GET/PUT/DELETE /api/v1/<table>/{id}`, bulk-delete, export/import CSV,
GraphQL (`/graphql`), uploads `/api/v1/attachment`.

Схема запроса поиска:

```bash
curl -X POST http://localhost:8000/api/v1/page/search?skip=0&limit=50 \
  -H 'Content-Type: application/json' \
  -d '{"search":{"AND":[{"field":"status","operator":"=","value":"published"}]},"order_by":{"field":"created_at","direction":"desc"}}'
```

Кастомная логика добавляется в виде **собственного python-приложения**: модели в
`apps/<myapp>/models/*.py`, кастомные роутеры в `routers/*.py`, seed-data в
`data/*.csv` — всё автообнаруживается и монтируется бэкендом. Свой код можно
держать прямо в этом репозитории (папка `apps/`), либо поднимать отдельные
контейнеры и обращаться к PostgreSQL/API по сети. См. справочник конвенций в
`AGENTS.md` репозитория.

## Troubleshooting

- **Долгий первый запуск** — бэкенд собирает клиент (`npm install` +
  `npm run build`) в `deepsel-data`. Загляните в `make logs-deepsel`:
  должно быть `Theme setup completed in ...`.
- **502 Bad Gateway у nginx** — клиент ещё стартует (или упал). Проверьте
  `make logs-deepsel`.
- **Логин в админке не проходит** — убедитесь, что `DS_ADMIN_PASSWORD` применён
  (см. `make logs-deepsel` при старте) и что после `make deploy` в браузере
  открыт `https://DOMAIN/admin`.
- **Сертификат не выпускается** — проверьте что `DOMAIN` резолвится на сервер
  и порт 80 открыт извне. Для отладки поставьте `CERTBOT_STAGING=true`.
- **PG-пароль из seed-данных** — при `ONLY_MIGRATE`-запуске применяются
  переменные `DB_*` из `.env`. Если они отличаются от `POSTGRES_*`, бэкенд не
  сможет подключиться.

## Структура

```
.
├── docker-compose.yaml        # prod: db, deepsel, nginx, certbot
├── docker-compose.dev.yaml    # dev:  + reload, проброшенные порты
├── Dockerfile                 # imagem бэкенда (Python 3.12 + Node 22)
├── Makefile                   # команды dev/deploy/logs/git/ssl
├── .env.example / .env        # конфигурация (.env в .gitignore)
├── docker/
│   ├── entrypoint.sh          # ожидание БД, миграции, применение админа
│   └── set_admin.py           # применение DS_ADMIN_* к админ-пользователю
├── nginx/
│   ├── nginx.conf             # базовая HTTP-конфигурация
│   ├── dev.conf               # server-блок для dev
│   └── prod.conf.template     # prod + ACME-webroot (envsubst по DOMAIN)
└── ... (исходники Deepsel: deepsel/, client/, themes/, packages/)
```