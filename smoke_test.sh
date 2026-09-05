#!/bin/sh
# smoke_test.sh – проверяет работу развёрнутого приложения

set -e

BASE_URL="http://localhost:3456"

test_endpoint() {
    endpoint="$1"
    expected="$2"
    response=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$endpoint")
    if [ "$response" -eq "$expected" ]; then
        echo "[OK] GET $endpoint (got $response)"
        return 0
    else
        echo "[FAIL] GET $endpoint (got $response, expected $expected)"
        return 1
    fi
}

# 1. Проверка API информации
test_endpoint "/api/v1/info" 200

# 2. Проверка корневого пути (страница логина)
test_endpoint "/" 200

# 3. Проверка версии (если есть) или другой публичный эндпоинт
# /api/v1/version – может отсутствовать, поэтому проверяем другой:
# например, /api/v1/openapi.json (если присутствует)
# Если нет, можно повторить проверку /api/v1/info с другим методом (например, HEAD)
# Используем третий эндпоинт – /api/v1/health (если есть) или просто ещё один раз /api/v1/info
# Для уверенности добавим проверку /api/v1/version, если упадёт – не критично, но сделаем
# Вместо этого сделаем проверку /api/v1/register (POST) с пустым телом, ожидаем 400 (неправильный запрос)
# Это тоже публичный эндпоинт.
response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/register" -H "Content-Type: application/json" -d '{}')
if [ "$response" -eq 400 ]; then
    echo "[OK] POST /api/v1/register (got 400, expected 400)"
else
    echo "[FAIL] POST /api/v1/register (got $response, expected 400)"
    exit 1
fi

echo "All smoke tests passed."
exit 0
