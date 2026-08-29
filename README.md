# Database-First Action Runtime (ModuleDev Week 1)

## Решение

### Архитектура

Система состоит из 5 контейнеров, описанных в `compose.yaml`:

| Сервис     | Роль                                                                                      |
|------------|-------------------------------------------------------------------------------------------|
| `gateway`  | C# ASP.NET Core reverse proxy на порту `8080`. Проксирует `/api/`, `/openapi/`, health.   |
| `api`      | Внутренний action runtime. Generic route `POST /api/{module}/{action}`, JWT, транзакции.   |
| `cli`      | Course CLI — публикация манифестов, управление версиями actions.                 |
| `migrator` | Выполняет автоматическое применение SQL-миграций структуры схемы (admin).                |
| `postgres` | PostgreSQL 16. Авторитетное хранилище: catalog, idempotency, payment, autocheck.          |

Потоки данных: `Client → gateway → api → postgres`. Gateway не имеет доступа к БД.

C4-диаграмма: [docs/c4-containers.md](docs/c4-containers.md)  
ADR о границах доверия: [docs/adr-trust-boundary.md](docs/adr-trust-boundary.md)  
ADR о результатах: [docs/adr-results.md](docs/adr-results.md)

### Запуск

Требования: Docker и Docker Compose.

1. Скопируйте шаблон переменных окружения в `.env`:
   - Linux/macOS: `cp .env.example .env`
   - Windows (PowerShell / cmd): `copy .env.example .env`
2. Запустите стек сервисов:
   ```bash
   docker compose up -d --build
   ```

Сервис доступен по адресу `http://localhost:8080`. После запуска `postgres` проходит healthcheck, сервис `migrator` автоматически накатывает SQL-миграции, `api` подключается к БД и регистрирует маршруты, а `gateway` начинает проксирование запросов. Проверить готовность можно запросом к `/health/ready`.

### Конфигурация

Все настраиваемые параметры и пароли вынесены в файл `.env` (шаблон доступен в `.env.example`).

| Переменная               | Сервис   | Описание                              |
|--------------------------|----------|---------------------------------------|
| `COURSE_JWT_ISSUER`      | `api`    | Issuer JWT-токенов                    |
| `COURSE_JWT_AUDIENCE`    | `api`    | Audience JWT-токенов                  |
| `COURSE_JWT_SIGNING_KEY` | `api`    | HS256 ключ подписи (≥32 байт)         |
| `COURSE_DB_CONNECTION`   | `api`    | Строка подключения к PostgreSQL       |
| `API_BACKEND_URL`        | `gateway`| URL внутреннего API (Compose DNS)     |
| `COURSE_DB_CONNECTION`   | `cli`    | Строка подключения (role: publication)|
| `COURSE_MIGRATION_DB_CONNECTION` | `cli`, `migrator` | Строка подключения для миграций (role: migration) |

Реальные секреты в репозитории не хранятся. Проверка подменяет signing key через Compose override.

### Миграции

SQL-миграции находятся в `migrations/`. Они применяются автоматически отдельным сервисом `migrator` при запуске `docker compose up -d --build` (а также поддерживаются через `/docker-entrypoint-initdb.d` PostgreSQL).

Публикация action manifests выполняется через `cli`:

```bash
docker compose run --rm cli action publish <manifest.json>
```

CLI проверяет SHA256 checksum миграций и регистрирует actions в `catalog.actions`.

### Проверка

Для Linux/macOS (через Bash):
```bash
./check.sh
```

Для Windows (через Python 3.10+, без дополнительных зависимостей `pip`):
```powershell
python autocheck/public_check.py --repo . --fixtures autocheck/fixtures --output week-1-public-report.json
```

Проверка покрывает: Compose interface, publication, security (JWT, policy), contracts (schemas, outcomes, envelopes), PostgreSQL (idempotency, concurrency, roles), recovery и OpenAPI documentation.

Health endpoints:
- `GET /health/live` — liveness (процесс gateway)
- `GET /health/ready` — readiness (gateway → api → PostgreSQL)

OpenAPI:
- `GET /openapi/default.json` — все включённые default routes

### Диагностика

| Что проверить         | Как                                                          |
|-----------------------|--------------------------------------------------------------|
| Liveness gateway      | `curl http://localhost:8080/health/live`                      |
| Readiness (сквозная)  | `curl http://localhost:8080/health/ready`                     |
| OpenAPI spec          | `curl http://localhost:8080/openapi/default.json`             |
| Логи gateway          | `docker compose logs gateway`                                |
| Логи api              | `docker compose logs api`                                    |
| Логи PostgreSQL       | `docker compose logs postgres`                               |
| Подключение к БД      | `docker compose exec postgres psql -U postgres -d course`    |

Логи выводятся встроенным ASP.NET Core JSON-логгером в stdout. JWT, credentials и payload в логи не попадают.

### Ограничения

- **Нагрузка на соединения PostgreSQL** — каждый HTTP-запрос удерживает физическое транзакционное соединение на протяжении валидации схемы, вызова `api.invoke` и проверки ответа. В production требуется вынос внешнего пулера (PgBouncer/Odyssey) и read-репликация для немодифицирующих запросов и OpenAPI.
- **Рост таблиц аудита и идемпотентности** — таблицы `catalog.action_dispatches` и `idempotency.records` являются append-only и накапливают данные без встроенной очистки. Для production-эксплуатации необходимо секционирование (partitioning by range/time) и регламентная архивация/TTL-очистка устаревших записей.
- **Симметричный ключ JWT (HS256)** — сервис валидирует токены по общему секрету (`COURSE_JWT_SIGNING_KEY`). В production-среде предпочтительна асимметричная криптография (RS256/ES256) с динамической загрузкой публичных ключей по JWKS от доверенного IdP (Keycloak/OIDC).
- **Отсутствие Rate Limiting и Circuit Breaker на Gateway** — Gateway реализует минималистичный reverse proxy без ограничения частоты запросов (rate limiting per IP/client), защитных очередей и прерывания каскадных сбоев (circuit breaker) при деградации `api` или базы данных.
- **Лимит размера полезной нагрузки** — размер тела запроса ограничен 1 МБ (`MaxRequestBodySize`), а парсинг выполняется в память через `JsonNode`. Архитектура не предназначена для передачи больших бинарных файлов (требуется интеграция с S3-совместимым объектным хранилищем и pre-signed URLs).
- **Сложность мониторинга и профилирования бизнес-логики** — реализация предметных функций на PL/pgSQL усложняет сквозную распределенную трассировку (OpenTelemetry spans внутри SQL) и APM-мониторинг по сравнению с кодом на прикладном уровне.