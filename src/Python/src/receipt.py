import json
import hmac
import hashlib
import re
from datetime import datetime

def map_callback_to_receipt(callback: dict) -> dict:
    return {
        "version": 1,
        "messageId": callback["providerPaymentId"],
        "externalRequestId": callback["operationId"],
        "providerPaymentId": callback["providerPaymentId"],
        "outcome": callback["result"],
        "occurredAt": callback["occurredAt"]
    }

def sign_receipt(receipt: dict, secret: str) -> tuple[bytes, str]:
    body_bytes = json.dumps(receipt, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode('utf-8')
    mac = hmac.new(secret.encode('utf-8'), body_bytes, hashlib.sha256)
    signature = f'v1={mac.hexdigest()}'
    return body_bytes, signature

def validate_callback(body: bytes) -> dict:
    try:
        data = json.loads(body.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ValueError("Invalid UTF-8 JSON") from e
    
    if not isinstance(data, dict):
        raise ValueError("Root element must be a JSON object")

    required_keys = {"providerPaymentId", "operationId", "result", "message", "occurredAt"}
    actual_keys = set(data.keys())
    
    if actual_keys != required_keys:
        raise ValueError(f"Invalid keys, expected exact match of {required_keys}")

    provider_id = data["providerPaymentId"]
    if not isinstance(provider_id, str) or not (1 <= len(provider_id) <= 128) or '\n' in provider_id or '\r' in provider_id:
        raise ValueError("Invalid providerPaymentId")

    op_id = data["operationId"]
    if not isinstance(op_id, str) or not (1 <= len(op_id) <= 128) or '\n' in op_id or '\r' in op_id:
        raise ValueError("Invalid operationId")

    result = data["result"]
    if result not in ("COMPLETED", "REJECTED"):
        raise ValueError("Invalid result")

    message = data["message"]
    if not isinstance(message, str) or not (0 <= len(message) <= 500) or '\n' in message or '\r' in message:
        raise ValueError("Invalid message")

    occurred_at = data["occurredAt"]
    if not isinstance(occurred_at, str) or len(occurred_at) > 64 or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', occurred_at):
        raise ValueError("Invalid occurredAt")
    datetime.fromisoformat(occurred_at)

    return data

def classify_provider_response(status: int, body: bytes) -> tuple[str, str | None]:
    if status == 202:
        try:
            data = json.loads(body.decode('utf-8'))
            payment_id = data['providerPaymentId']
            if (set(data) == {'providerPaymentId', 'status'} and data['status'] == 'ACCEPTED'
                    and isinstance(payment_id, str) and 1 <= len(payment_id) <= 128
                    and '\r' not in payment_id and '\n' not in payment_id):
                return 'success', payment_id
        except (ValueError, KeyError, TypeError):
            pass
        return 'response.invalid.terminal', None
    retryable = status in (408, 429) or 500 <= status <= 599
    return f"http.{status}.{'retryable' if retryable else 'terminal'}", None
