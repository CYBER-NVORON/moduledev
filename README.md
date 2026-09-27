# ModuleDev: Database-First Action Runtime & Workflow Engine

Данный репозиторий содержит реализацию платформы для выполнения действий (Week 1), оркестрации распределенных процессов (Week 2) и интеграции с внешними провайдерами (Week 3). 

Проект спроектирован по парадигме **Database-First**, где основным вычислительным ядром и источником истины (Source of Truth) выступает PostgreSQL, а C#-сервисы и Python-демоны являются stateless-прослойками (API, Worker, Gateway, Python Perimeter).

Обязательные требования: [TASK.md](TASK.md) и [JSON schemas](contracts/course-1).


## Решение

### Архитектура

В Compose объявлены 10 сервисов в двух сетях (`gateway-net` и `course-net`). `cli` работает как одноразовый migrator и после успешного выполнения завершается:

| Сервис       | Технологии / Роль | Детали реализации |
|--------------|-------------------|-------------------|
| `gateway`    | ASP.NET Core (.NET 10) | Reverse proxy (порт 8080) на базе Minimal API и `IHttpClientFactory`. Единственный сервис, смотрящий наружу. Проксирует `/api/` и `/openapi/`, не имеет доступа к БД. |
| `api`        | ASP.NET Core (.NET 10) | Generic HTTP-to-SQL транслятор. Выполняет JWT-аутентификацию, проверяет JSON Schema и вызывает PL/pgSQL функцию `api.invoke`. |
| `worker-a/b` | C# Console, .NET 10 | Два экземпляра одного image: короткий claim, lease/fencing и общий executor workflow actions. |
| `cli`        | .NET Console App  | Инструмент управления (публикация actions, валидация workflow-карт, управление версиями, применение миграций БД). |
| `outbox-dispatcher` | Python 3.12 | Демон (Transaction Outbox pattern), опрашивающий таблицу outbox и отправляющий запросы во внешние системы (провайдеры). |
| `receipt-adapter` | Python 3.12 | Проверяет capability URL и legacy callback, преобразует его в receipt v1 и подписывает exact JSON bytes. Без доступа к БД. |
| `inbox-reconciler` | Python 3.12 | Демон для разбора таблицы inbox и применения полученных receipt-сообщений к внутренним workflow. |
| `provider-simulator`| Simulator | Имитация внешнего платежного провайдера (v0.2.0) для тестирования интеграций и callbacks. |
| `postgres`   | PostgreSQL 16     | База `course`; схемы `catalog`, `idempotency`, `payment`, `workflow`, `receipt`, `delivery`, `autocheck`. Бизнес-логика в PostgreSQL functions. |

C4-диаграмма: [docs/c4-containers.md](docs/c4-containers.md)  
ADR о границах доверия: [docs/adr-trust-boundary.md](docs/adr-trust-boundary.md)  
ADR о результатах: [docs/adr-results.md](docs/adr-results.md)  
ADR об интеграциях (Python): [docs/adr-python-perimeter.md](docs/adr-python-perimeter.md)  
ADR о lease/fencing: [docs/adr-lease-fencing.md](docs/adr-lease-fencing.md)  

Python-сервисы используют один локально собираемый image, стандартную библиотеку, `psycopg2-binary` и `httpx`. Выбор `http.server` и ручной валидации — решение реализации, а не требование использовать конкретный framework.

### Запуск

Нужны Docker с Linux containers и Docker Compose v2. Для checker overrides нужна поддержка `!reset` и `!override`. Локальный .NET SDK для контейнерного запуска не нужен; Python 3.10+ нужен для checker и собственных DB-регрессий с хоста.

1. Скопируйте шаблон переменных окружения в `.env`:
   - Linux/macOS: `cp .env.example .env`
   - Windows (PowerShell / cmd): `copy .env.example .env`
2. Для полного ручного сценария заполните JWT, HMAC и callback capability. Создайте настоящий `PROVIDER_CALLBACK_TOKEN` по [инструкции с HTTP-примерами](docs/local-requests.md): произвольная строка вместо подписи JWT не работает.
3. Запустите стек сервисов:
   ```bash
   docker compose up -d --build
   ```

