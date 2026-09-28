import time
import psycopg2
import config
from observability import log, start_probes


def main():
    start_probes()
    log("reconciler.started")
    conn = None
    while True:
        try:
            if conn is None:
                conn = psycopg2.connect(config.DATABASE_URL, connect_timeout=2)
                conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("SELECT delivery.reconcile_inbox(%s)", (10,))
                applied = cur.fetchone()[0]
            if applied:
                log("inbox.applied", appliedCount=applied)
            else:
                time.sleep(config.INBOX_RECONCILIATION_POLL)
        except psycopg2.Error:
            log("reconciler.database_error", "ERROR", errorCode="dependency.unavailable")
            if conn is not None:
                conn.close()
                conn = None
            time.sleep(config.INBOX_RECONCILIATION_POLL)
        except Exception:
            log("reconciler.error", "ERROR", errorCode="internal.error")
            time.sleep(config.INBOX_RECONCILIATION_POLL)


if __name__ == "__main__":
    main()
