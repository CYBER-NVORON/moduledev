# Внешние HTTP- и SQL-контракты

[Документация](README.md) · [Платёжные процессы](payment-workflows.md) · [Восстановление доставки](reliability.md)

Документ определяет обмен с provider, приём квитанций и SQL-интерфейс Python-процессов. JSON-тела должны соответствовать [опубликованным schemas](../contracts/course-1).

## Provider simulator

Используется image:

```text
ghcr.io/fintech-dev-lab/internship-provider-simulator:v0.2.0
sha256:70e5e0dd9ab8425be84de431ec74516f9bedf5d5529077358e2e2b2037fe0c74
```

Provider принимает идемпотентный `POST /payments` и отправляет legacy callback без JWT и HMAC:

```json
{
  "providerPaymentId": "provider-123",
  "operationId": "external-123",
  "result": "COMPLETED",
  "message": "Payment completed",
  "occurredAt": "2026-09-04T12:00:00Z"
}
```

`result` равен `COMPLETED` или `REJECTED`. Provider поддерживает режимы `success`, `reject`, `delay`, `duplicate`, `lost-response`, `early-callback`, `conflicting-callback` и `transient-error`. Его память не переживает recreate; состояние предметных операций хранится в PostgreSQL.

## Dispatcher -> provider

Dispatcher отправляет:

```http
POST {PROVIDER_URL}/payments
Content-Type: application/json
Idempotency-Key: <externalRequestId>
X-Correlation-ID: <correlationId>
```

```json
{"operationId":"<externalRequestId>","amount":"1000.00","currency":"RUB"}
```

Успешное принятие имеет HTTP `202` и строгое JSON-тело без дополнительных полей:

```json
{"providerPaymentId":"provider-123","status":"ACCEPTED"}
```

Классификация результата попытки:

| Результат | Действие dispatcher | `p_error_code` для `delivery.fail_outbox` |
|---|---|---|
| `202` и корректное тело | `delivery.succeed_outbox` | Не применяется |
| Transport error или timeout | Повтор разрешён PostgreSQL policy | `transport.error.retryable` |
| HTTP `408`, `429`, `5xx` | Повтор разрешён PostgreSQL policy | `http.<status>.retryable` |
| Прочий HTTP status | Повтор запрещён | `http.<status>.terminal` |
| `202` с некорректным UTF-8/JSON/телом | Повтор запрещён | `response.invalid.terminal` |

Redirect не считается успешным `202`. Каждый повтор одного delivery сохраняет exact body, `Idempotency-Key` и `X-Correlation-ID`. Главный инвариант при lost response: provider audit показывает `paymentCount = 1`; число HTTP attempts может быть больше одного.

## Provider -> adapter

Единственный callback route:

```http
POST /callbacks/provider-v02/{PROVIDER_CALLBACK_CAPABILITY}
Content-Type: application/json
```

Тело соответствует `provider-v02-callback.schema.json`. Adapter ограничивает body размером 64 KiB, строго отвергает unknown fields и CR/LF в строковых транспортных полях.

| Ситуация | Ответ adapter |
|---|---|
| Неверный path или capability | `404`, пустое тело |
| Некорректный Content-Length, JSON или callback schema | `400`, пустое тело |
| Generic API ответил | Тот же HTTP status, body и media type |
| Timeout, connection error или недоступность generic API | `503`, `{"status":"error","code":"dependency.unavailable"}` |

Adapter не подтверждает callback до получения ответа API. Он не повторяет вызов API самостоятельно: provider v0.2.0 повторяет callback по своему policy.

HTTP-клиент adapter использует таймаут 5 секунд для обращения к generic API. Короткий `COURSE_PROVIDER_TIMEOUT_MS` относится к запросам dispatcher к provider и не ограничивает обработку квитанции после холодного старта API.

## Преобразование callback

Adapter строго валидирует legacy body, запрещает неизвестные поля и CR/LF в строковых транспортных полях, сохраняет исходную строку `occurredAt` и переводит callback в receipt v1:

| Provider v0.2.0 | Receipt v1 |
|---|---|
| `providerPaymentId` | `messageId` |
| `operationId` | `externalRequestId` |
| `result` | `outcome` |
| `providerPaymentId` | `providerPaymentId` |
| исходная строка `occurredAt` | исходная строка `occurredAt` |
| `message` | проверяется по типу/размеру и отбрасывается |

Использование `providerPaymentId` как `messageId` делает duplicate и conflicting callback одного provider payment одной дедупликационной областью.

Нормализованный body:

```json
{
  "externalRequestId": "external-123",
  "messageId": "provider-123",
  "occurredAt": "2026-09-04T12:00:00Z",
  "outcome": "COMPLETED",
  "providerPaymentId": "provider-123",
  "version": 1
}
```

Adapter сериализует его UTF-8 вызовом, эквивалентным:

```python
json.dumps(receipt, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
```

Без BOM и завершающего LF. HMAC-SHA256 считается над точными HTTP body bytes. Заголовок:

```text
X-Provider-Signature: v1=<lowercase-hex-hmac-sha256>
```

Ключом являются точные UTF-8 bytes `PROVIDER_HMAC_SECRET` без trim, Base64 или hex decoding. Adapter отправляет body через generic gateway с `Authorization: Bearer <PROVIDER_CALLBACK_TOKEN>`, `X-Action-Version: 1`, `Idempotency-Key: <messageId>` и подписью.

HMAC доказывает целостность участка adapter -> platform. Provider v0.2.0 сам подпись не создаёт. Доверие к его callback в локальном стенде ограничено изолированной Compose network и capability URL; это не модель полного банковского криптографического периметра.

