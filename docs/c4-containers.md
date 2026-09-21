# C4 Container Diagram

## Контекст

Database-First Action Runtime — финтех-платформа для выполнения бизнес-операций через зарегистрированные PostgreSQL-функции.

## Диаграмма контейнеров

```mermaid
C4Container
    title Database-First Action Runtime — Container Diagram

    Person(client, "Client", "HTTP-клиент или автопроверка")

    System_Boundary(system, "Action Runtime") {
        Container(gateway, "Gateway", "C# ASP.NET Core", "Reverse proxy. Whitelist /api/, /openapi/, /health/. Порт 8080. Не имеет доступа к БД.")
        Container(api, "Api", "C# ASP.NET Core", "Generic action runtime. JWT auth, schema validation, api.invoke(), транзакционный контроль.")
        Container(cli, "Cli", "C# Console", "Публикация манифестов, workflow-карт, управление версиями.")
        Container(dispatcher, "Outbox dispatcher", "Python 3.12", "Фиксированные SQL функции и provider HTTP.")
        Container(adapter, "Receipt adapter", "Python 3.12", "Legacy callback → signed receipt; без БД.")
        Container(reconciler, "Inbox reconciler", "Python 3.12", "Фиксированная функция reconciliation.")
        Container(provider, "Provider v0.2.0", "Выданный image", "Idempotent payment и legacy callback.")
        Container(worker_a, "Worker A", "C# Console", "Generic workflow executor. Polling, lease/fencing, claim_jobs -> api.invoke -> finish_job.")
        Container(worker_b, "Worker B", "C# Console", "Generic workflow executor (конкурентный экземпляр).")
        ContainerDb(postgres, "PostgreSQL 16", "PostgreSQL", "Авторитетное хранилище: catalog, idempotency, payment, workflow, receipt, delivery, autocheck. Бизнес-логика в PostgreSQL functions.")
    }

    Rel(client, gateway, "HTTP", "POST /api/{module}/{action}, GET /openapi/*, GET /health/*")
    Rel(gateway, api, "HTTP", "Compose DNS http://api:8080")
    Rel(api, postgres, "TCP/Npgsql", "SELECT api.invoke(...), SELECT catalog.actions")
    Rel(worker_a, postgres, "TCP/Npgsql", "SELECT workflow.claim_jobs, api.invoke, workflow.finish_job, workflow.fail_job")
    Rel(worker_b, postgres, "TCP/Npgsql", "SELECT workflow.claim_jobs, api.invoke, workflow.finish_job, workflow.fail_job")
    Rel(cli, postgres, "TCP/Npgsql", "INSERT catalog.actions, workflow.start_process, etc.")
    Rel(cli, postgres, "TCP/Npgsql", "Проверка и применение миграций при запуске")
    Rel(dispatcher, postgres, "SQL", "claim_outbox / succeed_outbox / fail_outbox")
    Rel(dispatcher, provider, "HTTP", "POST /payments")
    Rel(provider, adapter, "HTTP", "Callback с capability")
    Rel(adapter, gateway, "HTTP", "JWT и HMAC receipt v1")
    Rel(reconciler, postgres, "SQL", "reconcile_inbox")
```

## Потоки данных

1. **Action call**: Client → Gateway (`:8080`) → Api (internal) → PostgreSQL (`api.invoke`)
2. **Workflow Worker**: Worker (A/B) → PostgreSQL (отдельная короткая транзакция `claim_jobs`, затем общая транзакция `api.invoke` + validation + `finish_job`; при rollback — отдельный `fail_job`)
3. **Publication & CLI**: Cli → PostgreSQL (`catalog.actions`, `workflow.flow_versions`, `workflow.start_process`)
4. **Migration**: Cli → PostgreSQL (миграции)
5. **Health**: Client → Gateway `/health/ready` → Api `/health/ready` → PostgreSQL (проверка готовности каталога и функций `catalog.actions` / `api.invoke`)
6. **OpenAPI**: Client → Gateway `/openapi/*` → Api → PostgreSQL `catalog.actions`

## Сетевая изоляция

- Gateway — единственный контейнер с опубликованным host-портом (`8080`), подключен к `gateway-net`.
- Api подключен к `gateway-net` (для приема трафика от Gateway) и `course-net` (для взаимодействия с PostgreSQL).
- Cli, PostgreSQL, Worker-A/B, Outbox-dispatcher и Inbox-reconciler доступны только внутри Docker network `course-net`.
- Receipt-adapter изолирован в `gateway-net` и не имеет прямого доступа к PostgreSQL.
- Provider подключён к обеим сетям: принимает запросы dispatcher и отправляет callback adapter. Host-портов у него нет.
- Gateway не имеет credentials к PostgreSQL и не выполняет SQL.
