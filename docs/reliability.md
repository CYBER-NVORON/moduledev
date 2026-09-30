# Восстановление и диагностика

[Документация](README.md) · [Запуск и обновление БД](../README.md#миграции)

Runbook описывает доставку, диагностику и восстановление после сбоя. Форматы ответов заданы в [контракте наблюдаемости](observability-contracts.md), параметры — в [конфигурации](configuration.md). Команды установки и обновления существующего volume находятся в [README](../README.md).

## Сохранённые границы

Бизнес-состояние и решения остаются в PostgreSQL. API вызывает зарегистрированные actions через `api.invoke`, workers выполняют action и `finish_job` в общей транзакции. Python выполняет HTTP и фиксированные delivery-функции. Adapter не получает подключения к БД. Provider image сохранён из исходного задания.

Миграции `001..013` не изменены. `014_outbox_reliability.sql` добавляет `lease_until`, `dead_at` и настраиваемую политику повторов. `015_diagnostics.sql` добавляет безопасные связи dispatch → operation/process, две диагностические actions и представление метрик. Старый SQL dispatcher сохранён как закрытая `api.invoke_core`; обёртка записывает связи в той же транзакции. Trace не извлекает identifiers из логов, body или хешей.

Миграция `016_lease_deadlines_and_stalled_age.sql` проверяет действительность lease jobs и Outbox по `clock_timestamp()` после блокировки строки, в том числе до следующего claim. В Outbox сроки lease, retry и перехода в `DEAD` также используют фактическое время. Миграция добавляет 10-секундный порог `stalled`, сохраняя checksums `001..015` и прежние права SQL-функций.

Для старого volume перед применением миграций нужен административный `prepare_database.sql`: создать `autocheck_reader`, установить его пароль из окружения и отозвать прежние PUBLIC-привилегии. Он выполняется автоматически при чистом initdb, отдельно — при обновлении. Исторические dispatches связываются только там, где сохранённые requestId/principal или executionId позволяют доказать связь; восстановить отсутствовавшие в старой БД сведения невозможно.

В состав миграции `015_diagnostics.sql` также входит частичный индекс по `delivery.outbox.created_at` для состояний `PENDING`, `LEASED`, `RETRY_WAIT`. Индекс не меняет поведение доставки, значения метрик или JSON-контракты. Создание индекса выполняется в обычной транзакции мигратора; на существующем volume применяйте его с остановленными обработчиками по процедуре обновления в README.

## Доставка, аренда и поздняя квитанция

Две реплики dispatcher используют одну роль `outbox_dispatcher` и разные `OUTBOX_OWNER`. Короткий claim с `FOR UPDATE SKIP LOCKED` фиксирует owner, новую lease_version, срок аренды и номер попытки. Он выбирает доступные `PENDING`/`RETRY_WAIT` или `LEASED` с истёкшей арендой. HTTP выполняется после commit claim. Завершение доставки проверяет состояние, owner, version и срок lease. Ответ устаревшего владельца ничего не меняет.

`externalRequestId`, тело запроса и `Idempotency-Key` остаются прежними при повторах. Повторные HTTP attempts допустимы; provider дедуплицирует платёж. Успешный HTTP `202` означает принятие запроса, а окончательный результат приходит отдельной квитанцией. Dispatcher использует общий асинхронный deadline HTTP, включая DNS: синхронное разрешение имени остановленного контейнера не должно удерживать попытку дольше lease.

По умолчанию разрешены четыре попытки всего. Задержка после retryable-ошибки: `min(base * 2^(attempt-1), max) + random(0..jitterMax)` миллисекунд. Значения `base=200`, `max=800`, `jitterMax=100` поступают из Compose в настройки PostgreSQL `course.outbox_*`. Timeout, `408`, `429`, `5xx` допускают retry; terminal-ошибка завершает доставку сразу. Исчерпанная попытка, оставшаяся с истёкшим lease после падения dispatcher, также переводится в `DEAD` очередным claim.

`DEAD` завершает автоматическую доставку. Он **не** отклоняет операцию: operation остаётся `PROCESSING`, process — `WAITING_SIGNAL`. Поздний валидный receipt переводит Outbox в `CONFIRMED`, продолжает workflow и сохраняет `dead_at`, число попыток и сведения о прежней ошибке. Поздний `succeed_outbox`/`fail_outbox` не откатывает `CONFIRMED`.

Обе реплики reconciler используют одну функцию `delivery.reconcile_inbox`. Дедупликация receipt и сигнала, блокировки строк и общая транзакция не позволяют повторно применить квитанцию к операции.

## Health и метрики

| Процессы | Внутренний порт | Readiness dependency |
|---|---:|---|
| API | 8080 | PostgreSQL и наличие `autocheck.metrics` |
| worker-a, worker-b | 8080 | PostgreSQL и наличие `autocheck.metrics` |
| outbox-dispatcher, outbox-dispatcher-b | 8080 | PostgreSQL |
| inbox-reconciler, inbox-reconciler-b | 8080 | PostgreSQL |
| receipt-adapter | 8082 | `/health/ready` gateway |

У этих процессов `GET /health/live` возвращает `200 {"status":"live"}`, готовность — `200 {"status":"ready"}` или `503 {"status":"not_ready","code":"dependency.unavailable"}`. Liveness не проверяет БД/provider. Health запускается независимо от рабочего polling loop; потеря БД не завершает Python-процесс. Недоступность provider не делает dispatcher/API/worker неготовыми.

Gateway сохраняет собственный liveness и проксирует readiness API. Только его порт опубликован на хост. Внутренние endpoints можно опросить через `docker compose exec` из контейнера, имеющего доступ к нужной сети. Например, для API:

```text
docker compose exec -T receipt-adapter python -c "import urllib.request; print(urllib.request.urlopen('http://api:8080/metrics').read().decode())"
```

`/metrics` отдаёт `application/openmetrics-text; version=1.0.0; charset=utf-8` и завершающий `# EOF`. В API значения вычисляются одним SQL-запросом из durable состояния. Другие проверяемые процессы публикуют `component_up` без уникальных labels.

| Метрика API | Содержание |
|---|---|
| `workflow_jobs_ready` | READY, доступные RETRY_WAIT и LEASED с истёкшим lease |
| `workflow_job_oldest_age_seconds` | Возраст старейшего доступного job от created_at; 0 при отсутствии |
| `workflow_processes_waiting` | WAITING_SIGNAL и WAITING_MANUAL, в том числе ожидание после DEAD |
| `outbox_pending` | PENDING, LEASED, RETRY_WAIT, включая отложенные retries |
| `outbox_oldest_age_seconds` | Возраст старейшей записи в тех же состояниях от created_at; 0 при отсутствии |
| `workflow_failures_total` | Количество сохранённых terminal workflow failures (события TaskFailed) |

DEAD, DELIVERED и CONFIRMED не входят в Outbox-метрики. Counter объявлен `# TYPE workflow_failures counter`, sample называется `workflow_failures_total`. IDs не используются как labels. При недоступности БД API возвращает 503 вместо вымышленных нулевых значений.

Частичный индекс из миграции `015` содержит только активную часть Outbox и её `created_at`, используемый обеими Outbox-метриками. При большой доле завершённой истории он позволяет избежать чтения всей таблицы. Точный COUNT всё равно обрабатывает активные записи; на маленькой таблице PostgreSQL вправе выбрать последовательное сканирование. Индекс не ограничивает выдачу и не заменяет политику хранения истории.

## Trace и stalled

Обе actions — обычные manifests version 1, `POST`, outcome `FOUND`, policy `diagnostics:read`, idempotency `none/none`. Они читают сохранённое состояние; стандартный action audit разрешён. Роль HTTP-клиента не получает SQL-доступа.

Выпустите JWT со scope `diagnostics:read` по [инструкции](local-requests.md). Сохраните в `trace.json` объект `{"identifier":"<идентификатор>"}`, в `stalled.json` — `{}`. В Windows используйте `curl.exe`:

```text
curl -X POST http://localhost:8080/api/diagnostics/trace -H "Authorization: Bearer <DIAGNOSTICS_JWT>" -H "Content-Type: application/json" -H "X-Action-Version: 1" --data-binary "@trace.json"
curl -X POST http://localhost:8080/api/diagnostics/stalled -H "Authorization: Bearer <DIAGNOSTICS_JWT>" -H "Content-Type: application/json" -H "X-Action-Version: 1" --data-binary "@stalled.json"
```

Trace принимает correlationId, requestId, operationId, processId, stepInstanceId, jobId, executionId, attemptId, externalRequestId, messageId или decisionId. Все идентификаторы одной цепочки возвращают одинаковые предметные факты; отличается `query`. Массивы упорядочены по времени и ID, timestamps — UTC, amount — строка с двумя знаками. Неизвестный identifier даёт `404 diagnostics.trace_not_found`; неправильный payload — `422 payload.invalid`; отсутствие JWT — 401; отсутствие scope — 403.

Trace возвращает все сохранённые факты цепочки. Пагинация и усечение не предусмотрены текущей схемой ответа. Стоимость запроса и размер ответа растут с историей; timeout действия не ограничивает память агрегации.

Stalled возвращает уникальные операции с сочетанием `Outbox.DEAD + process.WAITING_SIGNAL + operation.PROCESSING`, если с сохранённого `dead_at` прошло не менее 10 секунд. Свежая DEAD операция до этой границы отсутствует в выборке; её можно найти через trace. [Правило возраста и расчёт запаса](observability-contracts.md#diagnosticsstalled) не зависят от времени запуска процесса. `items` содержит только operationId/processId/externalRequestId, сортируется по operationId. Пустая выборка — `items: []`. Никакие jobs или новые отправки этим запросом не создаются.

`autocheck_reader` имеет LOGIN с внешним паролем, SELECT только безопасных views `autocheck`, без role membership, application EXECUTE, физического DML, CREATE/TEMP или sequence privileges. Диагностика не содержит JWT, HMAC/signature, паролей, полного payload/body, callback message или manual reason.

## Аварийный runbook

1. Проверьте health и метрики, затем найдите цепочку через trace по известному ID. Сверяйте `attemptCount`, `leaseVersion`, `nextAttemptAt`, `lastErrorCode`, `deadAt` с сохранённым состоянием.
2. При падении worker/dispatcher перезапустите нужный сервис обычным `docker compose up -d <service>`. После истечения lease другая реплика продолжит обработку. Не меняйте executionId/externalRequestId и не создавайте новую операцию для имитации восстановления.
3. При временной недоступности provider восстановите его до исчерпания автоматических попыток. Dispatcher повторит запрос, readiness останется успешным при работающей БД. При недоступности PostgreSQL восстановите БД и дождитесь readiness; liveness приложения должен сохраняться.
4. Если доставка уже DEAD, запросите stalled и trace. Операция по-прежнему ждёт подтверждённого результата provider. Валидная поздняя квитанция по обычному adapter → API → Inbox маршруту продолжит её. В реализации нет административного action для принудительного перевода DEAD в PENDING или подмены результата SQL-обновлением.
5. После восстановления проверьте финальное состояние, одну запись предметного эффекта и историю попыток. `docker compose down`/`up` без `--volumes` сохраняет PostgreSQL и диагностические факты.

## Failpoints и тесты

Failpoints разрешены только при `COURSE_TEST_PROFILE=1` и точном `COURSE_FAILPOINT`. Подтверждение — JSON с `event=failpoint.reached`, `name` и непустым `instanceId`. После него процесс ждёт завершения; остановка выполняется тестом через SIGKILL. В обычном профиле переменная игнорируется.

| Failpoint | Где остановлен процесс | Состояние после SIGKILL |
|---|---|---|
| after_job_claim | worker: после commit claim, до action | Lease истекает, другой worker повторяет тот же job/execution |
| after_action_before_finish | worker: после action, до finish/commit | Предметная транзакция откатывается; reclaim выполняет шаг заново |
| after_outbox_claim | dispatcher: после commit claim, до HTTP | Другой dispatcher захватывает запись после lease |
| after_provider_response | dispatcher: после ответа provider, до записи результата | Повтор с тем же externalRequestId безопасен для provider |
| after_inbox_saved | API: после commit receipt/Inbox/idempotency, до HTTP | HTTP replay возвращает сохранённый результат, reconciler продолжает процесс |
| after_manual_decision | API: после успешной validation результата, до commit | Решение откатывается; повтор команды фиксирует одно решение |

Перед проверкой after_inbox_saved останавливаются обе реплики reconciler, иначе они вправе обработать Inbox раньше наблюдения. Для отдельного dispatcher/worker failpoint останавливается конкурирующая реплика, чтобы она не забрала fixture раньше нужного процесса. Failpoints не следует включать глобально для обычного стенда.

Команды: `python src/Tests/workflow_regression.py`, `python src/Tests/reliability_regression.py`, официальный `.\check.ps1 -Week 4` на Windows или `bash ./check.sh --week 4`. Подробные prerequisites и checkout checker — в README. [Контракт аварийных проверок](testing.md#детерминированные-failpoints) описывает подготовку каждого сценария. Оригинальные checkers не изменяются.

Логи исполнения содержат применимые IDs, action/flow/step, outcome или безопасный error code и duration. Retry логируется как WARNING, delivery DEAD — ERROR. [События dispatcher](observability-contracts.md#события-dispatcher) описывают сетевые шаги и результат обновления Outbox. Логи не атомарны с commit: отсутствие строки после падения не доказывает отсутствие эффекта; проверяйте PostgreSQL trace. Payload, receipt body, manual reason и exception text не выводятся.
