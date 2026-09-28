# Проверки и аварийные сценарии

[Документация](README.md) · [Команды и окружение](../README.md#проверка) · [Runbook](reliability.md)

Проверка использует generic HTTP API, container CLI, provider simulator и read-only SQL views. Помимо ответа API проверяются сохранённое состояние, история, отсутствие повторного предметного эффекта и восстановление после сбоя.

## Доступные прогоны

| Набор | Что проверяет |
|---|---|
| Официальный checker: `.\check.ps1 -Week 4` или `bash ./check.sh --week 4` | Чистую сборку и запуск, платёжные сценарии, роли, две реплики dispatcher/reconciler, восстановление provider до исчерпания попыток, полный restart, health/metrics, trace/stalled и отсутствие секретов |
| `python src/Tests/workflow_regression.py` | Обновление БД, публикацию, конкуренцию, fencing, retries, сигналы, предметные события, DEAD и позднюю квитанцию, все 11 типов trace identifiers и индекс метрик |
| `python src/Tests/reliability_regression.py` | Шесть границ commit с SIGKILL, HTTP/JWT/HMAC, восстановление, исчерпание доставки при остановленном provider и позднюю квитанцию |

Требования к окружению и команды unit tests находятся в [README](../README.md#проверка). Wrapper автоматически подготавливает недостающий checker в `scripts/repo/`, проверяет закреплённый SHA и чистоту checkout. Оригинальные checkers не редактируются. Закреплённые checkers недель 1 и 2 допускают дополнительные сервисы. Checker недели 3 отклоняет передачу паролей БД вторым репликам dispatcher/reconciler на этапе `compose-contract`, поэтому предназначен для версии решения до добавления этих реплик. Контракт недели 4 требует вторые реплики; её checker разрешает им соответствующие учётные данные и проверяет в том числе сценарии недели 3.

Официальный прогон записывает `week-4-public-report.json`; сгенерированный отчёт не включается в Git. Список сценариев ниже описывает проверяемые свойства, а результат конкретного запуска подтверждается его отчётом и выводом.

Собственные DB-регрессии и проверки wrapper также выполняет [отдельное задание CI](../.github/workflows/db-regressions.yml) на push/pull request или при ручном запуске. Оно использует временный Compose project без production secrets.

## Настройка запуска checker

PowerShell wrapper выбирает единственный установленный Linux-дистрибутив WSL. При нескольких дистрибутивах укажите его явно: `.\check.ps1 -Week 4 -Distro Debian`; список — `wsl --list --verbose`. Служебные `docker-desktop` и `docker-desktop-data` для запуска не используются.

В выбранном дистрибутиве нужны Python 3.11+, Git, Bash, `psql` и доступ к Docker Compose через WSL integration. В Debian/Ubuntu клиентские утилиты устанавливаются командой `sudo apt-get install python3 git bash postgresql-client`.

Для проверки другой рабочей копии используйте `bash ./check.sh --week 4 --repo /path/to/solution`. Параметр `--checkers-dir` задаёт каталог checker вместо `scripts/repo/`. Wrapper вызывает официальный Python entrypoint с явными путями к решению и fixtures. Неверный SHA или локальные изменения checker останавливают запуск; существующий checkout автоматически не перезаписывается.

Отчёт сохраняется в проверяемой рабочей копии. Exit codes: `0` — успех, `1` — нарушения контракта, `2` — ошибка checker или окружения. Для сохранения стенда после проверки используйте `--keep-stack` / `-KeepStack`.

Если Docker Desktop сообщает `ports are not available` / `bind: ... forbidden by its access permissions`, проверьте зарезервированные диапазоны Windows командой `netsh interface ipv4 show excludedportrange protocol=tcp`. При попадании случайного порта checker в такой диапазон повторите запуск.

## Технические инварианты

| Этап | Проверяемый результат |
|---|---|
| 1. Сборка | Все images собираются без ручных действий |
| 2. Запуск | Контейнеры стартуют на чистом окружении |
| 3. Готовность | `live` и `ready` отражают фактическое состояние |
| 4. Контракт | OpenAPI и реальное поведение согласованы |
| 5. Оркестратор | Manifest публикует функцию как endpoint; target/schema/policy соблюдаются |
| 6. Workflow | Версии, шаги, переходы, jobs, attempts и ожидание сохранены |
| 7. Предметный результат | Operation, event и обязательное свидетельство согласованы |
| 8. Идемпотентность | Повторы не создают дополнительных эффектов |
| 9. Конкуренция | Инварианты сохраняются при нескольких клиентах и worker |
| 10. Восстановление | Restart и expired lease не теряют работу |
| 11. Outbox/Inbox | Сообщения не теряются и применяются не более одного раза |
| 12. Наблюдаемость | Путь собирается по одному известному идентификатору |
| 13. Безопасность | Нет секретов, SQL target и лишних данных в журналах |

## Проверочные проекции

Read-only schema `autocheck` имеет версию контракта `course-1`. Все identifiers имеют тип `uuid`, если в таблице не указан `text`; время имеет тип `timestamptz` UTC, версии — `integer`, `lease_version` — `bigint`, хеши — lowercase hex `text`.

| View | Обязательные колонки |
|---|---|
| `autocheck.contract_info` | `contract_version text`, `generated_at timestamptz` |
| `autocheck.action_definitions` | `module text`, `action text`, `version integer`, `http_method text`, `target_schema text`, `target_function text`, `outcomes jsonb`, `enabled boolean`, `is_default boolean` |
| `autocheck.action_dispatches` | `correlation_id`, `request_id text`, `module text`, `action text`, `version integer`, `principal text`, `payload_hash text`, `status text`, `outcome text`, `occurred_at` |
| `autocheck.operations` | `operation_id`, `request_id text`, `operation_kind text`, `amount numeric`, `currency text`, `status text`, `process_id`, `created_at`, `updated_at` |
| `autocheck.operation_events` | `event_id`, `operation_id`, `event_type text`, `payload_hash text`, `occurred_at` |
| `autocheck.flow_versions` | `flow_name text`, `flow_version integer`, `status text`, `is_active boolean`, `published_at` |
| `autocheck.processes` | `process_id`, `business_key text`, `flow_name text`, `flow_version integer`, `state text`, `current_step_key text`, `created_at`, `updated_at` |
| `autocheck.steps` | `step_instance_id`, `process_id`, `step_key text`, `step_type text`, `state text`, `outcome text`, `entered_at`, `completed_at` |
| `autocheck.jobs` | `job_id`, `process_id`, `step_instance_id`, `execution_id`, `state text`, `lease_owner text`, `lease_version bigint`, `lease_until`, `attempt_count integer`, `next_attempt_at` |
| `autocheck.attempts` | `attempt_id`, `job_id`, `execution_id`, `lease_version bigint`, `attempt_number integer`, `status text`, `outcome text`, `error_code text`, `started_at`, `finished_at` |
| `autocheck.signals` | `message_id text`, `process_id`, `signal_type text`, `body_hash text`, `status text`, `received_at` |
| `autocheck.workflow_events` | `event_id`, `process_id`, `step_instance_id`, `event_type text`, `occurred_at` |
| `autocheck.external_requests` | `external_request_id text`, `operation_id`, `state text`, `payload_hash text`, `created_at` |
| `autocheck.receipts` | `message_id text`, `external_request_id text`, `message_version integer`, `outcome text`, `signature_valid boolean`, `body_hash text`, `received_at`, `applied_at` |
| `autocheck.outbox` | `outbox_id`, `external_request_id text`, `state text`, `attempt_count integer`, `next_attempt_at`, `last_error_code text`, `created_at`, `delivered_at` |
| `autocheck.inbox` | `message_id text`, `body_hash text`, `state text`, `received_at`, `applied_at` |
| `autocheck.decisions` | `decision_id`, `process_id`, `step_instance_id`, `source text`, `principal text`, `reason_hash text`, `outcome text`, `rule_version text`, `created_at` |

Nullability следует модели состояния: например, `process_id` отсутствует до `submit`, `lease_owner` и `lease_until` пусты до первого claim, `outcome` пуст у незавершённого или ошибочного шага. `lease_version` — счётчик поколений аренды, до первого claim он равен 0. `contract_info` содержит ровно одну строку. Проекции не раскрывают secrets, signature и полный payload. Login role `autocheck_reader` получает пароль из `COURSE_AUTOCHECK_PASSWORD`, читает только views schema `autocheck` и не имеет memberships, application function/sequence privileges, доступа к physical relations, `CREATE` или `TEMP`.

Все enum-подобные значения в views используют uppercase ASCII:

| Поле | Допустимые значения |
|---|---|
| `action_dispatches.status` | `OK`, `ERROR` |
| `operations.status` | `CREATED`, `PROCESSING`, `COMPLETED`, `REJECTED` |
| `flow_versions.status` | `PUBLISHED` |
| `processes.state` | `CREATED`, `RUNNING`, `WAITING_SIGNAL`, `WAITING_MANUAL`, `COMPLETED`, `FAILED` |
| `steps.step_type` | `AUTOMATIC`, `WAIT_SIGNAL`, `MANUAL`, `END` |
| `steps.state` | `PENDING`, `READY`, `RUNNING`, `WAITING`, `COMPLETED`, `FAILED` |
| `jobs.state` | `READY`, `LEASED`, `RETRY_WAIT`, `SUCCEEDED`, `DEAD` |
| `attempts.status` | `RUNNING`, `SUCCEEDED`, `FAILED`, `STALE` |
| `signals.status` | `ACCEPTED`, `APPLIED`, `CONFLICT` |
| `external_requests.state` | `CREATED`, `SENT`, `CONFIRMED` |
| `receipts.outcome` | `COMPLETED`, `REJECTED` |
| `outbox.state` | `PENDING`, `LEASED`, `RETRY_WAIT`, `DELIVERED`, `DEAD`, `CONFIRMED` |
| `inbox.state` | `RECEIVED`, `APPLIED`, `CONFLICT` |
| `decisions.source` | `LIMIT_RULE`, `MANUAL` |
| `decisions.outcome` | `APPROVED`, `REJECTED` |

`autocheck.outbox` также содержит `lease_owner text`, `lease_version bigint`, `lease_until timestamptz`, `dead_at timestamptz`. До первого claim owner и срок аренды пусты, версия равна 0; `dead_at` заполняется при переходе в `DEAD`. Поздняя валидная квитанция может перевести delivery из `DEAD` в `CONFIRMED`, не удаляя диагностические данные исчерпанной доставки.

Поля `outcome` actions и steps используют значения из соответствующего manifest/map. `workflow_events.event_type` является исключением из uppercase-правила и использует PascalCase domain event names, например `SignalReceived`, `ProcessCompleted` и `TaskFailed`. Error codes используют lowercase dotted identifiers из опубликованного error contract.

## Сценарии конкуренции и отказов

Для проверки инвариантов меняют значения, порядок, параллельность и точки отказа:

- 20–100 конкурентных одинаковых команд;
- один idempotency key с разными данными;
- попытка передать БД, schema, function и SQL через route/payload;
- disabled action, несовместимая версия и недостаточная policy;
- новый action key и новая карта после сборки C#;
- неизвестные service/action/version в task definition;
- попытка worker вызвать action без required policy;
- canary action с изменением и error envelope;
- result, не соответствующий response schema;
- несколько worker и dispatcher;
- lease expiration и stale completion;
- падение после claim и после предметного изменения;
- early, duplicate и conflicting receipt;
- один `messageId` с разным телом;
- invalid HMAC и message version;
- malformed legacy callback, wrong capability и подмена adapter target;
- exact compact JSON bytes, timestamp preservation и HMAC over raw body;
- Python processes из разных/prebuilt images или с лишними PostgreSQL privileges;
- конкурентные manual decisions;
- provider unavailable и lost response;
- рестарт API, worker и dispatcher на границах commit;
- граничные decimal values;
- неизвестные поля и версии;
- отсутствие или подмена correlation metadata;
- секреты и полный payload в коде, images или logs.

Это перечень технических сценариев, а не утверждение о покрытии каждого случая публичным checker. Состав доступных прогонов и команды перечислены выше.

## Детерминированные failpoints

Failpoints включаются только в test profile и недоступны из публичного API. Контур задаёт компоненту `COURSE_TEST_PROFILE=1` и `COURSE_FAILPOINT=<name>` через Compose override до его запуска.

Минимальные точки:

| `COURSE_FAILPOINT` | Компонент | Граница |
|---|---|---|
| `after_job_claim` | `worker-a` | после commit аренды до action |
| `after_action_before_finish` | `worker-a` | после action effect и contract validation внутри transaction до `finish_job` и commit |
| `after_outbox_claim` | `outbox-dispatcher` | после commit claim до provider HTTP |
| `after_provider_response` | `outbox-dispatcher` | после provider response до conditional delivery completion |
| `after_inbox_saved` | `api` | после commit Inbox, receipt и idempotency result, до HTTP-ответа; оба reconciler остановлены до callback |
| `after_manual_decision` | `api` | после выполнения `workflow.manual` и валидации результата, до commit общей transaction решения, перехода и следующего job |

Имена services в таблице задают целевой экземпляр базового сценария. До создания работы проверка останавливает конкурирующий `worker-b` или `outbox-dispatcher-b`, чтобы работу получил целевой исполнитель. После acknowledgement и принудительного завершения целевого контейнера второй экземпляр можно запустить для проверки reclaim/fencing. Failpoint включается только у одного экземпляра.

Для `after_inbox_saved` проверка заранее останавливает `inbox-reconciler` и `inbox-reconciler-b`, вызывает callback и ждёт acknowledgement API. После остановки API сохранённый Inbox доступен через read-only проекции; затем API и оба reconciler запускаются без failpoint. Это исключает применение signal до проверяемой границы. API не выполняет работу reconciler.

Для `after_manual_decision` остановка API откатывает решение, переход, новый job и успешный idempotency result вместе; повтор команды с теми же `Idempotency-Key` и payload создаёт ровно одно решение. Незавершённая команда восстанавливается автоматически, без ручного удаления ключа. «После выполнения» здесь не означает «после commit». SQL effect и валидация результата остаются в одной transaction generic action runtime.

При достижении точки компонент пишет одну JSON-запись `{"event":"failpoint.reached","name":"after_job_claim","instanceId":"..."}` и блокируется до принудительной остановки. Проверка ждёт эту запись, останавливает компонент, удаляет failpoint из override, запускает компонент и проверяет инварианты. Потеря ответа после фактического принятия provider включается документированным режимом `lost-response` самого simulator. Случайные `sleep` вместо acknowledgement barrier не используются.

## Тестовый профиль

| Параметр | Значение |
|---|---:|
| Lease job | 2 секунды |
| Poll interval worker | не более 100 мс |
| Provider timeout | 500 мс |
| Максимум попыток Outbox | 4, включая первую |
| Задержки Outbox | 200, 400, 800 мс |
| Добавочный jitter Outbox | от 0 до 100 мс |
| Lease Outbox | 2 секунды |
| Poll interval Outbox | не более 100 мс |
| Inbox reconciliation | не более 500 мс |
| Provider callback retry | 200 мс |
| Timeout аварийного сценария checker | 30 секунд |

Все интервалы задаются конфигурацией. Обычный профиль может использовать более консервативные значения без изменения семантики.

## Изоляция

Официальный checker и собственные DB/reliability регрессии создают отдельные Compose projects с синтетическими секретами и собственными PostgreSQL volumes. Test overrides могут временно публиковать loopback-порты внутренних сервисов; обычный Compose публикует только gateway. Fixtures монтируются отдельно, исходный код решения не меняется. Собственные регрессии удаляют свой стенд после выполнения; `-KeepStack` официального wrapper сохраняет стенд для диагностики.

Новые actions и карты публикуются через container CLI после сборки API/worker, без пересборки C# и ручного DML. API-клиент и runtime-роли не получают права мигратора. При проверке полного restart PostgreSQL volume сохраняется: `docker compose down` выполняется без удаления volumes. Случайные задержки не заменяют failpoint acknowledgement.
