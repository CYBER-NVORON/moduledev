# Платёжные процессы

[Документация](README.md) · [Внешние контракты](external-contracts.md) · [Примеры запросов](local-requests.md)

PostgreSQL выбирает процесс по виду операции и хранит его состояние. Общие C# API и worker исполняют зарегистрированные actions и карты без предметных веток в ядре. Python отвечает за внешний транспорт и вызовы фиксированных SQL-функций.

`payment-processing` завершается по сохранённой валидной квитанции, `payment-review` — по серверному правилу или аудированному ручному решению. Повторы не создают второй процесс, платёж, переход или решение.

## `payment.submit`

Payload version 1:

```json
{
  "operationId": "8c26513d-8441-43ea-b064-3bca8c240052"
}
```

Action требует `payment:write` и `Idempotency-Key`, не принимает flow name/version, operation kind, amount, limit или final status.

Одна транзакция:

```text
operation CREATED -> PROCESSING
+ process instance pinned to active flow version
+ first step/job or waiting state
+ OPERATION_SUBMITTED event
+ idempotency result
```

Серверная таблица binding сопоставляет:

| `operationKind` | Flow |
|---|---|
| `PAYMENT_EXECUTION` | `payment-processing` |
| `PAYMENT_APPROVAL` | `payment-review` |

Идентичный repeat возвращает исходный subject result команды со `status=PROCESSING` и существующий pinned process, в том числе после завершения operation или смены default flow version. Актуальный operation status читается отдельно. Changed body с тем же key даёт conflict. Нельзя получить operation `PROCESSING` без process или process для operation `CREATED`.

## Процесс `payment-processing`, версия 1

```text
validate_operation
  -> prepare_external_request
  -> wait_receipt
  -> apply_receipt
  -> [COMPLETED] complete_operation
  -> [REJECTED] reject_operation
  -> end
```

Automatic steps вызывают через общий runtime:

- `payment.validate`;
- `payment.prepare_external`;
- `payment.apply_receipt`;
- `payment.complete`;
- `payment.reject`.

`payment.prepare_external` одной transaction создаёт `external_request`, Outbox и завершает workflow job. Все retries job используют один `executionId`, поэтому создаётся один external request.

`payment.apply_receipt` читает только сохранённый receipt. Клиентский body и provider transport response не могут напрямую установить final status.

## Процесс `payment-review`, версия 1

```text
validate_operation
  -> check_limit
  -> [WITHIN_LIMIT] approve_operation
  -> [REVIEW_REQUIRED] wait_manual_decision
  -> [APPROVED] approve_operation
  -> [REJECTED] reject_operation
  -> end
```

Automatic steps вызывают `payment.validate`, `payment.check_limit`, `payment.approve` и `payment.reject`.

Серверное правило `course-limit-v1` задаёт порог: сумма до `100000.00 RUB` включительно даёт `WITHIN_LIMIT`, сумма выше даёт `REVIEW_REQUIRED`. Клиент не передаёт limit или rule version.

Автоматическое решение сохраняется с `source=LIMIT_RULE` и `rule_version=course-limit-v1`.

## Ручное решение

Action `workflow.manual` version 1 требует `workflow:manual` и `Idempotency-Key`. Payload:

```json
{
  "processId": "21a34f72-83cd-4e68-9cf2-a07ab20034fa",
  "stepInstanceId": "bdab3a76-3473-4c79-a7c5-6ff743658eda",
  "decision": "APPROVED",
  "reason": "Документы проверены"
}
```

`decision` равен `APPROVED` или `REJECTED`; `reason` содержит 1-500 символов и не является idempotency key.

- Решение допустимо только для текущего `manual` step pinned process.
- Principal берётся из trusted context, а не payload.
- Decision, workflow event и следующий job фиксируются одной transaction.
- Identical repeat возвращает те же `status`, `outcome` и `result`; transport headers и `meta` могут отличаться.
- Changed или concurrent decision возвращает conflict.
- Decision view хранит source `MANUAL`, principal, reason hash, outcome и время.

## Обязательные actions

Миграции регистрируют PostgreSQL actions:

- `payment.submit`;
- `operation.events`;
- `payment.validate`;
- `payment.prepare_external`;
- `payment.apply_receipt`;
- `payment.complete`;
- `payment.reject`;
- `payment.check_limit`;
- `payment.approve`;
- `receipt.accept`;
- `workflow.manual`.

Все automatic actions имеют явную version и вызываются worker через shared executor. `receipt.accept` и `workflow.manual` публикуются тем же generic HTTP route, а не отдельными controllers.
