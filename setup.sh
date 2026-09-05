#!/bin/sh
# setup.sh — разворачивает Vikunja (Postgres + Redis + приложение) "с нуля"
# без ручных действий. Совместимо с POSIX sh (запускается как /bin/sh setup.sh).
#
# Что делает:
#   1. Проверяет наличие docker / git / openssl / curl.
#   2. Клонирует upstream-репозиторий Vikunja на зафиксированный коммит.
#   3. Кладёт в него наш Dockerfile, docker-compose.yml и seed_data.sql.
#   4. Генерирует .env со случайными паролями (один раз, при первом запуске).
#   5. Собирает и поднимает контейнеры, дожидается healthy у всех сервисов.
#   6. Прогоняет миграции БД, затем загружает полный набор тестовых данных
#      напрямую в Postgres (пользователи, проекты, все 4 view, buckets,
#      задачи, метки, назначения, комментарий, команда с шарингом).
#   7. Печатает итоговый адрес приложения и код ответа быстрой проверки.
#
# Идемпотентность: повторный запуск не пересоздаёт .env, не загружает
# тестовые данные повторно (проверяется наличие пользователя 'admin')
# и не останавливает уже работающие контейнеры дольше, чем требуется
# для docker compose up -d.

set -eu

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------

REPO_URL="https://github.com/go-vikunja/vikunja.git"
# Требование "Фиксация версии upstream-проекта": клонируем строго по хэшу коммита.
REPO_REF="98b81df"
PROJECT_DIR="vikunja"
ENV_FILE="$PROJECT_DIR/.env"
SEED_FILE="$PROJECT_DIR/seed_data.sql"

# Тестовые учётки, создаваемые seed_data.sql (см. сам файл) — не секреты,
# это фиксированные тестовые данные для локальной разработки/демо.
SEED_TEST_USER="admin"
SEED_TEST_PASSWORD="password123"

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

log() {
    printf '>>> %s\n' "$*"
}

err() {
    printf 'ERROR: %s\n' "$*" >&2
}

need_cmd() {
    # $1 — имя команды, $2 — человекочитаемое сообщение об установке
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Не найдена команда '$1'. $2"
        exit 1
    fi
}

compose() {
    (cd "$PROJECT_DIR" && docker compose "$@")
}

# Ждём, пока контейнер с именем $1 не станет healthy (или не истечёт таймаут $2 сек).
wait_healthy() {
    container="$1"
    timeout="${2:-120}"
    waited=0

    while true; do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || printf 'unknown')

        if [ "$status" = "healthy" ]; then
            log "$container: healthy"
            return 0
        fi

        if [ "$status" = "unhealthy" ]; then
            err "$container перешёл в состояние unhealthy. Последние логи:"
            docker logs --tail 50 "$container" || true
            return 1
        fi

        if [ "$waited" -ge "$timeout" ]; then
            err "Не дождались healthy для $container за ${timeout}s (статус: $status). Последние логи:"
            docker logs --tail 50 "$container" || true
            return 1
        fi

        sleep 3
        waited=$((waited + 3))
    done
}

# ---------------------------------------------------------------------------
# 1. Проверка окружения
# ---------------------------------------------------------------------------

log "Проверяю наличие необходимых утилит..."

need_cmd docker "Установите Docker: https://docs.docker.com/engine/install/"
need_cmd git "Установите Git (пакет 'git' в вашем дистрибутиве)."
need_cmd openssl "Установите openssl (пакет 'openssl')."
need_cmd curl "Установите curl (пакет 'curl')."

if ! docker compose version >/dev/null 2>&1; then
    err "Плагин 'docker compose' (v2) недоступен. Обновите Docker до версии с поддержкой Compose v2."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Docker daemon недоступен. Убедитесь, что Docker запущен и у пользователя есть права на него."
    exit 1
fi

log "Все необходимые утилиты найдены."

# ---------------------------------------------------------------------------
# 2. Клонирование upstream-репозитория на зафиксированный коммит
# ---------------------------------------------------------------------------

if [ -d "$PROJECT_DIR/.git" ]; then
    log "Репозиторий уже склонирован в ./$PROJECT_DIR — обновляю ссылки и переключаюсь на $REPO_REF."
    git -C "$PROJECT_DIR" fetch --tags --force origin
    git -C "$PROJECT_DIR" checkout --force "$REPO_REF"
