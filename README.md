# ModuleDev: Database-First Action Runtime & Workflow Engine

Данный репозиторий содержит реализацию платформы для выполнения действий (Week 1) и оркестрации распределенных процессов (Week 2). 

Проект спроектирован по парадигме **Database-First**, где основным вычислительным ядром и источником истины (Source of Truth) выступает PostgreSQL, а C#-сервисы являются stateless-прослойками (API, Worker, Gateway).

## Решение

### Архитектура

Система состоит из 7 изолированных контейнеров, разделенных на две виртуальные сети (`gateway-net` и `course-net`):

| Сервис       | Технологии / Роль | Детали реализации |
|--------------|-------------------|-------------------|
| `gateway`    | YARP / ASP.NET 8  | Reverse proxy (порт 8080). Единственный сервис, смотрящий наружу. Проксирует `/api/` и `/openapi/`, не имеет доступа к БД. |
| `api`        | ASP.NET 8         | Generic HTTP-to-SQL транслятор. Выполняет JWT-аутентификацию, проверяет JSON Schema и вызывает PL/pgSQL функцию `api.invoke`. |
| `worker-a/b` | C# Background     | Два экземпляра stateless-воркера для консистентного выполнения фоновых задач. Используют паттерн Transactional Outbox/Polling. |
| `cli`        | .NET Console App  | Инструмент управления (публикация actions, валидация workflow-карт, управление версиями). |
| `migrator`   | C# Console App    | Применяет миграции при старте (если они не были применены через entrypoint), сверяет SHA256 checksums. |
| `postgres`   | PostgreSQL 16     | Ядро системы. Хранит схемы `catalog`, `idempotency`, `workflow`. Содержит бизнес-логику в виде `SECURITY DEFINER` функций. |

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

**Как работает инициализация базы (Database-First Init):**
Вместо хардкода паролей в SQL, был собран кастомный образ БД (`src/Postgres/Dockerfile`). 
При самом первом запуске встроенный механизм Postgres исполняет скрипт `000_set_passwords.sh`, который безопасно подтягивает пароли из `.env` и создает роли. Следом накатываются SQL-миграции `001..007`, создавая таблицы, привязывая их к ролям, и устанавливая строгие Append-Only триггеры на таблицы аудита.

### Конфигурация

Все настраиваемые параметры и пароли вынесены в файл `.env` (шаблон доступен в `.env.example`).

| Переменная               | Сервис   | Описание                              |
|--------------------------|----------|---------------------------------------|
| `COURSE_JWT_ISSUER`      | `api`    | Issuer JWT-токенов                    |
| `COURSE_JWT_AUDIENCE`    | `api`    | Audience JWT-токенов                  |
| `COURSE_JWT_SIGNING_KEY` | `api`, `cli` | HS256 ключ подписи (≥32 байт)         |
| `COURSE_DB_CONNECTION`   | `api`, `worker-*` | Строка подключения к PostgreSQL       |
| `API_BACKEND_URL`        | `gateway`| URL внутреннего API (Compose DNS)     |
| `COURSE_DB_CONNECTION`   | `cli`    | Строка подключения (role: publication)|
| `COURSE_MIGRATION_DB_CONNECTION` | `cli`, `migrator` | Строка подключения для миграций (role: migration) |

Также добавлены Fail-fast переменные для паролей ролей БД: `RUNTIME_PASSWORD`, `PUBLICATION_PASSWORD`, `MIGRATION_PASSWORD`, `WORKER_PASSWORD`. Реальные секреты в репозитории не хранятся. Проверка подменяет signing key и пароли через Compose override.

### Миграции

SQL-миграции находятся в `migrations/`. Они применяются автоматически отдельным сервисом `migrator` при запуске `docker compose up -d --build`. 
При этом инициализация ролей БД и безопасное проставление паролей происходит ДО миграций через скрипт `000_set_passwords.sh` в `/docker-entrypoint-initdb.d` PostgreSQL.

Публикация action manifests выполняется через `cli`:

```bash
docker compose run --rm cli action publish <manifest.json>
```

CLI проверяет SHA256 checksum миграций и регистрирует actions в `catalog.actions`.

### Workflow-карты

Модель процесса задается в виде направленного графа шагов (Directed Graph) в JSON-формате и хранится в `workflow.flow_versions`.

**Механизм валидации (CLI):**
Перед публикацией карты команда `flow validate` проверяет граф в памяти:
1. **Связность графа (BFS - Поиск в ширину):** Начиная со `start_step`, алгоритм проверяет, что до каждого объявленного узла можно добраться. Недостижимые узлы (orphan nodes) вызывают ошибку.
2. **Отсутствие циклов (DFS - Поиск в глубину):** Используется раскраска графа (белый/серый/черный). Если при обходе мы натыкаемся на "серый" узел (находящийся в текущем стеке вызовов) — обнаружен цикл, валидация отклоняется.
3. Валидация JSON Pointers для маппинга переменных (RFC 6901).

