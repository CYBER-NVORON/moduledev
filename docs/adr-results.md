# ADR: технический и предметный результат

[Документация](README.md) · [HTTP-примеры](local-requests.md)

## Статус

Принято.

## Контекст

Action runtime возвращает два типа результатов:

1. **Предметный результат** — action вернул `status=ok`, зарегистрированный outcome и корректный result. Отрицательное предметное решение может быть успешным outcome (например, `REJECTED`) и сохраняться с commit.
2. **Техническая ошибка** — отказ admission либо ошибка исполнения: auth, validation, timeout, DB unavailable. Ошибка может возникнуть и после начала SQL действия; его незавершённые изменения должны откатиться.

Необходимо определить единый формат HTTP-ответов для обоих случаев.

## Решение

### Единый JSON envelope

Успешный action использует envelope следующего вида (конкретный outcome определяется manifest):

```json
{
  "status": "ok",
  "outcome": "CREATED",
  "result": {},
  "meta": {
    "correlationId": "uuid",
    "actionVersion": 1
  }
}
```

Ошибка содержит `status=error`, `code`, `message` и при необходимости `retryable`, `details`, `meta`. `outcome` и `result` относятся к успешному subject result, а не к единому обязательному набору полей любого ответа.

### HTTP status codes

| Сценарий                          | HTTP | `status` | Кто определяет |
|-----------------------------------|------|----------|-----------------|
| Успешная операция                 | 200  | `ok`     | Runtime + DB    |
| Невалидный JWT                    | 401  | `error`  | Runtime (C#)    |
| Неверная переданная HMAC-подпись | 401 | `error` | Runtime (C#) |
| Отсутствующая подпись receipt | 403 | `error` | DB → Runtime |
| Нет required scope                | 403  | `error`  | Runtime (C#)    |
| Action не найден / disabled       | 404  | `error`  | Runtime (C#)    |
| Неизвестный identifier trace | 404 | `error` | DB → Runtime (`diagnostics.trace_not_found`) |
| Невалидный payload (schema)       | 422  | `error`  | Runtime (C#)    |
| Idempotency conflict              | 409  | `error`  | DB → Runtime    |
| Нарушение контракта ответа        | 500  | `error`  | Runtime (C#)    |
| БД недоступна                     | 503  | `error`  | Runtime (C#)    |
| Таймаут выполнения                | 504  | `error`  | Runtime (C#)    |

### Принцип разделения

- **4xx** — ошибка клиента до или вместо бизнес-логики (auth, validation, idempotency).
- **5xx** — инфраструктурная ошибка (contract violation, timeout, DB unavailable).
- **200** — бизнес-логика выполнена, outcome входит в зарегистрированный список, result прошёл response schema validation, транзакция закоммичена.

Envelope со `status=error` откатывает транзакцию и транслируется в HTTP 4xx/5xx. Для 5xx API скрывает target message и возвращает безопасный code вместо произвольного текста DB-ошибки. Успешный `receipt.accept` возвращает HTTP `200`; HTTP `202` относится к внешнему provider `/payments`.

### Rollback contract

Транзакция откатывается при:

- `status = 'error'` из PostgreSQL-функции;
- outcome не входит в `manifest.outcomes`;
- result не проходит response schema validation;
- любом исключении во время выполнения.

Commit происходит только когда все проверки пройдены.

## Последствия

- Клиент получает предсказуемый формат ответа независимо от причины ошибки.
- `correlationId` присутствует во всех ответах после аутентификации — упрощает трассировку.
- Бизнес-инварианты (outcome validation, schema validation) защищены транзакцией — частичный эффект невозможен.
