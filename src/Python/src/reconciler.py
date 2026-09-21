import time
import psycopg2
import logging
import sys
import json
import config

def setup_logging():
    logger = logging.getLogger("reconciler")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter('%(message)s'))
    logger.addHandler(handler)
    logger.propagate = False
    return logger

logger = setup_logging()

def main():
    logger.info(json.dumps({"event": "reconciler.started"}))
    
    conn = None
    while conn is None:
        try:
            conn = psycopg2.connect(config.DATABASE_URL)
            conn.autocommit = True
        except psycopg2.Error:
            time.sleep(1)
    
    while True:
        try:
            # 1. Periodically flush processed inbox messages to workflow signals
            with conn.cursor() as cur:
                cur.execute("SELECT delivery.reconcile_inbox(%s)", (10,))
                applied = cur.fetchone()[0]
                
            # 2. Backoff if queue is empty, otherwise immediately poll again
            if applied == 0:
                time.sleep(config.INBOX_RECONCILIATION_POLL)
        except psycopg2.Error as e:
            logger.error(json.dumps({"event": "db.error", "errorType": type(e).__name__}))
            time.sleep(config.INBOX_RECONCILIATION_POLL)
            try:
                conn.close()
            except:
                pass
            try:
                conn = psycopg2.connect(config.DATABASE_URL)
                conn.autocommit = True
            except:
                pass
        except Exception as e:
            logger.error(json.dumps({"event": "reconciler.error", "errorType": type(e).__name__}))
            time.sleep(config.INBOX_RECONCILIATION_POLL)

if __name__ == '__main__':
    main()