Шаги делятся на `execute` (вызов синхронного action) и `suspend` (заморозка процесса до получения внешнего сигнала).

### Worker

Воркеры `worker-a` и `worker-b` обеспечивают фоновое исполнение графа процессов с гарантиями Exactly-Once / At-Least-Once.

**Технические особенности реализации:**
1. **Concurrent Polling (SKIP LOCKED):** 
   Воркеры конкурентно опрашивают таблицу `workflow.jobs` через хранимую процедуру `workflow.claim_jobs`. В SQL используется `SELECT ... FOR UPDATE SKIP LOCKED LIMIT X`, что позволяет забирать пачки задач без взаимных блокировок и race conditions между инстансами.
2. **Lease и Fencing Token (Optimistic Concurrency):**
   Каждая полученная задача получает уникальную подпись `lease_version` (монотонно возрастающий счетчик) и срок действия `lease_until`. При попытке зафиксировать результат (функции `finish_job`, `fail_job`) воркер обязан передать этот token. Если lease истек и другая нода перехватила задачу (токен изменился) — фиксация отклоняется, защищая систему от Split-Brain.
3. **Smart Retries:**
   Если `execute`-шаг завершается ошибкой, воркер считывает массив `delays_ms` из задачи. Экспоненциальный бэкофф делегируется базе данных: SQL-функция переводит задачу в `RETRY_WAIT` и устанавливает `next_attempt_at`. До наступления этого времени задача скрыта от `SKIP LOCKED`.


### Проверка

Запуск основной проверки (для Linux, macOS, а Windows через Git Bash / WSL):
```bash
./check.sh
```

Для запуска в Windows (требуется Python 3.10+):

Для проверки Недели 1:
```powershell
python autocheck/week1/public_check_win.py --repo . --fixtures autocheck/week1/fixtures --output week-1-public-report.json
```

Для проверки Недели 2:
```powershell
python autocheck/public_check_win.py --repo . --fixtures autocheck/fixtures --output week-2-public-report.json
```

### Диагностика

Диагностика строится на стандартных HealthChecks и логах ASP.NET Core:

- **Liveness Gateway:** `curl http://localhost:8080/health/live` (проверка, что процесс не завис).
- **Readiness API:** `curl http://localhost:8080/health/ready` (глубокая проверка, gateway пингует api, api пингует postgres `SELECT 1`).
- **Динамический OpenAPI:** `curl http://localhost:8080/openapi/default.json` (API на лету генерирует swagger.json на основе манифестов из `catalog.actions`).
- **Structured JSON Logging:** Приложения пишут логи в stdout в формате JSON без чувствительных данных.
  ```bash
  docker compose logs -f api
  docker compose logs -f worker-a
  ```

### Ограничения

- **Нагрузка на соединения PostgreSQL** — каждый HTTP-запрос (через Generic Route) удерживает физическое соединение для выполнения `api.invoke`. В HighLoad потребуется пулер соединений (PgBouncer) в Transaction Mode.
- **Рост Append-Only таблиц** — `catalog.action_dispatches`, `idempotency.records`, и `workflow.events` только растут. Защита от мутаций сделана через Event-триггеры, но нет механизма TTL (регламентной архивации). Необходим Partitioning.
- **SchemaCache Stampede** — динамические JSON-схемы кэшируются в памяти API (`ConcurrentDictionary`). Для предотвращения лавинообразных пересозданий кэш обходит вставку новых элементов при достижении лимита (1000 элементов).
- **Симметричный ключ JWT (HS256)** — сервис валидирует токены по общему секрету (`COURSE_JWT_SIGNING_KEY`). В production-среде предпочтительна асимметричная криптография (RS256/ES256) с динамической загрузкой публичных ключей по JWKS от доверенного IdP (Keycloak/OIDC).
- **Отсутствие Rate Limiting и Circuit Breaker на Gateway** — Gateway реализует минималистичный reverse proxy без ограничения частоты запросов (rate limiting per IP/client), защитных очередей и прерывания каскадных сбоев (circuit breaker) при деградации `api` или базы данных.
- **Лимит размера полезной нагрузки** — размер тела запроса ограничен 1 МБ (`MaxRequestBodySize`), а парсинг выполняется в память через `JsonNode`. Архитектура не предназначена для передачи больших бинарных файлов (требуется интеграция с S3-совместимым объектным хранилищем и pre-signed URLs).
- **Сложность мониторинга и профилирования бизнес-логики** — реализация предметных функций на PL/pgSQL усложняет сквозную распределенную трассировку (OpenTelemetry spans внутри SQL) и APM-мониторинг по сравнению с кодом на прикладном уровне.