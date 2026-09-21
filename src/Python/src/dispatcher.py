import json
import os
import sys
import time
import uuid
import logging
import psycopg2
import httpx

import config
from receipt import classify_provider_response

def setup_logging():
    logger = logging.getLogger("dispatcher")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter('%(message)s'))
    logger.addHandler(handler)
    logger.propagate = False
    return logger

logger = setup_logging()

def handle_failpoint(point_name: str, instance_id: str):
    failpoint = os.environ.get("COURSE_FAILPOINT")
    if failpoint == point_name:
        logger.info(json.dumps({
            "event": "failpoint.reached",
            "name": point_name,
            "instanceId": instance_id
        }))
        while True:
            time.sleep(999999)

def main():
    instance_id = str(uuid.uuid4())
    logger.info(json.dumps({"event": "dispatcher.started", "instanceId": instance_id}))

    conn = None
    while conn is None:
        try:
            conn = psycopg2.connect(config.DATABASE_URL)
            conn.autocommit = True
        except psycopg2.Error:
            time.sleep(1)
    
    while True:
        try:
            # 1. Claim pending outbox records from PostgreSQL (Skip Locked)
            with conn.cursor() as cur:
                cur.execute("SELECT outbox_id, lease_version, external_request_id, correlation_id, amount, currency FROM delivery.claim_outbox(%s, %s)", (config.OUTBOX_OWNER, 1))
                rows = cur.fetchall()
                
            if not rows:
                time.sleep(config.POLL_INTERVAL)
                continue
                
            handle_failpoint("after_outbox_claim", instance_id)
            
            # 2. Dispatch claimed records to the external provider
            for row in rows:
                outbox_id, lease_version, external_request_id, correlation_id, amount, currency = row
                
                headers = {
                    "Content-Type": "application/json",
                    "Idempotency-Key": external_request_id,
                    "X-Correlation-ID": str(correlation_id)
                }
                
                payload = {
                    "operationId": external_request_id,
                    "amount": str(amount),
                    "currency": currency
                }
                
                status_to_report = None
                provider_payment_id = None
                
                try:
                    with httpx.Client(timeout=config.PROVIDER_TIMEOUT) as client:
                        response = client.post(f"{config.PROVIDER_URL}/payments", content=json.dumps(payload, separators=(',', ':')).encode('utf-8'), headers=headers)
                        
                        handle_failpoint("after_provider_response", instance_id)
                        
                        status_to_report, provider_payment_id = classify_provider_response(
                            response.status_code, response.content)
                except httpx.RequestError:
                    handle_failpoint("after_provider_response", instance_id)
                    status_to_report = "transport.error.retryable"
                    
                # 3. Classify response and record decision back in PostgreSQL
                with conn.cursor() as cur:
                    if status_to_report == "success":
                        cur.execute("SELECT delivery.succeed_outbox(%s, %s, %s, %s)", 
                                    (outbox_id, config.OUTBOX_OWNER, lease_version, provider_payment_id))
                    else:
                        cur.execute("SELECT delivery.fail_outbox(%s, %s, %s, %s)", 
                                    (outbox_id, config.OUTBOX_OWNER, lease_version, status_to_report))
                        
        except psycopg2.Error as e:
            logger.error(json.dumps({"event": "db.error", "errorType": type(e).__name__}))
            time.sleep(config.POLL_INTERVAL)
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
            logger.error(json.dumps({"event": "dispatcher.error", "errorType": type(e).__name__}))
            time.sleep(config.POLL_INTERVAL)

if __name__ == '__main__':
    main()
