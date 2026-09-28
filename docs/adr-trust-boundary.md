# ADR: границы доверия и изоляция Gateway от БД

[Документация](README.md) · [Архитектура контейнеров](c4-containers.md)

## Статус

Принято.

## Контекст

Система обрабатывает финансовые операции (payment.request, operation.get) и требует строгого разделения зон доверия. Необходимо определить, какие компоненты имеют доступ к PostgreSQL и JWT-секретам.

## Решение

### Граница 1: Gateway изолирован от БД

Gateway выполняет только проксирование HTTP-запросов к внутреннему Api по Compose DNS. Gateway:

- **не имеет** строки подключения к PostgreSQL;
- не использует JWT signing key: переменная передаётся всем C# services по конфигурационному контракту недели 4, а JWT проверяет API;
- **не выполняет** аутентификацию, авторизацию или бизнес-логику;
- **не модифицирует** payload — только проксирует тело и контрактные заголовки (`Authorization`, `Idempotency-Key`, `X-Action-Version`, `X-Provider-Signature`).

Gateway не получает прямого SQL-доступа или credentials БД. При этом он видит проходящий HTTP-трафик: сетевая изоляция не делает компрометацию gateway безвредной для запросов клиентов.

### Граница 2: Api изолирован внутри Docker network

Api не публикует host-порты; публичный клиент обращается через Gateway. Контейнеры общей сети технически могут обращаться к API напрямую, поэтому JWT и policy проверяет сам API. С БД Api общается внутри `course-net`. Api:

- проверяет JWT (issuer, audience, signature, expiry, claims);
- формирует server-side context (`principal`, `consumer`, `scopes`, `correlationId`, `deadline`);
- проверяет policy на двух границах: в C# до вызова и в `api.invoke` на уровне PostgreSQL;
- не раскрывает SQL, stack traces, connection strings и внутренние targets в HTTP-ответах.

### Граница 3: PostgreSQL — ролевая изоляция

| Роль                | Возможности                                                    |
|---------------------|----------------------------------------------------------------|
| `course_owner`      | `NOLOGIN`. Владелец объектов, `SECURITY DEFINER` функций.      |
| `course_runtime`    | `LOGIN`. Выполняет `api.invoke`. Нет прямого DML к `payment.*`.|
| `course_publication`| `LOGIN`. Ограниченная публикация manifests и workflow-карт, служебные workflow-команды. Без owner membership и прямого DML к `payment.*`. |
| `course_migration`  | `LOGIN`. Выполнение DDL-миграций структуры схемы (admin).      |
| `workflow_worker`   | `LOGIN`. Выполняет `workflow.claim_jobs`, `api.invoke`, `workflow.finish_job`, `workflow.fail_job`. Нет прямого DML к `payment.*` и `workflow.*`. |
| `outbox_dispatcher` | `LOGIN`. Только `delivery.claim_outbox`, `delivery.succeed_outbox`, `delivery.fail_outbox`. |
| `inbox_reconciler` | `LOGIN`. Только `delivery.reconcile_inbox`. |
| `autocheck_reader` | `LOGIN`. Только `SELECT` безопасных views схемы `autocheck`; без членства в других ролях, прямых таблиц, application functions, CREATE и TEMP. |

`course_runtime` не может напрямую INSERT/UPDATE/DELETE в `payment.operations` или `payment.operation_events` — только через `SECURITY DEFINER` функции, принадлежащие `course_owner`. `payment.operations` защищена триггерами неизменяемости и графом допустимых переходов статусов, а `payment.operation_events` является строго append-only.

## Последствия

- Gateway не получает прямого SQL-доступа к БД; публичные запросы проходят JWT/policy в API.
- Атака на Api ограничена возможностями роли `course_runtime`.
- Идемпотентность и уникальность операций закреплены в PostgreSQL. Admission, response validation и корректное управление общей транзакцией остаются обязанностями C# runtime.
