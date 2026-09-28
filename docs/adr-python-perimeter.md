# ADR: Python-периметр и границы доставки

[Документация](README.md) · [Восстановление доставки](reliability.md#доставка-аренда-и-поздняя-квитанция)

**Статус:** Принято  
**Контекст:** Интеграция с внешними системами и восстановление после сбоев (недели 3–4)

## Контекст и Проблематика

При интеграции с внешним платежным провайдером (Provider v0.2.0) возникает необходимость надежно отправлять запросы и принимать асинхронные ответы (веб-хуки/callbacks). 
Провайдер работает по протоколу HTTP с JSON, однако основная бизнес-логика (стейт-машины, проверки лимитов, маршрутизация) строго инкапсулирована внутри базы данных (PL/pgSQL).

HTTP-транспорт и нормализация legacy callback вынесены в Python. Бизнес-решения и состояние остаются в PostgreSQL, чтобы их изменения фиксировались общей транзакцией.

## Принятое решение

Периметр на Python 3.12 состоит из трёх компонентов, которые общаются с ядром через **Transactional Outbox / Inbox**. В неделе 4 dispatcher и reconciler работают в двух репликах: всего пять Python-контейнеров из одного image.

### 1. Единая кодовая база, разделенные роли

Все три Python-компонента собираются из одного и того же образа (image) Docker, но запускаются с разными точками входа (entrypoints):

* **Dispatcher** (outbox-dispatcher): Опрашивает таблицу outbox и совершает исходящие HTTP POST запросы к провайдеру.
* **Adapter** (receipt-adapter): Обрабатывает входящие веб-хуки от провайдера, валидирует их и перенаправляет во внутренний C# API.
* **Reconciler** (inbox-reconciler): Опрашивает таблицу inbox (куда API складывает валидированные ответы) и применяет их к бизнес-логике.

### 2. Строгое ограничение доступа к БД (Least Privilege)

* **Adapter** вообще не имеет доступа к PostgreSQL. Его задача — исключительно преобразование HTTP-запросов (wire format).
* **Dispatcher** имеет права EXECUTE только на 3 функции: `claim_outbox`, `succeed_outbox`, `fail_outbox`.
* **Reconciler** имеет права EXECUTE только на одну функцию: `reconcile_inbox`.
Любые решения (одобрить платеж, отклонить, перевести в ручной режим) принимает исключительно PostgreSQL. Python-слой занимается только транспортом.

### 3. Механизм доверия (HMAC и Capability)

Поскольку провайдер (v0.2.0) присылает callback без надежной криптографической подписи (legacy callback), мы формируем границу доверия (Trust Boundary) на уровне Adapter'а:

1. Adapter принимает callback только по пути `/callbacks/provider-v02/{PROVIDER_CALLBACK_CAPABILITY}`. Сам provider не присылает HMAC. Неверный path/capability даёт `404`.
2. Adapter проверяет legacy schema и преобразует callback в receipt v1. Затем сериализует receipt как compact sorted UTF-8 JSON и подписывает через **HMAC-SHA256**.
3. Подписанные байты и заголовок X-Provider-Signature уходят в Gateway, а затем в API.
4. Для исходящего вызова adapter использует `PROVIDER_CALLBACK_TOKEN` — JWT principal `receipt-provider` со scope `receipt:write`. C# API проверяет JWT и HMAC сырых байтов с `PROVIDER_HMAC_SECRET`. HMAC подтверждает целостность и владение ключом; он не шифрует сообщение и не заменяет TLS вне локального стенда.

### 4. Идемпотентность и надежность (Inbox/Outbox)

* **Outbox**: Допускает повторную отправку после потери ответа или падения dispatcher, пока не исчерпан бюджет попыток. Провайдер дедуплицирует запросы по Idempotency-Key (externalRequestId). Конечный retry budget не гарантирует доставку при бессрочной недоступности provider: delivery станет DEAD, операция продолжит ждать квитанцию.
* **Inbox**: `receipt.accept` фиксирует сообщение до успешного HTTP `200`. Provider HTTP `202` относится к отдельному запросу `POST /payments`. Идентичный повтор безопасен, изменённый body с тем же key/messageId даёт conflict.
* Reconciliation применяет сохранённый receipt и создаёт durable workflow signal для `wait_signal`, включая сообщение, пришедшее раньше готовности шага. Adapter возвращает статус и body ответа API.

## Последствия и ограничения

* **Безопасность логов**: Из логов исключены тексты SQL-ошибок (exception text), чувствительные токены и полные причины отказов провайдера. Публичные view содержат только безопасные хеши и идентификаторы.
* **Доставка**: повторные HTTP attempts возможны; один provider payment обеспечивается стабильным `externalRequestId` и дедупликацией provider. Dispatcher ограничивает весь асинхронный HTTP-запрос deadline, включая DNS; это не гарантия exactly-once.
* **Тестовые остановки**: dispatcher поддерживает `after_outbox_claim` и `after_provider_response`; Compose передаёт `COURSE_FAILPOINT`. Остановка включается только при `COURSE_TEST_PROFILE=1`. Reconciler не имеет контрактных failpoints. Границы commit и восстановление описаны в [runbook](reliability.md).
* **Зависимости**: SQL-вызовы выполняются через `psycopg2-binary`, HTTP-клиент — `httpx`, callback server — стандартный `http.server`. Проверка callback реализована в общем модуле `receipt.py`.
