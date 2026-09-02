# ADR: Trust Boundary — изоляция Gateway от базы данных

## Статус

Принято.

## Контекст

Система обрабатывает финансовые операции (payment.request, operation.get) и требует строгого разделения зон доверия. Необходимо определить, какие компоненты имеют доступ к PostgreSQL и JWT-секретам.

## Решение

### Граница 1: Gateway изолирован от БД

Gateway выполняет только проксирование HTTP-запросов к внутреннему Api по Compose DNS. Gateway:

- **не имеет** строки подключения к PostgreSQL;
- **не имеет** доступа к JWT signing key;
- **не выполняет** аутентификацию, авторизацию или бизнес-логику;
- **не модифицирует** payload — только проксирует тело и контрактные заголовки (`Authorization`, `Idempotency-Key`, `X-Action-Version`).

Компрометация Gateway не даёт доступа к данным в PostgreSQL.

### Граница 2: Api изолирован внутри Docker network

Api не публикует host-порты. Доступ к Api возможен только через Gateway внутри `gateway-net`. С БД Api общается внутри `course-net`. Api:

- проверяет JWT (issuer, audience, signature, expiry, claims);
- формирует server-side context (`principal`, `consumer`, `scopes`, `correlationId`, `deadline`);
- проверяет policy на двух границах: в C# до вызова и в `api.invoke` на уровне PostgreSQL;
- не раскрывает SQL, stack traces, connection strings и внутренние targets в HTTP-ответах.

### Граница 3: PostgreSQL — ролевая изоляция

| Роль                | Возможности                                                    |
|---------------------|----------------------------------------------------------------|
| `course_owner`      | `NOLOGIN`. Владелец объектов, `SECURITY DEFINER` функций.      |
| `course_runtime`    | `LOGIN`. Выполняет `api.invoke`. Нет прямого DML к `payment.*`.|
| `course_publication`| `LOGIN`. Ограниченная публикация манифестов в `catalog.*`. Без owner-прав и без доступа к `payment.*`. |
| `course_migration`  | `LOGIN`. Выполнение DDL-миграций структуры схемы (admin).      |
| `workflow_worker`   | `LOGIN`. Выполняет `workflow.claim_jobs`, `api.invoke`, `workflow.finish_job`, `workflow.fail_job`. Нет прямого DML к `payment.*` и `workflow.*`. |

`course_runtime` не может напрямую INSERT/UPDATE/DELETE в `payment.operations` или `payment.operation_events` — только через `SECURITY DEFINER` функции, принадлежащие `course_owner`. `payment.operations` защищена триггерами неизменяемости и графом допустимых переходов статусов, а `payment.operation_events` является строго append-only.

## Последствия

- Атака на Gateway не даёт доступа к данным.
- Атака на Api ограничена возможностями роли `course_runtime`.
- Бизнес-инварианты (идемпотентность, уникальность операций) защищены на уровне PostgreSQL и не зависят от корректности C#-кода.
