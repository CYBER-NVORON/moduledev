# C4 Container Diagram

## Контекст

Database-First Action Runtime — финтех-платформа для выполнения бизнес-операций через зарегистрированные PostgreSQL-функции.

## Диаграмма контейнеров

```mermaid
C4Context
    title Database-First Action Runtime — Container Diagram

    Person(client, "Client", "HTTP-клиент или автопроверка")

    System_Boundary(system, "Action Runtime") {
        Container(gateway, "Gateway", "C# ASP.NET Core", "Reverse proxy. Whitelist /api/, /openapi/, /health/. Порт 8080. Не имеет доступа к БД.")
        Container(api, "Api", "C# ASP.NET Core", "Generic action runtime. JWT auth, schema validation, api.invoke(), транзакционный контроль.")
        Container(cli, "Cli", "C# Console", "Публикация манифестов, управление версиями actions.")
        Container(migrator, "Migrator", "C# Console", "Автоматическое применение SQL-миграций структуры схемы (admin).")
        ContainerDb(postgres, "PostgreSQL 16", "PostgreSQL", "Авторитетное хранилище: catalog, idempotency, payment, autocheck. Бизнес-логика в SECURITY DEFINER функциях.")
    }

    Rel(client, gateway, "HTTP", "POST /api/{module}/{action}, GET /openapi/*, GET /health/*")
    Rel(gateway, api, "HTTP", "Compose DNS http://api:8080")
    Rel(api, postgres, "TCP/Npgsql", "SELECT api.invoke(...), SELECT catalog.actions")
    Rel(cli, postgres, "TCP/Npgsql", "INSERT catalog.actions")
    Rel(migrator, postgres, "TCP/Npgsql", "Миграции")
```

## Потоки данных

1. **Action call**: Client → Gateway (`:8080`) → Api (internal) → PostgreSQL (`api.invoke`)
2. **Publication**: Cli → PostgreSQL (`catalog.actions`)
3. **Migration**: Migrator → PostgreSQL (миграции)
4. **Health**: Client → Gateway `/health/ready` → Api `/health/ready` → PostgreSQL `SELECT 1`
5. **OpenAPI**: Client → Gateway `/openapi/*` → Api → PostgreSQL `catalog.actions`

## Сетевая изоляция

- Gateway — единственный контейнер с опубликованным host-портом (`8080`).
- Api, Cli, PostgreSQL доступны только внутри Docker network `course-net`.
- Gateway не имеет credentials к PostgreSQL и не выполняет SQL.
