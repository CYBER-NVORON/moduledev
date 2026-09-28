import asyncio
import json
import time
import psycopg2
import httpx
import config
from receipt import classify_provider_response
from observability import log, failpoint, start_probes


async def main():
    start_probes()
    log("dispatcher.started", instanceId=config.OUTBOX_OWNER)
    conn = None
    while True:
        try:
            if conn is None:
                conn = psycopg2.connect(config.DATABASE_URL, connect_timeout=2)
                conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("SELECT outbox_id, lease_version, external_request_id, correlation_id, amount, currency FROM delivery.claim_outbox(%s,%s)", (config.OUTBOX_OWNER, 1))
                rows = cur.fetchall()
            # Autocommit has released the claim locks before any external HTTP request.
            if not rows:
                await asyncio.sleep(config.POLL_INTERVAL)
                continue
            for outbox_id, lease_version, external_id, correlation_id, amount, currency in rows:
                fields = dict(outboxId=outbox_id, externalRequestId=external_id,
                              correlationId=correlation_id, leaseVersion=lease_version, instanceId=config.OUTBOX_OWNER)
                log("outbox.claimed", "INFO", **fields)
                failpoint("after_outbox_claim", config.OUTBOX_OWNER)
                started = time.monotonic()
                http_status = None
                provider_id = None
                try:
                    log("provider.request.sent", "INFO", **fields)
                    async with httpx.AsyncClient(timeout=config.PROVIDER_TIMEOUT) as client:
                        # The async deadline includes DNS; a synchronous resolver can outlive the lease.
                        response = await asyncio.wait_for(client.post(config.PROVIDER_URL + "/payments",
                            content=json.dumps({"operationId": external_id, "amount": str(amount), "currency": currency}, separators=(",", ":")).encode(),
                            headers={"Content-Type": "application/json", "Idempotency-Key": external_id,
                                     "X-Correlation-ID": str(correlation_id)}), timeout=config.PROVIDER_TIMEOUT)
                    http_status = response.status_code
                    log("provider.response.received", "INFO" if http_status < 400 else "WARNING",
                        **fields, httpStatus=http_status, durationMs=int((time.monotonic()-started)*1000))
                    outcome, provider_id = classify_provider_response(http_status, response.content)
                    if outcome != "success":
                        log("provider.request.failed", "WARNING", **fields, httpStatus=http_status,
                            errorCode=outcome, durationMs=int((time.monotonic()-started)*1000))
                except (httpx.RequestError, asyncio.TimeoutError):
                    outcome = "transport.error.retryable"
                    log("provider.request.failed", "WARNING", **fields, httpStatus=http_status,
                        errorCode=outcome, durationMs=int((time.monotonic()-started)*1000))
                failpoint("after_provider_response", config.OUTBOX_OWNER)
                # SQL checks owner/version/expiry and preserves a receipt already marked CONFIRMED.
                with conn.cursor() as cur:
                    if outcome == "success":
                        cur.execute("SELECT delivery.succeed_outbox(%s,%s,%s,%s)",
                                    (outbox_id, config.OUTBOX_OWNER, lease_version, provider_id))
                    else:
                        cur.execute("SELECT delivery.fail_outbox(%s,%s,%s,%s)",
                                    (outbox_id, config.OUTBOX_OWNER, lease_version, outcome))
                    result = cur.fetchone()[0]
                if not result["updated"]:
                    log("outbox.stale", "WARNING", **fields, **result,
                        httpStatus=http_status, durationMs=int((time.monotonic()-started)*1000))
                elif result.get("state") == "DEAD":
                    log("outbox.dead", "ERROR", **fields, **result,
                        httpStatus=http_status, durationMs=int((time.monotonic()-started)*1000))
                elif result.get("state") == "DELIVERED":
                    log("outbox.delivered", "INFO", **fields, **result,
                        httpStatus=http_status, durationMs=int((time.monotonic()-started)*1000))
                elif result.get("state") == "RETRY_WAIT":
                    log("outbox.retry.scheduled", "WARNING", **fields, **result,
                        httpStatus=http_status, durationMs=int((time.monotonic()-started)*1000))
        except psycopg2.Error:
            log("dispatcher.database_error", "ERROR", errorCode="dependency.unavailable")
            if conn is not None:
                conn.close()
                conn = None
            await asyncio.sleep(config.POLL_INTERVAL)
        except Exception:
            log("dispatcher.error", "ERROR", errorCode="internal.error")
            await asyncio.sleep(config.POLL_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
