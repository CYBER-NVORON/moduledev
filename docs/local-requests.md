# Локальные JWT и HTTP-запросы

Это инструкция для ручной работы со стендом. Авточекеры сами создают synthetic secrets и токены, `.env` им не требуется. Исходный HTTP-контракт описан в документации, формы payload — в [contracts/course-1](../contracts/course-1).

## Настройка

Скопируйте `.env.example` в `.env`. Для ручного сценария нужны `COURSE_JWT_ISSUER`, `COURSE_JWT_AUDIENCE`, `COURSE_JWT_SIGNING_KEY`, `PROVIDER_HMAC_SECRET` и `PROVIDER_CALLBACK_CAPABILITY`. Development-строки шаблона не являются производственными секретами. Для генерации случайного значения можно использовать стандартную библиотеку Python:

```text
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Сгенерируйте независимые значения для JWT key, HMAC key и capability. JWT key должен содержать не менее 32 UTF-8 байт. В примере ниже значения `.env` записываются простыми строками `KEY=value` без кавычек, интерполяции и пробелов вокруг `=`.

`PROVIDER_CALLBACK_TOKEN` — настоящий HS256 JWT для исходящего запроса adapter → API. Он должен иметь строковые `sub`, `consumer`, `scope`, `iss`, `aud` и числовые `iat`, `exp`. Токен без `consumer`, времени жизни или корректной подписи будет отклонён.

Для выпуска локальных токенов сохраните этот пример во временный `make_token.py` вне репозитория. Запускайте его из корня проекта, чтобы он прочитал вашу `.env`. Скрипт не обращается в сеть и не изменяет файлы:

```python
import base64
import hashlib
import hmac
import json
from pathlib import Path
import sys
import time

settings = dict(
    line.split("=", 1)
    for line in Path(".env").read_text(encoding="utf-8-sig").splitlines()
    if line.strip() and not line.lstrip().startswith("#") and "=" in line
)
principal, consumer, scopes = sys.argv[1:4]
key = settings["COURSE_JWT_SIGNING_KEY"].strip().encode("utf-8")
if len(key) < 32:
    raise SystemExit("COURSE_JWT_SIGNING_KEY must contain at least 32 bytes")

def encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

def segment(value):
    return encode(json.dumps(value, separators=(",", ":")).encode("utf-8"))

now = int(time.time())
claims = dict(sub=principal, consumer=consumer, scope=scopes, iat=now,
              exp=now + 86400, iss=settings["COURSE_JWT_ISSUER"].strip(),
              aud=settings["COURSE_JWT_AUDIENCE"].strip())
unsigned = segment(dict(alg="HS256", typ="JWT")) + "." + segment(claims)
signature = hmac.new(key, unsigned.encode("ascii"), hashlib.sha256).digest()
print(unsigned + "." + encode(signature))
```

Подставьте путь временного файла вместо `<path>`:

```text
python <path>/make_token.py receipt-provider integration receipt:write
python <path>/make_token.py candidate-client web "payment:write payment:read workflow:read"
python <path>/make_token.py reviewer backoffice "workflow:manual payment:read"
```

Первый результат вставьте в `PROVIDER_CALLBACK_TOKEN` в `.env`. Два других используйте как `<CLIENT_JWT>` и `<REVIEWER_JWT>` в запросах. Не коммитьте эти значения. Токены действуют сутки; после замены callback token или других настроек выполните `docker compose up -d --build`, чтобы контейнеры получили новое окружение.

## Создание и запуск payment

Сохраните payload в локальный `request.json`:

```json
{"operationKind":"PAYMENT_EXECUTION","amount":"1000.00","currency":"RUB"}
```

Команды ниже используют `curl`; в Windows PowerShell замените его на `curl.exe`. Placeholders JWT и UUID нужно заменить реальными значениями.

```text
curl -X POST http://localhost:8080/api/payment/request -H "Authorization: Bearer <CLIENT_JWT>" -H "Content-Type: application/json" -H "Idempotency-Key: local-request-001" -H "X-Action-Version: 1" --data-binary "@request.json"
```

Возьмите `operationId` из `result` ответа и создайте `operation.json`:

```json
{"operationId":"<operation-id>"}
```

```text
curl -X POST http://localhost:8080/api/payment/submit -H "Authorization: Bearer <CLIENT_JWT>" -H "Content-Type: application/json" -H "Idempotency-Key: local-submit-001" -H "X-Action-Version: 1" --data-binary "@operation.json"
curl -X POST http://localhost:8080/api/operation/get -H "Authorization: Bearer <CLIENT_JWT>" -H "Content-Type: application/json" -H "X-Action-Version: 1" --data-binary "@operation.json"
```

Submit возвращает `processId`, закреплённые flow/version и результат команды со `status=PROCESSING`. Состояние процесса можно посмотреть командой `docker compose run --rm cli flow get <process-id>`. Финальный статус operation читайте через `operation.get`, а не повтором submit.

## Ручное решение

Создайте отдельную operation с `operationKind=PAYMENT_APPROVAL`, строковым `amount="100000.01"` и новым idempotency key, затем выполните submit. CLI `flow get` показывает компактное состояние без идентификаторов отдельных шагов. Для подробностей сохраните `{"processId":"<process-id>"}` в `process.json` и вызовите опубликованный action:

```text
curl -X POST http://localhost:8080/api/workflow/get -H "Authorization: Bearer <CLIENT_JWT>" -H "Content-Type: application/json" -H "X-Action-Version: 1" --data-binary "@process.json"
```

Когда process достигнет `WAITING_MANUAL`, найдите в `result.steps` шаг с `stepType=MANUAL`, `state=WAITING`, возьмите его `stepInstanceId` и создайте `decision.json`:

```json
{
  "processId": "<process-id>",
  "stepInstanceId": "<step-instance-id>",
  "decision": "APPROVED",
  "reason": "Документы проверены"
}
```

```text
curl -X POST http://localhost:8080/api/workflow/manual -H "Authorization: Bearer <REVIEWER_JWT>" -H "Content-Type: application/json" -H "Idempotency-Key: local-decision-001" -H "X-Action-Version: 1" --data-binary "@decision.json"
```

Для отказа используется `REJECTED`. Amount до `100000.00 RUB` включительно в `payment-review` проходит автоматическую ветку. Principal ручного решения берётся из JWT, его нельзя назначить полем payload.

Для новой команды используйте новый `Idempotency-Key`; для проверки replay отправьте прежние key и body. Изменённый body с прежним key вызывает conflict. Callback обычно отправляет provider; ручная отправка receipt дополнительно требует HMAC exact body bytes по внешнему контракту.
