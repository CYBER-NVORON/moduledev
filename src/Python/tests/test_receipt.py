import hashlib
import hmac
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from receipt import classify_provider_response, map_callback_to_receipt, sign_receipt, validate_callback


class ReceiptContractTests(unittest.TestCase):
    def setUp(self):
        self.callback = dict(providerPaymentId='provider-123', operationId='external-123',
                             result='REJECTED', message='Private provider detail',
                             occurredAt='2026-09-04T12:00:00.123456789Z')

    def test_mapping_preserves_timestamp_and_signs_exact_compact_bytes(self):
        receipt = map_callback_to_receipt(validate_callback(json.dumps(self.callback).encode()))
        body, signature = sign_receipt(receipt, 'unit-test-only')
        expected = (b'{"externalRequestId":"external-123","messageId":"provider-123",'
                    b'"occurredAt":"2026-09-04T12:00:00.123456789Z","outcome":"REJECTED",'
                    b'"providerPaymentId":"provider-123","version":1}')
        self.assertEqual(body, expected)
        self.assertEqual(signature, 'v1=' + hmac.new(b'unit-test-only', expected, hashlib.sha256).hexdigest())
        self.assertNotIn(b'Private provider detail', body)

    def test_callback_rejects_unknown_fields_controls_invalid_dates_and_types(self):
        mutations = [dict(extra='field'), dict(operationId='id\r\nInjected: true'),
                     dict(message='bad\nmessage'), dict(providerPaymentId=123),
                     dict(occurredAt='2026-02-30T12:00:00Z'), dict(occurredAt='anythingZ'),
                     dict(occurredAt='2026-09-04T12:00:00+00:00'), dict(result='ACCEPTED')]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_callback(json.dumps(self.callback | mutation).encode())
        for body in (b'[]', b'null', b'{', b'\xff'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                validate_callback(body)

    def test_provider_response_classification_is_strict(self):
        self.assertEqual(classify_provider_response(202, b'{"providerPaymentId":"id","status":"ACCEPTED"}'),
                         ('success', 'id'))
        for body in (b'[]', b'null', b'\xff', b'{}', b'{"providerPaymentId":"","status":"ACCEPTED"}',
                     b'{"providerPaymentId":"id","status":"ACCEPTED","extra":1}'):
            with self.subTest(body=body):
                self.assertEqual(classify_provider_response(202, body), ('response.invalid.terminal', None))
        for status in (408, 429, 500, 503, 599):
            self.assertEqual(classify_provider_response(status, b''), (f'http.{status}.retryable', None))
        for status in (200, 201, 301, 400, 401, 404, 409):
            self.assertEqual(classify_provider_response(status, b''), (f'http.{status}.terminal', None))


if __name__ == '__main__':
    unittest.main()
