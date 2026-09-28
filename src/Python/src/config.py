import os

DATABASE_URL = os.environ.get("DATABASE_URL")
PROVIDER_URL = os.environ.get("PROVIDER_URL")
OUTBOX_OWNER = os.environ.get("OUTBOX_OWNER", "outbox-dispatcher")
PROVIDER_CALLBACK_CAPABILITY = os.environ.get("PROVIDER_CALLBACK_CAPABILITY")
PROVIDER_CALLBACK_TOKEN = os.environ.get("PROVIDER_CALLBACK_TOKEN")
PROVIDER_HMAC_SECRET = os.environ.get("PROVIDER_HMAC_SECRET")
RECEIPT_API_URL = os.environ.get("RECEIPT_API_URL", "http://gateway:8080/api/receipt/accept")
COURSE_TEST_PROFILE = os.environ.get("COURSE_TEST_PROFILE")

if COURSE_TEST_PROFILE == '1':
    POLL_INTERVAL = 0.1
    PROVIDER_TIMEOUT = 0.5
    INBOX_RECONCILIATION_POLL = 0.5
else:
    POLL_INTERVAL = 1.0
    PROVIDER_TIMEOUT = 5.0
    INBOX_RECONCILIATION_POLL = 2.0

# Millisecond configuration contract, with existing profile defaults as fallback.
POLL_INTERVAL = max(1, int(os.environ.get("COURSE_OUTBOX_POLL_MS", POLL_INTERVAL * 1000))) / 1000
PROVIDER_TIMEOUT = max(1, int(os.environ.get("COURSE_PROVIDER_TIMEOUT_MS", PROVIDER_TIMEOUT * 1000))) / 1000
INBOX_RECONCILIATION_POLL = max(1, int(os.environ.get("COURSE_INBOX_POLL_MS", INBOX_RECONCILIATION_POLL * 1000))) / 1000

