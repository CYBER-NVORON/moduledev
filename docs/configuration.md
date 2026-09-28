# Конфигурация и запуск

[Документация](README.md) · [Первый запуск](../README.md#запуск) · [Проверки](testing.md)

## Сервисы и сети

Имена сервисов в `compose.yaml`:

```text
gateway api cli postgres worker-a worker-b
outbox-dispatcher outbox-dispatcher-b receipt-adapter
inbox-reconciler inbox-reconciler-b provider-simulator
```

`cli` — одноразовый сервис миграций; успешное завершение с exit code 0 штатно. Остальные сервисы работают после `docker compose up -d --build`. Пять Python-процессов используют один локально собранный image с Python 3.12+ и разными entrypoints; две реплики worker используют один C# image.

Только `gateway` публикует host port. Публикация порта в Compose:

```yaml
services:
  gateway:
    ports:
      - "127.0.0.1:${COURSE_GATEWAY_PORT:-8080}:8080"
```

Checker сначала валидирует этот contract с `COURSE_GATEWAY_PORT=8080`, затем создаёт isolated override со случайным loopback host port и container target `8080`. Только на время проверки override также публикует случайные loopback-порты PostgreSQL, provider и служебных endpoints; исходный Compose по-прежнему не публикует их.

Python services и provider не публикуют host ports. Adapter не получает PostgreSQL settings. API подключается как `course_runtime`, workers — как `workflow_worker`, оба dispatcher — как `outbox_dispatcher`, оба reconciler — как `inbox_reconciler`. Dispatcher используют разные `OUTBOX_OWNER`.

`postgres` монтирует каталог данных в объявленный top-level named volume. Checker выполняет `docker compose down`/`up` без удаления volume и проверяет сохранность состояния; anonymous volume или writable container layer не удовлетворяют контракту.

## Переменные окружения

Compose получает настройки через окружение или локальный `.env`; пример — [`.env.example`](../.env.example). Проверки передают синтетические значения в отдельное окружение. Значения паролей по умолчанию предназначены только для локальной разработки. JWT, HMAC и callback capability задаются явно по [инструкции запуска](../README.md#запуск).

| Переменная | Получатель | Значение по умолчанию в Compose |
|---|---|---|
| `COURSE_GATEWAY_PORT` | `gateway` | `8080` |
| `COURSE_TEST_PROFILE` | Все проверяемые процессы | `0`; для аварийных тестов — `1` |
| `COURSE_JWT_ISSUER` | C# application services | Пустое значение |
| `COURSE_JWT_AUDIENCE` | C# application services | Пустое значение |
| `COURSE_JWT_SIGNING_KEY` | C# application services | Пустое значение |
| `COURSE_POSTGRES_PASSWORD` | `postgres` | Локальное значение для разработки |
| `COURSE_MIGRATOR_PASSWORD` | `postgres`, `cli` | Локальное значение для разработки |
| `COURSE_PUBLISHER_PASSWORD` | `postgres`, `cli` | Локальное значение для разработки |
| `COURSE_RUNTIME_PASSWORD` | `postgres`, `api` | Локальное значение для разработки |
| `COURSE_WORKER_PASSWORD` | `postgres`, workers | Локальное значение для разработки |
| `COURSE_OUTBOX_PASSWORD` | `postgres`, dispatcher | Локальное значение для разработки |
| `COURSE_INBOX_PASSWORD` | `postgres`, reconciler | Локальное значение для разработки |
| `COURSE_AUTOCHECK_PASSWORD` | `postgres`; checker использует снаружи Compose | Пустое значение |
| `PROVIDER_URL` | Dispatcher | `http://provider-simulator:8081` |
| `OUTBOX_OWNER` | Dispatcher | `outbox-dispatcher` |
| `OUTBOX_OWNER_B` | Второй dispatcher | `outbox-dispatcher-b` |
| `COURSE_FAILPOINT` | Проверяемый process | Пустое значение |
| `COURSE_PROVIDER_TIMEOUT_MS` | Dispatcher | `500` |
| `COURSE_OUTBOX_MAX_ATTEMPTS` | PostgreSQL/dispatcher | `4` |
| `COURSE_OUTBOX_BACKOFF_BASE_MS` | PostgreSQL | `200` |
| `COURSE_OUTBOX_BACKOFF_MAX_MS` | PostgreSQL | `800` |
| `COURSE_OUTBOX_JITTER_MAX_MS` | PostgreSQL | `100` |
| `COURSE_OUTBOX_LEASE_MS` | PostgreSQL/dispatcher | `2000` |
| `COURSE_OUTBOX_POLL_MS` | Dispatcher | `100` |
| `COURSE_INBOX_POLL_MS` | Reconciler | `500` |
| `COURSE_JOB_LEASE_MS` | PostgreSQL, workers | `2000` |
| `COURSE_WORKER_POLL_MS` | Workers | `100` |
| `PROVIDER_CALLBACK_CAPABILITY` | Adapter, provider callback URL | Пустое значение |
| `PROVIDER_CALLBACK_TOKEN` | Adapter | Пустое значение |
| `PROVIDER_HMAC_SECRET` | Adapter, API | Пустое значение |
| `RECEIPT_API_URL` | Adapter | `http://gateway:8080/api/receipt/accept` |
| `PROVIDER_AUDIT_TOKEN` | Provider | Пустое значение |

Строки `COURSE_DB_CONNECTION`, `COURSE_MIGRATION_DB_CONNECTION` и `DATABASE_URL` формируются внутри Compose из `COURSE_*_PASSWORD`; `API_BACKEND_URL` также задан в Compose. Для их замены нужен Compose override. Изменение пароля в `.env` не меняет роль в уже созданной БД.

`OUTBOX_OWNER_B` подставляется во внутреннюю переменную `OUTBOX_OWNER` второй реплики. Политика повторов передаётся PostgreSQL через настройки `course.outbox_*`; lease jobs — через `course.job_lease_ms`. `COURSE_TEST_PROFILE` разрешает тестовые команды и failpoints, но сам по себе не переключает интервалы: они задаются перечисленными переменными. Если `COURSE_AUTOCHECK_PASSWORD` пуст, парольный вход роли наблюдателя отключён; checker задаёт отдельный пароль.

`COURSE_PROVIDER_TIMEOUT_MS` ограничивает вызов provider из dispatcher. Для HTTP-клиента adapter, вызывающего `receipt.accept` через gateway, установлен отдельный таймаут 5 секунд, чтобы холодный старт API не обрывался по короткому бюджету внешней доставки.

## Начальная настройка

После чистого `docker compose up -d --build` без ручных host-команд должны быть готовы:

- база `course`, roles и grants;
- миграции `001..015`;
- зарегистрированные actions и ровно одна default version каждого действия;
- опубликованные и активированные flow maps;
- read-only schema `autocheck` и login role `autocheck_reader`, которая имеет только `CONNECT`, `USAGE` schema и `SELECT` views; у неё нет memberships, application function/sequence privileges, доступа к physical relations, `CREATE` или `TEMP`;
- health/readiness/metrics API, workers и Python integration processes.

При пустом volume роли и схема создаются PostgreSQL init scripts. При последующих запусках `cli` проверяет checksums и применяет новые миграции. Проверочный контур использует entrypoint `cli`, а не выполняет host scripts проекта.

## Обновление БД

Миграции идентифицируются по имени и SHA-256. CLI применяет каждый новый файл отдельной транзакцией; изменение уже применённого файла останавливает обновление. Сначала сделайте резервную копию существующей БД и убедитесь, что её история миграций совпадает с файлами проекта.

Для перехода к схеме `014..015` остановите обработчики, подготовьте роль наблюдателя и примените новые миграции:

```text
docker compose build postgres cli
docker compose stop api worker-a worker-b outbox-dispatcher outbox-dispatcher-b receipt-adapter inbox-reconciler inbox-reconciler-b
docker compose up -d postgres
docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U postgres -d course -v check_pass="$COURSE_AUTOCHECK_PASSWORD" -f /opt/prepare_database.sql'
docker compose run --rm cli migration apply /migrations
docker compose up -d --build
```

Перед административной командой дождитесь состояния `healthy` у PostgreSQL. Продолжайте только после успешного завершения каждой команды. `prepare_database.sql` создаёт `autocheck_reader` и закрывает унаследованные PUBLIC-привилегии; для существующего volume это выполняется отдельно, поскольку initdb повторно не запускается. Мигратор не получает дополнительных прав администратора.

Compose не ждёт завершения CLI перед запуском API/workers. Readiness API и workers проверяет соединение с БД и наличие `autocheck.metrics` из миграции `015`.

Базы с прежним локальным именем `008_week3_delivery.sql` или промежуточной редакцией `015` имеют другую историю/checksum. Такие тестовые БД следует пересоздать; БД с нужными данными требует отдельного плана переноса. Записи журнала и checksums вручную не подменяются.

Миграция `012` сохраняет старую append-only историю и проверяет канонические имена новых operation events. Публичные чтения переводят исторические `OperationSubmitted`, `OperationCompleted`, `OperationRejected` в uppercase, сохраняя IDs, хеши и время. Имена `workflow.events` остаются в PascalCase.

## SQL-интерфейс Python

Имена, типы аргументов и tabular result `delivery.claim_outbox` описаны в [SQL-интерфейсе Python](external-contracts.md#sql-интерфейс-python). `delivery.succeed_outbox` и `delivery.fail_outbox` возвращают JSON object; его внутренняя форма не стандартизована и не читается checker. Обязательны conditional owner/lease update и отсутствие regression из `CONFIRMED`.

`delivery.reconcile_inbox(p_limit integer)` возвращает число сообщений, применённых текущим вызовом. HTTP выполняется вне транзакции claim; предметные изменения остаются внутри PostgreSQL.

## Служебные порты

| Service | Internal port |
|---|---:|
| `api` | 8080 |
| `worker-a`, `worker-b` | 8080 |
| `outbox-dispatcher`, `outbox-dispatcher-b` | 8080 |
| `receipt-adapter` | 8082 |
| `inbox-reconciler`, `inbox-reconciler-b` | 8080 |

Порты не публикуются на host. На каждом доступны `/health/live`, `/health/ready`, `/metrics`.
