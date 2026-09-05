# Practica — Автоматическое развертывание Vikunja

Данный проект представляет собой полностью автоматизированное развертывание Vikunja — open-source приложения для управления задачами и проектами.

Развертывание выполняется в изолированных Docker-контейнерах с использованием PostgreSQL в качестве базы данных и Redis для кэширования.


Состав проекта

- Dockerfile : многостадийная сборка образа Vikunja: сначала собирается фронтенд (Node.js), затем бэкенд (Go). В финальный образ Alpine копируется готовый бинарник.
- docker-compose.yml : оркестрация трёх сервисов: app (Vikunja), db (PostgreSQL 16), redis (Redis 7). Настроены healthcheck, проброс портов и постоянные тома для данных.
- setup.sh : главный скрипт автоматического развертывания "с нуля". Выполняет проверку зависимостей, клонирует upstream-репозиторий Vikunja на фиксированный коммит, генерирует .env со случайными паролями, собирает и запускает контейнеры, выполняет миграции БД и загружает тестовые данные.
- smoke_test.sh : скрипт для smoke-тестирования. Выполняет 3 проверки публичных эндпоинтов (/api/v1/info, /, /api/v1/register) и завершается с ошибкой при любом сбое.
- .github/workflows/ci.yml : конвейер GitHub Actions: при каждом push в ветку main автоматически запускается setup.sh, а затем smoke_test.sh.
- seed_data.sql : SQL-скрипт с тестовыми данными: 3 пользователя (admin, alice, bob с паролем password123), 3 проекта, 4 вида отображения на каждый проект, канбан-доски, 8 задач, метки, назначения, комментарии и команда "Developers".


Быстрый старт

Требования:
- Docker (с поддержкой Compose v2)
- Git
- OpenSSL
- curl

Запуск:

1. Клонируйте репозиторий:
   git clone https://github.com/vikotihina/Practica.git
   cd Practica

2. Запустите скрипт развертывания:
   sh setup.sh

   Скрипт выполнит все шаги автоматически:
   - проверит наличие необходимых утилит;
   - клонирует upstream-репозиторий Vikunja;
   - сгенерирует .env со случайными секретами;
   - соберёт и запустит контейнеры;
   - выполнит миграции БД;
   - загрузит тестовые данные.

3. Откройте приложение в браузере:
   http://localhost:3456

Тестовые учётные записи:
- admin@example.com / password123 (администратор)
- alice@example.com / password123 (пользователь)
- bob@example.com / password123 (пользователь)


Smoke-тестирование

Для проверки работоспособности приложения выполните:
sh smoke_test.sh

Скрипт последовательно проверит:
- GET /api/v1/info — ожидает 200 OK;
- GET / — ожидает 200 OK;
- POST /api/v1/register с пустым JSON — ожидает 400 Bad Request.

Все проверки должны завершиться с сообщением [OK]. При любой ошибке скрипт завершится с кодом 1.


CI/CD (GitHub Actions)

При каждом push в ветку main автоматически запускается пайплайн:
1. Установка зависимостей (Docker, Git, OpenSSL, curl).
2. Запуск setup.sh — полное развертывание приложения.
3. Запуск smoke_test.sh — проверка работоспособности.

Если хотя бы один этап завершится с ошибкой, пайплайн получит красный статус.


Управление контейнерами

- docker compose up -d : запустить все сервисы в фоне
- docker compose down : остановить все сервисы
- docker compose down -v : остановить и удалить тома с данными
- docker compose logs app : просмотреть логи приложения
- docker compose logs db : просмотреть логи базы данных
- docker compose restart app : перезапустить только приложение


Устранение неполадок

Ошибка "Account is not local" при входе:
Убедитесь, что в таблице users для учётной записи задан auth_provider = 'local', а поля issuer, subject, avatar_provider и auth_provider_id установлены в NULL:

docker exec -it vikunja-db psql -U vikunja -d vikunja -c "UPDATE users SET auth_provider = 'local', issuer = NULL, subject = NULL, avatar_provider = NULL, auth_provider_id = NULL WHERE username = 'admin';"
docker compose restart app

Порт 5432 уже занят:
Если на хосте запущен локальный PostgreSQL, измените внешний порт в docker-compose.yml:
ports:
  - "5433:5432"
И в DBeaver/psql подключайтесь к порту 5433.

Контейнер не становится healthy:
Проверьте логи:
docker compose logs app
docker compose logs db
docker compose logs redis
