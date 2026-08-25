# ADR: Unified Response Envelope — технический и предметный результат

## Статус

Принято.

## Контекст

Action runtime возвращает два типа результатов:

1. **Предметный результат** — бизнес-операция выполнена (успешно или с бизнес-ошибкой). Транзакция закоммичена или откачена в зависимости от outcome.
2. **Инфраструктурная ошибка** — запрос не дошёл до бизнес-логики (auth, validation, timeout, DB unavailable).

Необходимо определить единый формат HTTP-ответов для обоих случаев.

## Решение

### Единый JSON envelope

Все ответы action runtime используют один формат:

```json
{
  "status": "ok | error",
  "outcome": "created | found | ...",
  "code": "error.code",
  "message": "human-readable message",
  "result": { ... },
  "retryable": false,
  "details": { },
  "meta": {
    "correlationId": "uuid",
    "actionVersion": 1
  }
}
```

### HTTP status codes

| Сценарий                          | HTTP | `status` | Кто определяет |
|-----------------------------------|------|----------|-----------------|
| Успешная операция                 | 200  | `ok`     | Runtime + DB    |
| Невалидный JWT                    | 401  | `error`  | Runtime (C#)    |
| Нет required scope                | 403  | `error`  | Runtime (C#)    |
| Action не найден / disabled       | 404  | `error`  | Runtime (C#)    |
| Невалидный payload (schema)       | 422  | `error`  | Runtime (C#)    |
| Idempotency conflict              | 409  | `error`  | DB → Runtime    |
| Нарушение контракта ответа        | 500  | `error`  | Runtime (C#)    |
| БД недоступна                     | 503  | `error`  | Runtime (C#)    |
| Таймаут выполнения                | 504  | `error`  | Runtime (C#)    |

### Принцип разделения

- **4xx** — ошибка клиента до или вместо бизнес-логики (auth, validation, idempotency).
- **5xx** — инфраструктурная ошибка (contract violation, timeout, DB unavailable).
- **200** — бизнес-логика выполнена, outcome входит в зарегистрированный список, result прошёл response schema validation, транзакция закоммичена.

Бизнес-ошибки, возвращённые PostgreSQL-функцией со `status = 'error'`, транслируются в HTTP 4xx/5xx с `code` из БД. Транзакция при этом откатывается.

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