Чистый запуск не требует `.env`: у PostgreSQL есть явно обозначенные development-пароли. Без JWT-конфигурации API обслуживает health, но отклоняет actions с `503 dependency.unavailable`. Checker подставляет собственные параметры автоматически.

```text
docker compose ps -a
docker compose logs cli
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

В Windows при наличии PowerShell alias `curl` используйте `curl.exe`. После изменения `.env` выполните `docker compose up -d`: простой `restart` новое окружение не подхватывает. Остановка с сохранением БД — `docker compose down`; опция `--volumes` удаляет данные и для обычного обновления не нужна.

**Как работает инициализация базы (Database-First Init):**
Вместо хардкода паролей в SQL, был собран кастомный образ БД (`src/Postgres/Dockerfile`). 
При самом первом запуске встроенный механизм Postgres исполняет скрипт `000_set_passwords.sh`, который безопасно подтягивает пароли из `.env` и создает роли. Следом накатываются SQL-миграции `001..013`, создавая таблицы, привязывая их к ролям, и устанавливая строгие Append-Only триггеры на таблицы аудита.

### Конфигурация

Compose читает переменные окружения хоста и `.env` (шаблон `.env.example`). `.env` не коммитится. Основные внешние настройки:

| Переменная               | Сервис   | Описание                              |
|--------------------------|----------|---------------------------------------|
| `COURSE_JWT_ISSUER`      | `api`    | Issuer JWT-токенов                    |
| `COURSE_JWT_AUDIENCE`    | `api`    | Audience JWT-токенов                  |
| `COURSE_JWT_SIGNING_KEY` | `api`, `cli` | HS256 ключ подписи (≥32 байт)         |
| `COURSE_GATEWAY_PORT` | `gateway` | Host-порт, по умолчанию `8080` |
| `COURSE_POSTGRES_PASSWORD` | `postgres` | Пароль администратора при создании БД |
| `PROVIDER_URL` | dispatcher | Default `http://provider-simulator:8081` |
| `OUTBOX_OWNER` | dispatcher | Владелец lease, default `outbox-dispatcher` |
| `PROVIDER_CALLBACK_CAPABILITY` | adapter, provider | Непредсказуемый сегмент callback URL; это не JWT |
| `PROVIDER_CALLBACK_TOKEN` | adapter | JWT для исходящего запроса в API: `receipt-provider`, `receipt:write` |
| `PROVIDER_HMAC_SECRET` | adapter, API | Общий ключ HMAC для exact receipt bytes |
| `RECEIPT_API_URL` | adapter | Default `http://gateway:8080/api/receipt/accept` |
| `PROVIDER_AUDIT_TOKEN` | provider | Доступ checker к audit; для обычной доставки не используется |
| `COURSE_TEST_PROFILE` | workers, dispatcher, reconciler | `1` включает короткие интервалы тестирования; обычный запуск оставляет пустым |
| `COURSE_FAILPOINT` | C# workers | `after_job_claim` или `after_action_before_finish`; обычный запуск оставляет пустым |

Пароли ролей БД задаются через `COURSE_RUNTIME_PASSWORD`, `COURSE_PUBLISHER_PASSWORD`, `COURSE_MIGRATOR_PASSWORD`, `COURSE_WORKER_PASSWORD`, `COURSE_OUTBOX_PASSWORD` и `COURSE_INBOX_PASSWORD`. Compose содержит значения для локальной разработки; реальные секреты в репозитории не хранятся. Проверка подменяет signing key и пароли через Compose override.

`COURSE_DB_CONNECTION`, `COURSE_MIGRATION_DB_CONNECTION`, `DATABASE_URL` и `API_BACKEND_URL` формируются внутри Compose. Для их изменения нужен Compose override, а не одноимённая строка в `.env`. Полный контракт настроек — в документации. Изменение пароля в `.env` не меняет пароль роли в уже существующей БД: `000_set_passwords.sh` работает только при создании пустого volume.

### Миграции

