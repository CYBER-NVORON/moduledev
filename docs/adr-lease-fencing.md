# ADR: lease, fencing и защита от повторного эффекта

[Документация](README.md) · [Аварийные сценарии](reliability.md#failpoints-и-тесты)

## Контекст

В распределённой системе workflow-движка несколько экземпляров Worker (`worker-a`, `worker-b`) параллельно опрашивают очередь заданий (`workflow.jobs`) и выполняют предметные действия через `api.invoke`.

Возможны следующие сбои:

1. **Crash/Hang после захвата (claim)**: Worker захватил задание, но упал до вызова действия или во время его работы.
2. **Crash/Hang после выполнения действия**: SQL действия выполнен в открытой транзакции, но worker упал до `finish_job` и commit. Эффект ещё не зафиксирован.
3. **Stale Worker (Split-brain)**: Worker "завис" (GC pause, network latency), аренда (lease) истекла, другой воркер перехватил задание (reclaim), после чего первый очнулся и попытался зафиксировать результат.

Требуется обеспечить:

- Повторный захват задания после истечения lease и сохранение состояния. При исчерпании бюджета ошибок job переходит в `DEAD`, процесс — в `FAILED`.
- **At-most-once business effect** для каждого логического шага (один логический шаг не создаёт дублирующихся финансовых/предметных записей).
- **Строгий Fencing**: Устаревший воркер не может перезаписать или завершить перехваченное задание.

## Принятое решение

### 1. Аренда (Lease) и FOR UPDATE SKIP LOCKED

- Захват заданий осуществляется функцией `workflow.claim_jobs` с использованием `FOR UPDATE SKIP LOCKED`: worker пропускает уже заблокированные строки очереди. Блокировки внутри SQL actions требуют согласованного порядка независимо от механизма claim.
- При захвате устанавливается время истечения аренды `lease_until = clock_timestamp() + lease_seconds`.
- Если аренда истекла (`lease_until < clock_timestamp()`), задание считается готовым к перехвату (reclaim) любым другим воркером.

### 2. Fencing Token через `lease_version`

- Каждое задание хранит монотонно возрастающее поле `lease_version (bigint)`.
- При каждом захвате/перехвате (`claim_jobs`) значение `lease_version` увеличивается на 1.
- Попытка завершить задание (`workflow.finish_job` или `workflow.fail_job`) после блокировки строки проверяет состояние `LEASED`, точное совпадение `(job_id, owner, lease_version)` и `lease_until > clock_timestamp()`. NULL owner/version и истёкшая аренда отклоняются с `workflow.lease_stale`, даже если нового claim ещё не было. `now()` здесь непригоден: он сохраняет время начала транзакции, которая могла пережить аренду.

### 3. Стабильный `execution_id` для предметной идемпотентности

- Каждому логическому заданию `job` при создании присваивается постоянный `execution_id` (UUID).
- При повторных попытках (retries) или перехватах (reclaim) `job_id` и `execution_id` **сохраняются неизменными**, в то время как `attempt_id` создаётся новый, а `lease_version` инкрементируется.
- `execution_id` передаётся в доверенный контекст `api.invoke` как `requestId` / `executionId`. Если manifest требует идемпотентность, runtime использует этот requestId в её scope. Дополнительные ограничения предметных таблиц задаются самими actions.
- Контекст также содержит `processId`, `jobId`, `attemptId` и числовой `leaseVersion` из claim. Одноимённые поля payload не изменяют server-side context. При reclaim target видит новую attempt и поколение lease; сами проверки fencing остаются в `finish_job`/`fail_job`.

### 4. Атомарная транзакционная граница

- Вызов `api.invoke` и вызов `workflow.finish_job` выполняются **в одной и той же Npgsql-транзакции**.
- Если `api.invoke` завершился ошибкой или валидация схемы ответа не прошла — транзакция откатывается (предметный эффект не сохраняется). После этого в отдельной транзакции вызывается `workflow.fail_job`.
- Если воркер упал в failpoint `after_action_before_finish` (до commit) — транзакция базы данных закрывается с ROLLBACK. Никаких частичных эффектов не остаётся.

### 5. Диагностика попыток

Worker пишет JSON events `worker.claim`, `worker.invoke`, `worker.finish`, `worker.fail`, `worker.retry`, `worker.stale` с едиными `processId`, `jobId`, `executionId`, `attemptId`, `leaseVersion` и `instanceId`. Записываются безопасные outcome/error code и состояние job, без payload и exception details.

Finish логируется после commit. Fail/retry — после ответа `fail_job`, причём retry только при `RETRY_WAIT`. Если результат записи ошибки неизвестен, появляется `worker.fail_unconfirmed`, а не подтверждение retry. Прерывание до завершения отмечается `worker.interrupted`/`worker.abandoned`. Сбой между commit и записью лога возможен; авторитетным доказательством остаются PostgreSQL attempts/events. Контрактные failpoint acknowledgements сохранены отдельно.

## Последствия

### Положительные:

- Исключены фантомные дубликаты бизнес-операций при авариях и ретраях.
- После истечения lease прежний владелец не может зафиксировать результат, независимо от наличия нового claim.
- События `workflow.events` защищены от UPDATE/DELETE. Attempts не удаляются, но меняют статус `RUNNING` на `SUCCEEDED`, `FAILED` или `STALE`; это не полностью immutable rows.
- `STALE` увеличивает общее число attempts, но не расходует failure budget. Миграция `011` считает ошибки `FAILED` отдельно и выбирает задержку по номеру failure.

### Ограничения:

- Общая транзакция защищает зафиксированные эффекты PostgreSQL даже для action с `idempotency_mode=none`: stale finish откатывает вызов action. Внешний HTTP не входит в эту транзакцию; для него применяются Outbox и дедупликация провайдером.