## Adapter -> `receipt.accept`

Adapter вызывает generic route:

```http
POST /api/receipt/accept
Authorization: Bearer <PROVIDER_CALLBACK_TOKEN>
Content-Type: application/json
Idempotency-Key: <messageId>
X-Action-Version: 1
X-Provider-Signature: v1=<lowercase-hex-hmac-sha256>
```

Receipt сериализуется compact JSON с sorted keys, без BOM и завершающего LF. SHA-256 body hash и HMAC вычисляются над одними и теми же exact HTTP body bytes.

Успешный subject envelope содержит:

```json
{
  "status": "ok",
  "outcome": "RECEIVED",
  "result": {
    "messageId": "provider-123",
    "externalRequestId": "external-123",
    "state": "RECEIVED"
  },
  "meta": {
    "correlationId": "00000000-0000-0000-0000-000000000000",
    "actionVersion": 1
  }
}
```

`outcome` равен `RECEIVED` для нового сообщения или `DUPLICATE` для уже известного идентичного сообщения, принятого с другой idempotency-командой. `state` отражает сохранённое состояние `RECEIVED` или `APPLIED`.

| Ситуация | HTTP status | `code` |
|---|---:|---|
| Подпись отсутствует у `receipt.accept` | `403` | `receipt.signature_required` |
| Формат/version/HMAC подписи неверны | `401` | `signature.invalid` |
| Receipt schema или `version` неверны | `422` | `payload.invalid` |
| `externalRequestId` неизвестен | `422` | `receipt.external_request_not_found` |
| Тот же idempotency key или `messageId`, но другой body | `409` | `idempotency.conflict` |

Идентичный повтор с теми же `Idempotency-Key` и body возвращает те же `status`, `outcome` и `result`. Поле `meta` и transport headers могут отличаться.

## Повтор `workflow.manual`

Идентичный повтор с теми же key и payload возвращает те же `status`, `outcome` и `result`; `meta` и transport headers могут отличаться. Изменённый payload с тем же key возвращает `409 idempotency.conflict`. Конкурирующее решение уже завершённого шага возвращает `409 workflow.decision_conflict`.

## Повтор `payment.submit`

Первый успешный submit возвращает subject result со `status = PROCESSING` и закреплёнными `processId`, `flowName`, `flowVersion`.

Любой последующий submit той же operation не создаёт новый process и возвращает исходный закреплённый subject result команды со `status = PROCESSING`, даже если operation уже завершена или default flow version была изменена. Актуальное состояние operation читается через опубликованную read boundary, а не подменяет результат submit. Изменённый body с тем же idempotency key возвращает `409 idempotency.conflict`.

## Проверка подписи в API

`api` проверяет `X-Provider-Signature` над исходными body bytes до предметного вызова и сравнивает decoded bytes constant-time. Проверка общая для подписанных запросов и не ветвится по имени action.

При успехе C# добавляет в server-side context:

```json
{
  "transport": {
    "signatureVerified": true,
    "signatureVersion": 1
  }
}
```

В context не попадают secret и полная signature. Неверный формат, версия или HMAC возвращают `401 signature.invalid`, target не вызывается. Отсутствие подписи не ломает остальные actions, но `receipt.accept` требует `transport.signatureVerified = true` и иначе возвращает `403 receipt.signature_required` без Inbox mutation.

## SQL-интерфейс Python

Dispatcher не читает физические таблицы и не вызывает `api.invoke`. Его роль `outbox_dispatcher` имеет `EXECUTE` только на функции:

```sql
delivery.claim_outbox(
  p_owner text,
  p_limit integer
) returns table (
  outbox_id uuid,
  lease_version bigint,
  external_request_id text,
  correlation_id uuid,
  amount text,
  currency text
)

delivery.succeed_outbox(
  p_outbox_id uuid,
  p_owner text,
  p_lease_version bigint,
  p_provider_payment_id text
) returns jsonb

delivery.fail_outbox(
  p_outbox_id uuid,
  p_owner text,
  p_lease_version bigint,
  p_error_code text
) returns jsonb
```

Один claim соответствует одной HTTP-попытке. Claim фиксируется до HTTP-вызова; результат записывается отдельным условным вызовом. `succeed_outbox` и `fail_outbox` возвращают JSON object: его внутренняя форма не является публичным wire-контрактом. Обязательны проверки owner, lease version и срока lease; `CONFIRMED` не откатывается в предыдущее состояние. Политику retry, `next_attempt_at` и `DEAD` определяет PostgreSQL; подробности — в [runbook](reliability.md#доставка-аренда-и-поздняя-квитанция).

### Reconciler

Reconciler не читает и не изменяет физические таблицы напрямую. Роль `inbox_reconciler` имеет `EXECUTE` только на:

```sql
delivery.reconcile_inbox(p_limit integer) returns integer
```

Один вызов атомарно применяет подходящие `RECEIVED` сообщения к pinned process, создаёт/дедуплицирует workflow signal и переводит Inbox в `APPLIED`. Неподходящее раннее сообщение остаётся `RECEIVED`. Вход соответствующего `wait_signal` также проверяет Inbox в своей транзакции.

В test profile poll interval не более 500 ms. Recreate reconciler не теряет работу: очередь определяется только состоянием PostgreSQL.

Роли dispatcher и reconciler не имеют прямого DML таблиц, прав миграции, доступа к `api.invoke` или workflow finish functions. Adapter не получает PostgreSQL credentials. Две реплики каждого обработчика используют ту же SQL-границу и ту же роль; dispatcher различаются `OUTBOX_OWNER`.