SQL-миграции находятся в `migrations/`. При первом запуске их применяет PostgreSQL initdb и записывает checksums; при последующих запусках сервис `cli` проверяет SHA-256 и применяет новые миграции. Его завершение с кодом 0 после `docker compose up -d --build` нормально.
При этом инициализация ролей БД и безопасное проставление паролей происходит ДО миграций через скрипт `000_set_passwords.sh` в `/docker-entrypoint-initdb.d` PostgreSQL.

Для обновления БД с той же историей имён и checksum:

```text
docker compose build cli
docker compose stop api worker-a worker-b outbox-dispatcher receipt-adapter inbox-reconciler
docker compose up -d postgres
docker compose run --rm cli migration apply /migrations
docker compose up -d --build
```

Продолжайте обновление только после успешного завершения migration command. Compose не ждёт завершения CLI перед запуском API/workers, а readiness не проверяет максимальный номер миграции.

Миграция `012_operation_event_contract.sql` обновляет функции `payment.submit/complete/reject/approve` и проверяет новые записи событий: `OPERATION_CREATED`, `OPERATION_SUBMITTED`, `OPERATION_COMPLETED`, `OPERATION_REJECTED`. Для существующей БД применяется тот же порядок обновления с остановкой обработчиков. Миграции `001..011` и их checksums сохранены.

Старая append-only история не переписывается. `autocheck.operation_events` и `operation.events` переводят только исторические имена `OperationSubmitted`, `OperationCompleted`, `OperationRejected` в канонические uppercase-значения, сохраняя IDs, хеши и время. CHECK добавлен как `NOT VALID`: он проверяет новые записи, а существующие строки остаются нетронутыми. `workflow.events` сохраняет PascalCase (`TaskFailed`, `StepCompleted` и другие).

Миграция `013_outbox_retry_policy.sql` обновляет `delivery.fail_outbox`: всего 4 попытки, включая первую, с задержками повторов 200/400/800 мс. Сохраняются права функции и проверки владельца, версии lease и состояния `LEASED`; поздняя ошибка dispatcher не меняет `CONFIRMED`. Применяется тот же порядок обновления БД, без изменения миграций `001..012`. Существующие строки Outbox, включая `DEAD`, автоматически не перезапускаются.

БД с прежним локальным именем миграции `008_week3_delivery.sql` требует отдельного согласования истории: текущий файл называется `008_delivery_system.sql`, и CLI идентифицирует миграцию по имени и checksum. Не подменяйте checksum и записи журнала для обхода проверки.

CLI читает пути внутри контейнера. Для публикации пользовательского manifest смонтируйте каталог с ним (пример предполагает `manifest.json` в корне репозитория):

```bash
docker compose run --rm -v "./:/input:ro" cli action validate /input/manifest.json
docker compose run --rm -v "./:/input:ro" cli action publish /input/manifest.json
docker compose run --rm cli action list
docker compose run --rm cli action activate payment.request --version 1
```

Публикация регистрирует action в `catalog.actions`, но не создаёт SQL target: функция должна существовать и иметь нужную сигнатуру. [Example manifest](contracts/course-1/action-manifest.example.json) показывает форму документа. Готовые actions и платёжные карты регистрируются миграциями при чистом запуске.

Для отключения версии предусмотрена `action disable <module.action> --version <v> [--replacement-version <v>]`. Активация и отключение выполняются CLI атомарно; запущенные workflow сохраняют закреплённую версию карты.

### Workflow-карты

Модель процесса задаётся графом шагов в JSON или YAML и хранится как JSON в `workflow.flow_versions`. Типы шагов: `automatic`, `wait_signal`, `manual`, `end`.

**Механизм валидации (CLI):**
Перед публикацией карты команда `flow validate` проверяет граф в памяти:
1. **Связность графа (BFS - Поиск в ширину):** Начиная со `start_step`, алгоритм проверяет, что до каждого объявленного узла можно добраться. Недостижимые узлы (orphan nodes) вызывают ошибку.
2. **Отсутствие циклов (DFS - Поиск в глубину):** Используется раскраска графа (белый/серый/черный). Если при обходе мы натыкаемся на "серый" узел (находящийся в текущем стеке вызовов) — обнаружен цикл, валидация отклоняется.
3. Валидация JSON Pointers для маппинга переменных (RFC 6901).