else
    log "Клонирую $REPO_URL в ./$PROJECT_DIR ..."
    git clone "$REPO_URL" "$PROJECT_DIR"
    git -C "$PROJECT_DIR" checkout --force "$REPO_REF"
fi

log "Текущий коммит: $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# 3. Dockerfile и docker-compose.yml — не входят в upstream, кладём сами
# ---------------------------------------------------------------------------

log "Записываю Dockerfile и docker-compose.yml в ./$PROJECT_DIR ..."

cat > "$PROJECT_DIR/Dockerfile" <<'DOCKERFILE_EOF'
# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
FROM --platform=$BUILDPLATFORM node:24.20.0-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf AS frontendbuilder

WORKDIR /build

ENV PNPM_CACHE_FOLDER=.cache/pnpm/
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV CYPRESS_INSTALL_BINARY=0

COPY frontend/pnpm-lock.yaml frontend/package.json frontend/pnpm-workspace.yaml ./
RUN npm install -g corepack && corepack enable && \
    pnpm install --frozen-lockfile
COPY frontend/ ./
ARG RELEASE_VERSION=dev
RUN echo "{\"VERSION\": \"${RELEASE_VERSION/-g/-}\"}" > src/version.json && pnpm run build

FROM --platform=$BUILDPLATFORM ghcr.io/techknowlogick/xgo:go-1.27.x@sha256:8cc742b41f043a4fd45d2f63f1fcd12cb27949342df09efb5561f2aadfbe6da3 AS apibuilder

RUN go install github.com/magefile/mage@latest && \
    mv /go/bin/mage /usr/local/go/bin

WORKDIR /go/src/code.vikunja.io/api
COPY . ./
COPY --from=frontendbuilder /build/dist ./frontend/dist

ARG TARGETOS TARGETARCH TARGETVARIANT RELEASE_VERSION
ENV RELEASE_VERSION=$RELEASE_VERSION

RUN export PATH=$PATH:$GOPATH/bin && \
    mage build:clean && \
    (cd build && mage release:xgo vikunja "${TARGETOS}/${TARGETARCH}/${TARGETVARIANT}")

RUN mkdir -p /tmp && chmod 1777 /tmp

# The actual image
FROM alpine

LABEL org.opencontainers.image.authors='maintainers@vikunja.io'
LABEL org.opencontainers.image.url='https://vikunja.io'
LABEL org.opencontainers.image.documentation='https://vikunja.io/docs'
LABEL org.opencontainers.image.source='https://code.vikunja.io/vikunja'
LABEL org.opencontainers.image.licenses='AGPLv3'
LABEL org.opencontainers.image.title='Vikunja'

WORKDIR /app/vikunja
ENTRYPOINT [ "/app/vikunja/vikunja" ]
EXPOSE 3456

COPY --from=apibuilder --chown=1000:1000 --chmod=1777 /tmp /tmp

USER 1000

ENV VIKUNJA_SERVICE_ROOTPATH=/app/vikunja/
ENV VIKUNJA_DATABASE_PATH=/db/vikunja.db

COPY --from=apibuilder /build/vikunja-* vikunja
COPY --from=apibuilder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
DOCKERFILE_EOF

cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE_EOF'
services:

  app:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        RELEASE_VERSION: ${RELEASE_VERSION:-dev}
    image: vikunja:${RELEASE_VERSION:-dev}
    container_name: vikunja-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "${APP_PORT:-3456}:3456"
    environment:
      VIKUNJA_SERVICE_ROOTPATH: /app/vikunja/
      VIKUNJA_SERVICE_SECRET: ${JWT_SECRET}
      VIKUNJA_SERVICE_PUBLICURL: ${APP_PUBLIC_URL:-http://localhost:3456}
      VIKUNJA_FILES_BASEPATH: /tmp/files
      VIKUNJA_DATABASE_TYPE: postgres
      VIKUNJA_DATABASE_HOST: ${DB_HOST:-db}
      VIKUNJA_DATABASE_PORT: ${DB_PORT:-5432}
      VIKUNJA_DATABASE_USER: ${DB_USER}
      VIKUNJA_DATABASE_PASSWORD: ${DB_PASSWORD}
      VIKUNJA_DATABASE_DATABASE: ${DB_NAME}
      VIKUNJA_REDIS_ENABLED: "true"
      VIKUNJA_REDIS_HOST: ${REDIS_HOST:-redis}:${REDIS_PORT:-6379}
      VIKUNJA_REDIS_PASSWORD: ${REDIS_PASSWORD}
      VIKUNJA_CACHE_ENABLED: "true"
      VIKUNJA_CACHE_TYPE: redis
    volumes:
      - vikunja_files:/tmp
    mem_limit: ${APP_MEM_LIMIT:-512m}
    cpus: ${APP_CPUS:-1.0}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3456/api/v1/info"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 15s

  db:
    image: postgres:16-alpine
    container_name: vikunja-db
    restart: unless-stopped
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - vikunja_db_data:/var/lib/postgresql/data
    mem_limit: ${DB_MEM_LIMIT:-512m}
    cpus: ${DB_CPUS:-0.5}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  redis:
    image: redis:7-alpine
    container_name: vikunja-redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - vikunja_redis_data:/data
    mem_limit: ${REDIS_MEM_LIMIT:-256m}
    cpus: ${REDIS_CPUS:-0.25}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

volumes:
  vikunja_db_data:
  vikunja_redis_data:
  vikunja_files:
COMPOSE_EOF

cat > "$SEED_FILE" <<'SEED_EOF'
-- ============================================================
-- Тестовые данные для Vikunja
-- Пароль для всех пользователей ниже: password123
-- (bcrypt hash, cost=12, совместим с golang.org/x/crypto/bcrypt)
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- Пользователи
-- ------------------------------------------------------------
INSERT INTO public.users
    (id, name, username, password, email, status, is_admin,
     email_reminders_enabled, discoverable_by_name, discoverable_by_email,
     overdue_tasks_reminders_enabled, overdue_tasks_reminders_time,
     week_start, "language", timezone, created, updated)
VALUES
    (1, 'Admin User', 'admin',
     '$2b$12$yyBGDpxwrEs2wvFjk3YF/esh4HPmyUJfdRCrFw4NMPyhI141A5IyC',
     'admin@example.com', 0, true, true, false, false, true, '09:00',
     1, 'en', 'UTC', now(), now()),
    (2, 'Alice Tester', 'alice',
     '$2b$12$yyBGDpxwrEs2wvFjk3YF/esh4HPmyUJfdRCrFw4NMPyhI141A5IyC',
     'alice@example.com', 0, false, true, false, false, true, '09:00',
     1, 'en', 'UTC', now(), now()),
    (3, 'Bob Tester', 'bob',
     '$2b$12$yyBGDpxwrEs2wvFjk3YF/esh4HPmyUJfdRCrFw4NMPyhI141A5IyC',
     'bob@example.com', 0, false, true, false, false, true, '09:00',
     1, 'en', 'UTC', now(), now());

UPDATE users SET issuer = 'local', subject = NULL, avatar_provider = 'initials';

-- ------------------------------------------------------------
-- Проекты
-- ------------------------------------------------------------
INSERT INTO public.projects
    (id, title, description, identifier, hex_color, owner_id, is_archived, created, updated)
VALUES
    (1, 'Work', 'Рабочие задачи', 'WORK', '1973ff', 1, false, now(), now()),
    (2, 'Personal', 'Личные дела', 'PERS', 'e8b613', 2, false, now(), now()),
    (3, 'Shopping List', 'Список покупок', 'SHOP', '3cb537', 1, false, now(), now());

-- ------------------------------------------------------------
-- Views для каждого проекта: list=0, gantt=1, table=2, kanban=3
-- (default_bucket_id / done_bucket_id проставим позже, после buckets)
-- ------------------------------------------------------------
INSERT INTO public.project_views
    (id, title, project_id, view_kind, bucket_configuration_mode, "position", created, updated)
VALUES
    -- Work (project 1)
    (1, 'List',   1, 0, 0, 1, now(), now()),
    (2, 'Gantt',  1, 1, 0, 2, now(), now()),
    (3, 'Table',  1, 2, 0, 3, now(), now()),
    (4, 'Kanban', 1, 3, 1, 4, now(), now()),
    -- Personal (project 2)
    (5, 'List',   2, 0, 0, 1, now(), now()),
    (6, 'Gantt',  2, 1, 0, 2, now(), now()),
    (7, 'Table',  2, 2, 0, 3, now(), now()),
    (8, 'Kanban', 2, 3, 1, 4, now(), now()),
    -- Shopping List (project 3)
    (9,  'List',   3, 0, 0, 1, now(), now()),
    (10, 'Gantt',  3, 1, 0, 2, now(), now()),
    (11, 'Table',  3, 2, 0, 3, now(), now()),
    (12, 'Kanban', 3, 3, 1, 4, now(), now());

-- ------------------------------------------------------------
-- Buckets (только для kanban-views: 4, 8, 12)
-- ------------------------------------------------------------
INSERT INTO public.buckets
    (id, title, project_view_id, "limit", "position", created, updated, created_by_id)
VALUES
    -- Work / Kanban (view 4)
    (1, 'To Do',       4, 0, 1, now(), now(), 1),
    (2, 'In Progress', 4, 0, 2, now(), now(), 1),
    (3, 'Done',        4, 0, 3, now(), now(), 1),
    -- Personal / Kanban (view 8)
    (4, 'To Do',       8, 0, 1, now(), now(), 2),
    (5, 'In Progress', 8, 0, 2, now(), now(), 2),
    (6, 'Done',        8, 0, 3, now(), now(), 2),
    -- Shopping List / Kanban (view 12)
    (7, 'To Buy',      12, 0, 1, now(), now(), 1),
    (8, 'In Cart',     12, 0, 2, now(), now(), 1),
    (9, 'Bought',      12, 0, 3, now(), now(), 1);

-- Проставляем дефолтную и "done"-корзину на kanban-views
UPDATE public.project_views SET default_bucket_id = 1, done_bucket_id = 3  WHERE id = 4;
UPDATE public.project_views SET default_bucket_id = 4, done_bucket_id = 6  WHERE id = 8;
UPDATE public.project_views SET default_bucket_id = 7, done_bucket_id = 9  WHERE id = 12;

-- ------------------------------------------------------------
-- Метки (labels)
-- ------------------------------------------------------------
INSERT INTO public.labels
    (id, title, description, hex_color, created_by_id, created, updated)
VALUES
    (1, 'Bug',     'Что-то сломано',          'e8433a', 1, now(), now()),
    (2, 'Feature', 'Новая функциональность',  '1973ff', 1, now(), now()),
    (3, 'Urgent',  'Требует внимания срочно', 'ff0000', 1, now(), now());

-- ------------------------------------------------------------
-- Задачи
-- ------------------------------------------------------------
INSERT INTO public.tasks
    (id, title, description, project_id, done, done_at, due_date,
     priority, "index", created_by_id, created, updated)
VALUES
    -- Work
    (1, 'Подготовить отчёт за Q3', 'Собрать цифры по всем командам', 1,
        false, NULL, now() + interval '3 days', 3, 1, 1, now(), now()),
    (2, 'Починить баг с логином', 'Пользователи иногда не могут войти', 1,
        false, NULL, now() + interval '1 day', 4, 2, 1, now(), now()),
    (3, 'Выкатить релиз в продакшн', NULL, 1,
        true, now() - interval '1 day', NULL, 2, 3, 1, now(), now()),
    -- Personal
    (4, 'Купить подарок на день рождения', NULL, 2,
        false, NULL, now() + interval '5 days', 2, 1, 2, now(), now()),
    (5, 'Записаться к стоматологу', NULL, 2,
        false, NULL, NULL, 1, 2, 2, now(), now()),
    -- Shopping List
    (6, 'Молоко',  NULL, 3, false, NULL, NULL, 0, 1, 1, now(), now()),
    (7, 'Хлеб',    NULL, 3, true,  now(), NULL, 0, 2, 1, now(), now()),
    (8, 'Кофе',    NULL, 3, false, NULL, NULL, 0, 3, 1, now(), now());

-- ------------------------------------------------------------
-- Размещение задач по канбан-корзинам
-- ------------------------------------------------------------
INSERT INTO public.task_buckets (bucket_id, task_id, project_view_id) VALUES
    (1, 1, 4),  -- Q3 отчёт        -> To Do
    (2, 2, 4),  -- Баг с логином   -> In Progress
    (3, 3, 4),  -- Релиз           -> Done
    (4, 4, 8),  -- Подарок         -> To Do
    (5, 5, 8),  -- Стоматолог      -> In Progress
    (7, 6, 12), -- Молоко          -> To Buy
    (9, 7, 12), -- Хлеб            -> Bought
    (7, 8, 12); -- Кофе            -> To Buy

-- ------------------------------------------------------------
-- Позиции задач в list-views (для сортировки drag&drop)
-- ------------------------------------------------------------
INSERT INTO public.task_positions (task_id, project_view_id, "position") VALUES
    (1, 1, 1024), (2, 1, 2048), (3, 1, 3072),
    (4, 5, 1024), (5, 5, 2048),
    (6, 9, 1024), (7, 9, 2048), (8, 9, 3072);

-- ------------------------------------------------------------
-- Метки на задачах
-- ------------------------------------------------------------
INSERT INTO public.label_tasks (id, task_id, label_id, created) VALUES
    (1, 1, 2, now()),  -- Q3 отчёт      -> Feature
    (2, 2, 1, now()),  -- Баг с логином -> Bug
    (3, 2, 3, now()),  -- Баг с логином -> Urgent
    (4, 4, 3, now());  -- Подарок       -> Urgent

-- ------------------------------------------------------------
-- Исполнители задач
-- ------------------------------------------------------------
INSERT INTO public.task_assignees (id, task_id, user_id, created) VALUES
    (1, 1, 1, now()),
    (2, 2, 1, now()),
    (3, 4, 2, now()),
    (4, 5, 2, now());

-- ------------------------------------------------------------
-- Комментарий к задаче
-- ------------------------------------------------------------
INSERT INTO public.task_comments (id, "comment", author_id, task_id, created, updated) VALUES
    (1, 'Разбираюсь, похоже проблема в сессиях.', 1, 2, now(), now());

-- ------------------------------------------------------------
-- Команда + шаринг проекта (permission: 0=read, 1=write, 2=admin)
-- ------------------------------------------------------------
INSERT INTO public.teams (id, "name", description, created_by_id, created, updated, is_public) VALUES
    (1, 'Developers', 'Команда разработки', 1, now(), now(), false);

INSERT INTO public.team_members (id, team_id, user_id, "admin", created) VALUES
    (1, 1, 1, true,  now()),
    (2, 1, 3, false, now());

INSERT INTO public.team_projects (id, team_id, project_id, "permission", created, updated) VALUES
    (1, 1, 1, 1, now(), now());  -- Developers имеют write-доступ к Work

-- ------------------------------------------------------------
-- Синхронизация sequence'ов, чтобы новые записи из приложения
-- не конфликтовали с вручную заданными id
-- ------------------------------------------------------------
SELECT setval('public.users_id_seq',          (SELECT max(id) FROM public.users));
SELECT setval('public.projects_id_seq',       (SELECT max(id) FROM public.projects));
SELECT setval('public.project_views_id_seq',  (SELECT max(id) FROM public.project_views));
SELECT setval('public.buckets_id_seq',        (SELECT max(id) FROM public.buckets));
SELECT setval('public.labels_id_seq',         (SELECT max(id) FROM public.labels));
SELECT setval('public.tasks_id_seq',          (SELECT max(id) FROM public.tasks));
SELECT setval('public.label_tasks_id_seq',    (SELECT max(id) FROM public.label_tasks));
SELECT setval('public.task_assignees_id_seq', (SELECT max(id) FROM public.task_assignees));
SELECT setval('public.task_comments_id_seq',  (SELECT max(id) FROM public.task_comments));
SELECT setval('public.teams_id_seq',          (SELECT max(id) FROM public.teams));
SELECT setval('public.team_members_id_seq',   (SELECT max(id) FROM public.team_members));
SELECT setval('public.team_projects_id_seq',  (SELECT max(id) FROM public.team_projects));

COMMIT;
SEED_EOF

# ---------------------------------------------------------------------------
# 4. Генерация .env (только если ещё не существует — для идемпотентности)
# ---------------------------------------------------------------------------

if [ -f "$ENV_FILE" ]; then
    log "$ENV_FILE уже существует — использую ранее сгенерированные секреты."
else
    log "Генерирую $ENV_FILE со случайными паролями..."

    gen_db_password=$(openssl rand -hex 16)
    gen_redis_password=$(openssl rand -hex 16)
    gen_jwt_secret=$(openssl rand -hex 32)

    cat > "$ENV_FILE" <<EOF
# Сгенерировано автоматически setup.sh. Не коммитить в репозиторий!
RELEASE_VERSION=dev
APP_PORT=3456
APP_PUBLIC_URL=http://localhost:3456
APP_MEM_LIMIT=512m
APP_CPUS=1.0

JWT_SECRET=${gen_jwt_secret}

DB_HOST=db
DB_PORT=5432
DB_USER=vikunja
DB_PASSWORD=${gen_db_password}
DB_NAME=vikunja
DB_MEM_LIMIT=512m
DB_CPUS=0.5

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${gen_redis_password}
REDIS_MEM_LIMIT=256m
REDIS_CPUS=0.25
EOF

    chmod 600 "$ENV_FILE"
    log "Секреты сгенерированы и сохранены в $ENV_FILE (права доступа 600)."
fi

# Подхватываем переменные из .env в текущий процесс (для curl-проверок ниже).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# ---------------------------------------------------------------------------
# 5. Сборка и запуск контейнеров
# ---------------------------------------------------------------------------

log "Собираю образы (docker compose build)..."
compose build

log "Запускаю контейнеры (docker compose up -d)..."
compose up -d

log "Жду готовности СУБД и кэша..."
wait_healthy vikunja-db 90
wait_healthy vikunja-redis 60

log "Жду готовности приложения..."
wait_healthy vikunja-app 120

# ---------------------------------------------------------------------------
# 6. Миграции БД и тестовые данные
# ---------------------------------------------------------------------------

log "Выполняю миграции базы данных..."
compose exec -T app /app/vikunja/vikunja migrate

log "Проверяю, загружены ли уже тестовые данные..."
seed_marker=$(compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT 1 FROM users WHERE username='${SEED_TEST_USER}' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

if [ "$seed_marker" = "1" ]; then
    log "Тестовые данные уже загружены (пользователь '${SEED_TEST_USER}' существует) — пропускаю (идемпотентность)."
else
    log "Загружаю полный набор тестовых данных из seed_data.sql (пользователи, проекты, все 4 view, buckets, задачи, метки, команда)..."
    if ! compose exec -T db psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$SEED_FILE"; then
        err "Загрузка тестовых данных завершилась ошибкой — см. вывод psql выше."
        exit 1
    fi
    log "Тестовые данные загружены."
fi

# ---------------------------------------------------------------------------
# 7. Итоговый статус
# ---------------------------------------------------------------------------

http_code=$(curl -s -o /dev/null -w '%{http_code}' "$APP_PUBLIC_URL/api/v1/info" 2>/dev/null)
[ -n "$http_code" ] || http_code="000"

printf '\n'
printf '=================================================================\n'
printf ' Vikunja развёрнута и доступна по адресу: %s\n' "$APP_PUBLIC_URL"
printf ' Проверка API (%s/api/v1/info): HTTP %s\n' "$APP_PUBLIC_URL" "$http_code"
printf ' Тестовые пользователи (пароль у всех: %s):\n' "$SEED_TEST_PASSWORD"
printf '   admin / alice / bob\n'
printf ' Загружено: 3 проекта, все 4 view на каждый, kanban-buckets, 8 задач,\n'
printf ' метки, назначения, комментарий, команда "Developers" с доступом к Work.\n'
printf ' Секреты БД/Redis/JWT сохранены в: %s\n' "$ENV_FILE"
printf '=================================================================\n'

if [ "$http_code" != "200" ]; then
    err "Приложение отвечает кодом $http_code вместо 200 — проверьте 'docker compose logs app'."
    exit 1
fi

exit 0
