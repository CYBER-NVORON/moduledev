# ModuleDev

Платформа выполнения PostgreSQL actions и распределённых workflow. PostgreSQL хранит бизнес-логику, состояние процессов и историю; C# API и workers исполняют зарегистрированные контракты, Python-сервисы обеспечивают доставку запросов и приём квитанций.

[Техническое задание](TASK.md) · [Документация](docs/README.md) · [JSON-контракты](contracts/course-1)

## Решение

### Архитектура

Compose запускает 12 сервисов в сетях `gateway-net` и `course-net`. Только gateway публикует порт хоста. CLI применяет миграции и завершается с кодом 0.

| Сервис | Назначение |
|---|---|
| `gateway` | ASP.NET Core reverse proxy: `/api/`, `/openapi/` и health. Без доступа к БД. |
| `api` | .NET 10: JWT, JSON Schema, generic HTTP-вызов `api.invoke` и контроль транзакции. |
| `cli` | Миграции, публикация actions и workflow-карт, управление версиями. |
| `worker-a`, `worker-b` | Два экземпляра одного .NET image: claim, исполнение action, lease/fencing. |
| `outbox-dispatcher`, `outbox-dispatcher-b` | Доставка запросов провайдеру через фиксированные SQL-функции. |
| `receipt-adapter` | Преобразование callback в подписанную квитанцию. Без доступа к БД. |
| `inbox-reconciler`, `inbox-reconciler-b` | Применение сохранённых квитанций к workflow. |
| `provider-simulator` | Платёжный HTTP-симулятор v0.2.0 с идемпотентностью и callbacks. |
| `postgres` | PostgreSQL 16, база `course`, постоянный named volume. |

Пять Python-процессов используют один image с Python 3.12, `psycopg2-binary` и `httpx`.

[C4-диаграмма](docs/c4-containers.md) и ADR: [границы доверия](docs/adr-trust-boundary.md), [результаты действий](docs/adr-results.md), [lease/fencing](docs/adr-lease-fencing.md), [Python-периметр](docs/adr-python-perimeter.md).

### Запуск

Нужны Docker с Linux containers и Docker Compose v2 с поддержкой `!reset` и `!override` для проверок. Локальный .NET SDK для контейнерного запуска не требуется.

1. Скопируйте шаблон переменных окружения в `.env`:
   - Linux/macOS: `cp .env.example .env`
   - Windows (PowerShell / cmd): `copy .env.example .env`
2. Задайте JWT key, HMAC key и callback capability. Выпустите `PROVIDER_CALLBACK_TOKEN` по [инструкции локальных запросов](docs/local-requests.md).
3. Запустите стек:

```bash
docker compose up -d --build
```

Проверьте завершение миграций и готовность API:

```text
docker compose ps -a
docker compose logs cli
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

В Windows PowerShell используйте `curl.exe`. Readiness возвращает HTTP 200 при доступной БД и установленной схеме; успешный выход `cli` с кодом 0 штатен.

Без `.env` стек запускается с development-паролями PostgreSQL. API обслуживает health, но без JWT-настроек отклоняет actions с `503 dependency.unavailable`. Автопроверка задаёт собственные настройки и токены.

После изменения `.env` выполните `docker compose up -d`, чтобы пересоздать контейнеры с новым окружением. Команда `docker compose down` сохраняет БД; `--volumes` удаляет её данные.

### Конфигурация

Compose читает окружение хоста и `.env`. Значения в [шаблоне](.env.example) предназначены для локальной разработки.

| Настройка | Назначение |
|---|---|
| `COURSE_JWT_ISSUER`, `COURSE_JWT_AUDIENCE`, `COURSE_JWT_SIGNING_KEY` | JWT HS256; ключ — не менее 32 UTF-8 байт. |
| `COURSE_*_PASSWORD` | Раздельные пароли ролей PostgreSQL. |
| `PROVIDER_HMAC_SECRET` | Общий ключ adapter и API для подписи байтов квитанции. |
| `PROVIDER_CALLBACK_CAPABILITY` | Секретный сегмент callback URL. |
| `PROVIDER_CALLBACK_TOKEN` | JWT с principal `receipt-provider` и scope `receipt:write`. |
| `COURSE_TEST_PROFILE`, `COURSE_FAILPOINT` | Разрешение аварийных остановок и имя точки; обычный профиль — `0`. |

Полный список переменных, значения timeout/retry/lease, SQL-роли и внутренние порты: [конфигурация](docs/configuration.md).

Строки подключения формируются внутри Compose. Изменение пароля в `.env` не обновляет пароль роли в существующей БД; скрипт создания ролей выполняется только при инициализации пустого volume.

### Миграции

SQL-файлы находятся в `migrations/`. На пустом volume PostgreSQL создаёт роли, применяет `001..015` и записывает SHA-256 файлов. При последующих запусках CLI проверяет checksums и применяет новые миграции.

Применённые файлы сохраняют имя и содержимое. При несовпадении checksum мигратор останавливается. Для обновления существующей БД сначала остановите обработчики и выполните административную подготовку роли наблюдателя: [порядок обновления](docs/configuration.md#обновление-бд).

Для публикации собственного action функция PostgreSQL должна уже существовать. CLI читает пути внутри контейнера; каталог с manifest монтируется отдельно:

```text
docker compose run --rm -v "./:/input:ro" cli action validate /input/manifest.json
docker compose run --rm -v "./:/input:ro" cli action publish /input/manifest.json
docker compose run --rm cli action list
docker compose run --rm cli action activate payment.request --version 1
```

Формат документа: [пример manifest](contracts/course-1/action-manifest.example.json). Отключение версии: `action disable <module.action> --version <v> [--replacement-version <v>]`. Встроенные actions и платёжные карты публикуются миграциями.

### Workflow-карты

Карта задаёт граф шагов `automatic`, `wait_signal`, `manual`, `end` в JSON или YAML. CLI проверяет схему, достижимость шагов и финалов, отсутствие циклов, transitions/outcomes, JSON Pointers, retry policy, версии actions и полномочия worker.

```text
docker compose run --rm -v "./:/input:ro" cli flow validate /input/contracts/course-1/payment-review-v1.flow.json
docker compose run --rm -v "./:/input:ro" cli flow publish /input/contracts/course-1/payment-review-v1.flow.json
docker compose run --rm cli flow activate payment-review --version 1
docker compose run --rm cli flow list
docker compose run --rm cli flow get <process-id>
```

Опубликованная версия карты неизменяема. Переключение активной версии влияет на новые процессы; запущенные сохраняют свою версию.

Для собственных карт доступны `flow start` и `flow signal`:

```text
docker compose run --rm -v "./:/input:ro" cli flow start <flow> --business-key <key> --data /input/data.json
docker compose run --rm -v "./:/input:ro" cli flow signal <process-id> --type <signal-type> --message-id <message-id> --payload /input/signal.json
```

Платёжные процессы запускаются через `payment.submit`, который атомарно связывает operation и process. Ручное решение передаётся через `workflow.manual`. Карты, правила и примеры: [платёжные процессы](docs/payment-workflows.md), [HTTP-запросы](docs/local-requests.md).

### Worker

Два worker конкурентно захватывают jobs через `FOR UPDATE SKIP LOCKED`. Claim фиксируется короткой транзакцией; затем action, проверка результата и `finish_job` выполняются в одной транзакции.

После истечения lease другой worker может повторить шаг. `jobId` и `executionId` сохраняются, `attemptId` создаётся заново, `leaseVersion` увеличивается. Устаревший finish откатывает предметный эффект. Ошибка записывается отдельным `fail_job`; `STALE` остаётся в истории, но не расходует бюджет ошибок.

Идентификаторы исполнения и права worker поступают из доверенного контекста, независимо от payload. Подробности: [ADR lease/fencing](docs/adr-lease-fencing.md).

### Внешняя доставка

Dispatcher отправляет запрос после commit Outbox claim. При повторах сохраняются `externalRequestId`, тело запроса и `Idempotency-Key`; provider дедуплицирует платёж.

По умолчанию выполняются четыре попытки с задержками 200/400/800 мс и добавочным jitter 0–100 мс. Исчерпание доставки переводит Outbox в `DEAD`, оставляя operation в `PROCESSING` и process в `WAITING_SIGNAL`. Поздняя валидная квитанция продолжает процесс.

Adapter принимает callback по capability URL, проверяет формат, преобразует его в receipt v1 и отправляет через gateway с JWT и HMAC. API сохраняет Inbox; reconciler применяет квитанцию к workflow. Контракты: [HTTP и SQL](docs/external-contracts.md), [восстановление доставки](docs/reliability.md).

### Проверка

Для официальных checker нужны Python 3.11+, Git, Bash, PostgreSQL client (`psql`), Docker и Compose v2. В Windows используется WSL Debian/Ubuntu с включённой Docker Desktop WSL integration.

Linux/macOS/WSL:

```bash
bash ./check.sh --week 4
```

Windows PowerShell:

```powershell
.\check.ps1 -Week 4
```

Wrapper автоматически скачивает checker в `scripts/repo/` и проверяет закреплённый commit и чистоту checkout. Первый запуск требует доступа к GitHub; существующая копия используется без повторного скачивания. Docker отдельно загружает необходимые образы.

| Неделя | Репозиторий | Commit |
|---|---|---|
| 1 | [moduledev-week-1-gateway-task](https://github.com/fintech-dev-lab/moduledev-week-1-gateway-task/tree/51fbca54412ceb42964048fb0b19354d51488a22) | `51fbca54412ceb42964048fb0b19354d51488a22` |
| 2 | [moduledev-week-2-workflow-task](https://github.com/fintech-dev-lab/moduledev-week-2-workflow-task/tree/0db15e2ee8e6722369425439cc44946d9a049bd5) | `0db15e2ee8e6722369425439cc44946d9a049bd5` |
| 3 | [moduledev-week-3-python-perimeter-task](https://github.com/fintech-dev-lab/moduledev-week-3-python-perimeter-task/tree/563e2fcf5ada68e71e88675fc7740ab81083126d) | `563e2fcf5ada68e71e88675fc7740ab81083126d` |
| 4 | [moduledev-week-4-reliability-task](https://github.com/fintech-dev-lab/moduledev-week-4-reliability-task/tree/e1ae7e03c6a4f2da5dc2ee9f02ebe3f26b2d16a3) | `e1ae7e03c6a4f2da5dc2ee9f02ebe3f26b2d16a3` |

Команды предыдущих недель:

```bash
bash ./check.sh --week 1
bash ./check.sh --week 2
bash ./check.sh --week 3
```

```powershell
.\check.ps1 -Week 1
.\check.ps1 -Week 2
.\check.ps1 -Week 3
```

Checkers недель 1–2 допускают текущий Compose. Checker недели 3 не разрешает пароли БД вторым репликам dispatcher/reconciler и требует версию решения до их добавления. Checker недели 4 поддерживает обе реплики и включает сценарии недели 3.

По умолчанию запускается неделя 4. Отчёты `week-X-public-report.json` сохраняются в корне и исключены из Git. Для сохранения стенда после проверки используйте `--keep-stack` / `-KeepStack`. При нескольких WSL-дистрибутивах укажите `-Distro Debian`.

Собственные проверки:

```text
dotnet test src/Tests/Tests.csproj -c Release
python -m unittest discover -s src/Python/tests
python -m unittest discover -s scripts/tests
python src/Tests/workflow_regression.py
python src/Tests/reliability_regression.py
```

C# unit-тестам нужен .NET SDK 10. DB-регрессиям нужны Python 3.10+ и Docker Compose; они создают отдельный стенд и удаляют его после проверки. [CI](.github/workflows/db-regressions.yml) запускает wrapper tests и DB-регрессии. Состав сценариев, параметры wrapper и устранение ошибок запуска: [проверки](docs/testing.md).

### Диагностика

```text
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
curl http://localhost:8080/openapi/default.json
docker compose logs -f api worker-a worker-b
docker compose logs -f outbox-dispatcher outbox-dispatcher-b receipt-adapter inbox-reconciler inbox-reconciler-b
```

API, workers и Python-сервисы предоставляют внутренние health/metrics. Readiness зависит от PostgreSQL; у adapter — от gateway. Недоступность provider отражается в Outbox и не делает API неготовым.

`diagnostics.trace` восстанавливает цепочку операции по сохранённым связям БД. `diagnostics.stalled` находит операции, ожидающие квитанцию после исчерпания доставки. Оба action требуют `diagnostics:read`.

Форматы метрик и логов: [наблюдаемость](docs/observability-contracts.md). Команды trace/stalled и порядок восстановления: [runbook](docs/reliability.md).

### Ограничения

- Trace возвращает полную историю без пагинации; объём ответа и стоимость SQL растут с числом событий.
- Архивирование истории не реализовано.
- API принимает тело запроса размером до 1 МиБ и разбирает JSON в памяти.
- Аутентификация использует общий HS256-ключ; выпуск и обновление клиентских JWT выполняются отдельно.
- Gateway не ограничивает частоту запросов. Таймауты и лимиты ресурсов не заменяют управление нагрузкой.