Также проверяются JSON Schema карты, transitions/outcomes, retry, enabled action version, равенство policy карты и action и достаточность прав worker.

```text
docker compose run --rm -v "./:/input:ro" cli flow validate /input/contracts/course-1/payment-review-v1.flow.json
docker compose run --rm -v "./:/input:ro" cli flow publish /input/contracts/course-1/payment-review-v1.flow.json
docker compose run --rm cli flow activate payment-review --version 1
docker compose run --rm cli flow list
docker compose run --rm cli flow get <process-id>
```

Для собственных учебных карт:

```text
docker compose run --rm -v "./:/input:ro" cli flow start <flow> --business-key <key> --data /input/data.json
docker compose run --rm -v "./:/input:ro" cli flow signal <process-id> --type <signal-type> --message-id <message-id> --payload /input/signal.json
```

Платёжные процессы запускаются через `payment.submit`: он атомарно связывает operation и process и выбирает server-side binding. Ручное решение недели 3 передаётся через `workflow.manual`; тестовая CLI-команда `flow test-finish` его не заменяет.

### Worker

Воркеры `worker-a` и `worker-b` допускают повторное исполнение после сбоя. Защита от дублирующего зафиксированного эффекта PostgreSQL основана на общей транзакции action/finish и fencing; внешние HTTP-вызовы выполняются через Outbox отдельно.

**Технические особенности реализации:**
1. **Concurrent Polling (SKIP LOCKED):** 
   Воркеры конкурентно вызывают функцию `workflow.claim_jobs`. `FOR UPDATE SKIP LOCKED` позволяет захватывать доступные строки без ожидания уже заблокированных jobs; текущий C# worker запрашивает по одному job.
2. **Lease и Fencing Token (Optimistic Concurrency):**
   Каждый захват увеличивает счётчик `lease_version` и задаёт `lease_until`. `finish_job` и `fail_job` сверяют owner и версию lease. После reclaim прежний владелец получает `workflow.lease_stale`. `jobId` и `executionId` сохраняются, `attemptId` создаётся заново.
3. **Smart Retries:**
   Для retryable error и runtime timeout PostgreSQL переводит job в `RETRY_WAIT` до `next_attempt_at`. Задержки берутся из `delays_ms`, а не вычисляются обязательным экспоненциальным алгоритмом. `STALE` сохраняется в истории, но не расходует failure budget `max_attempts`.

Claim фиксируется короткой транзакцией. Затем `api.invoke`, валидация response и `finish_job` выполняются в одной другой транзакции. При ошибке предметный эффект откатывается; `fail_job` вызывается отдельно. Missing source mapping даёт `workflow.mapping_missing`; существующий JSON `null` передаётся request schema.

Trusted context содержит `processId`, `jobId`, `executionId`, `attemptId` и числовой `leaseVersion` из claim. Поля payload не назначают эти значения. Result action проверяется в исходном JSON-типе, включая `null`, без подмены пустым объектом.

### Python-периметр (Week 3)

Сначала `payment.request` создаёт operation из `operationKind`, строкового `amount` и `currency=RUB`. Затем `payment.submit` принимает только `operationId` и использует server-side binding: `PAYMENT_EXECUTION` → `payment-processing`, `PAYMENT_APPROVAL` → `payment-review`. Только в `payment-review` правило `course-limit-v1` одобряет сумму до `100000.00 RUB` включительно; при превышении процесс переходит в `WAITING_MANUAL` и ждёт action `workflow.manual` с решением, reason и principal из JWT.

`payment-processing` создаёт external request/Outbox, ждёт receipt и завершает operation по сохранённому результату. Повтор `payment.submit` возвращает исходный результат команды со `status=PROCESSING`, даже после завершения процесса. Актуальное состояние читается через `operation.get` и `workflow.get`.

* **Dispatcher:** опрашивает таблицу через `delivery.claim_outbox` и отправляет запросы провайдеру. При успехе/ошибке вызывает `succeed_outbox` / `fail_outbox`.
* **Adapter:** принимает legacy callback provider v0.2.0 без HMAC по capability URL. Валидирует body до 64 KiB, преобразует его в receipt v1 и подписывает compact sorted JSON bytes. Передаёт JWT и HMAC через gateway; подпись проверяет API. Успешный `receipt.accept` отвечает HTTP `200` после сохранения Inbox; adapter возвращает ответ API.
* **Reconciler:** опрашивает `inbox` и применяет ответы провайдеров к внутренним стейт-машинам через `delivery.reconcile_inbox`.

### Provider-simulator

Официальный `v0.2.0` образ провайдера (имитатора внешнего API). Ожидает HTTP POST запросы с заголовками `Idempotency-Key` (соответствует `externalRequestId`) и `X-Correlation-ID`. Поддерживает механизм retry policy. Audit API защищен `PROVIDER_AUDIT_TOKEN` для проверки авточекером.

Успешный ответ provider — HTTP `202` со строгим JSON body. Transport errors, `408`, `429`, `5xx` допускают retry по policy БД; некорректный body при `202` — terminal error. Outbox допускает повторные HTTP attempts, provider дедуплицирует payment. Точные bytes/headers и правила повторов — во внешнем контракте.

Политика повторов Outbox в БД: первая попытка и до трёх повторов с задержками **200, 400 и 800 мс**. После retryable-ошибки четвёртой попытки или любой terminal-ошибки запись переходит в `DEAD`. Эти значения используются в обоих профилях и соответствуют [уточнённому тестовому профилю недели 3](https://github.com/fintech-dev-lab/moduledev-week-3-python-perimeter-task/blob/563e2fcf5ada68e71e88675fc7740ab81083126d/docs/07-autocheck-outline.md#тестовый-профиль). Задержка задаёт время доступности следующего claim; фактическая отправка также зависит от poll interval dispatcher.

### Проверка

Локальный [wrapper](scripts/check.py) проверяет, что в `scripts/repo/` лежит репозиторий нужной недели с закреплённым commit, и запускает `public_check.py`. Автоматически клонировать он не умеет — нужно сделать это вручную один раз (шаг 1 ниже). Папка `scripts/repo/` исключена из Git и Docker build context.

Нужны Python 3.10+, Git, Bash, Docker и Compose v2.


Закреплённые версии:

| Неделя | Репозиторий | Commit |
|---|---|---|
| 1 | [moduledev-week-1-gateway-task](https://github.com/fintech-dev-lab/moduledev-week-1-gateway-task/tree/51fbca54412ceb42964048fb0b19354d51488a22) | `51fbca54412ceb42964048fb0b19354d51488a22` |
| 2 | [moduledev-week-2-workflow-task](https://github.com/fintech-dev-lab/moduledev-week-2-workflow-task/tree/0db15e2ee8e6722369425439cc44946d9a049bd5) | `0db15e2ee8e6722369425439cc44946d9a049bd5` |
| 3 | [moduledev-week-3-python-perimeter-task](https://github.com/fintech-dev-lab/moduledev-week-3-python-perimeter-task/tree/563e2fcf5ada68e71e88675fc7740ab81083126d) | `563e2fcf5ada68e71e88675fc7740ab81083126d` |

**Шаг 1 — склонировать checker-репозитории (один раз):**

```bash
# Неделя 1
git clone --config core.autocrlf=false https://github.com/fintech-dev-lab/moduledev-week-1-gateway-task.git scripts/repo/moduledev-week-1-gateway-task
git -C scripts/repo/moduledev-week-1-gateway-task checkout 51fbca54412ceb42964048fb0b19354d51488a22

# Неделя 2
git clone --config core.autocrlf=false https://github.com/fintech-dev-lab/moduledev-week-2-workflow-task.git scripts/repo/moduledev-week-2-workflow-task
git -C scripts/repo/moduledev-week-2-workflow-task checkout 0db15e2ee8e6722369425439cc44946d9a049bd5

# Неделя 3
git clone --config core.autocrlf=false https://github.com/fintech-dev-lab/moduledev-week-3-python-perimeter-task.git scripts/repo/moduledev-week-3-python-perimeter-task
git -C scripts/repo/moduledev-week-3-python-perimeter-task checkout 563e2fcf5ada68e71e88675fc7740ab81083126d
```


**Шаг 2 — запустить полную проверку (требуется Docker):**

Linux/macOS/WSL:

```bash
bash ./check.sh --week 1
bash ./check.sh --week 2
bash ./check.sh --week 3
```

Windows PowerShell:

```powershell
.\check.ps1 -week 1
.\check.ps1 -week 2
.\check.ps1 -week 3
```

PowerShell wrapper автоматически выбирает единственный установленный дистрибутив WSL, исключая служебные `docker-desktop` и `docker-desktop-data`. При нескольких дистрибутивах укажите нужный явно, например `.\check.ps1 -week 3 -distro Debian`; список — `wsl --list --verbose`. В выбранном дистрибутиве должны быть Python 3.10+, Git, Bash и `docker compose`; для Docker Desktop включите WSL integration. Пути переводятся через `wslpath`.

По умолчанию оба wrapper запускают неделю 3. Отчёты `week-X-public-report.json` сохраняются в корне решения, commit checker печатается перед запуском. Для сохранения стека используйте `--keep-stack` / `-keepStack`. Wrapper передаёт exit code checker (`0` — успех, `1` — нарушения, `2` — ошибка checker/окружения).

Для другого решения используйте `bash ./check.sh --week 3 --repo /path/to/solution`. Checker ищется в `scripts/repo/` относительно расположения wrapper; изменить путь можно через `--checkers-dir`. При несовпадении commit или локальных изменениях в checkout запуск останавливается. Wrapper вызывает официальный Python entrypoint: shell wrapper недели 2 не позволяет передать внешний `--repo`.



**Собственные регрессии workflow и PostgreSQL:**

Нужны Python 3.10+ и Docker Compose; команда одинакова для Windows PowerShell, Linux и macOS:

```text
python src/Tests/workflow_regression.py
```

Набор создаёт отдельный Compose project без опубликованных портов и удаляет его контейнеры и volume после проверки. Проверяются обновление БД с миграций `001..010` через `011/012/013`, повторное применение миграций, неизменяемость опубликованных карт, переключение активной версии, конкурирующие claim, устаревший finish, retry после STALE, повтор/конфликт сигнала, mapping отсутствующего значения и JSON null, права worker и восстановление после остановки между action и finish.

Проверка политики Outbox вызывает production-функции под ролью `outbox_dispatcher`: четыре попытки, точные интервалы 200/400/800 мс, запрет раннего claim, успех на четвёртой попытке, исчерпание повторов, немедленный `DEAD` при terminal error и защита от неверного owner/stale lease/изменения `CONFIRMED`. SQL fixture откатывается; ожидание задержек заменено изменением `next_attempt_at` в тестовой БД.

Регрессии недели 3 проверяют сохранность legacy events при обновлении, канонические имена в таблице и публичных чтениях, rollback submit, 20 конкурентных submit с одинаковыми/разными ключами, финалы по receipt и auto/manual decision. SQL fixture проверяет предметную границу; JWT/HMAC и provider HTTP проверяет внешний checker. Реальный worker проверяется на полный trusted context, независимость от одноимённых полей payload, JSON-цепочки attempts, отсутствие чувствительных сообщений в логах и rollback некорректного `result=null`. Команды не запускаются автоматически при сборке приложения.

Локальные unit-тесты C# (требуется .NET SDK 10):

```text
dotnet test src/Tests/Tests.csproj -c Release
```

Unit-тесты Python receipt: `python -m unittest discover -s src/Python/tests`. Проверки wrapper без сети/Docker: `python -m unittest discover -s scripts/tests`. Команды в README не означают, что последняя редакция уже протестирована.

Миграция `011_workflow_invariants.sql` защищает опубликованные карты и исправляет расход retry budget: STALE сохраняется в истории, но не считается ошибкой исполнения. Порядок обновления и ограничение для переименованной `008` описаны в разделе «Миграции». Права `workflow-worker` (`workflow:execute`, `payment:internal`) заданы независимо от policy действий и проверяются при публикации карты и исполнении задания.

### Диагностика

Диагностика строится на стандартных HealthChecks и логах ASP.NET Core:

- **Liveness Gateway:** `curl http://localhost:8080/health/live` (проверка, что процесс не завис).
- **Readiness API:** `curl http://localhost:8080/health/ready` — gateway обращается к API, API проверяет наличие `catalog.actions` и `api.invoke` в БД. Это не проверка всех миграций, provider или Python-сервисов.
- **Динамический OpenAPI:** `curl http://localhost:8080/openapi/default.json` (API на лету генерирует swagger.json на основе манифестов из `catalog.actions`).
- **Логи:** gateway/API, Python и C# worker используют JSON. Worker пишет `worker.claim`, `worker.invoke`, `worker.finish`, `worker.fail`, `worker.retry`, `worker.stale` с `timestamp`, `instanceId`, `processId`, `jobId`, `executionId`, `attemptId`, `leaseVersion`, `outcome`, `errorCode`, `jobState`. События уровня процесса (`worker.started` и другие) имеют `null` вместо IDs задания. Payload, SQL exception text и target message в worker-логи не включаются.
  ```bash
  docker compose logs -f api
  docker compose logs -f worker-a
  docker compose logs -f outbox-dispatcher receipt-adapter inbox-reconciler
  ```

`worker.claim` следует за подтверждённым claim; `worker.invoke` означает начало вызова, а не commit. `worker.finish` появляется только после commit action/finish. `worker.fail` отражает подтверждённый `fail_job`; `worker.retry` дополнительно появляется при фактическом `RETRY_WAIT`. `worker.stale` означает отказ устаревшей попытке. `worker.fail_unconfirmed` сообщает, что запись результата fail_job не подтверждена; `worker.abandoned`/`worker.interrupted` требуют сверки с БД и последующим reclaim. По `attemptId` и `leaseVersion` сопоставляйте цепочку с `autocheck.attempts`. Логи не атомарны с commit и не заменяют durable историю. Формат `failpoint.reached` сохранён.

### Ограничения

- **Нагрузка на соединения PostgreSQL** — каждый HTTP-запрос (через Generic Route) удерживает физическое соединение для выполнения `api.invoke`. В HighLoad потребуется пулер соединений (PgBouncer) в Transaction Mode.
- **Хранение истории** — для events и dispatches нет политики архивирования. `workflow.events` защищены от UPDATE/DELETE; `workflow.attempts` меняет статус при завершении, поэтому не является полностью неизменяемой таблицей.
- **Кэш схем** — API использует `ConcurrentDictionary` и ограничивает добавление новых записей при достижении 1000 элементов. Это не отдельная гарантия защиты от одновременной компиляции одной схемы.
- **Симметричный ключ JWT (HS256)** — сервис валидирует токены по общему секрету (`COURSE_JWT_SIGNING_KEY`). В production-среде предпочтительна асимметричная криптография (RS256/ES256) с динамической загрузкой публичных ключей по JWKS от доверенного IdP (Keycloak/OIDC).
- **Отсутствие Rate Limiting и Circuit Breaker на Gateway** — Gateway реализует минималистичный reverse proxy без ограничения частоты запросов (rate limiting per IP/client), защитных очередей и прерывания каскадных сбоев (circuit breaker) при деградации `api` или базы данных.
- **Лимит размера полезной нагрузки** — размер тела запроса ограничен 1 МБ (`MaxRequestBodySize`), а парсинг выполняется в память через `JsonNode`. Архитектура не предназначена для передачи больших бинарных файлов (требуется интеграция с S3-совместимым объектным хранилищем и pre-signed URLs).
- **Сложность мониторинга и профилирования бизнес-логики** — реализация предметных функций на PL/pgSQL усложняет сквозную распределенную трассировку (OpenTelemetry spans внутри SQL) и APM-мониторинг по сравнению с кодом на прикладном уровне.
