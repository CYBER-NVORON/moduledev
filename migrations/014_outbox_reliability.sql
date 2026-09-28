-- Delivery policy lives in PostgreSQL; HTTP stays outside the claim transaction.
SET ROLE course_owner;
ALTER TABLE delivery.outbox ADD COLUMN lease_until timestamptz, ADD COLUMN dead_at timestamptz;
UPDATE delivery.outbox SET lease_until=next_attempt_at WHERE state='LEASED';
UPDATE delivery.outbox SET dead_at=now() WHERE state='DEAD';

CREATE FUNCTION delivery.setting(p_name text, p_default integer) RETURNS integer
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
    SELECT COALESCE(NULLIF(current_setting('course.' || p_name,true),'')::integer,p_default)
$$;

CREATE OR REPLACE FUNCTION delivery.claim_outbox(p_owner text, p_limit integer)
RETURNS TABLE(outbox_id uuid, lease_version bigint, external_request_id text, correlation_id uuid, amount text, currency text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_max integer := greatest(1,delivery.setting('outbox_max_attempts',4));
BEGIN
    IF NULLIF(p_owner,'') IS NULL OR p_limit < 1 OR p_limit > 100 THEN
        RAISE EXCEPTION 'delivery.claim_invalid';
    END IF;
    -- A crash on the final attempt still consumes the finite delivery budget.
    WITH expired AS (
        SELECT o.outbox_id FROM delivery.outbox o
        WHERE o.state='LEASED' AND o.lease_until <= now() AND o.attempt_count >= v_max
        FOR UPDATE SKIP LOCKED LIMIT p_limit
    )
    UPDATE delivery.outbox o SET state='DEAD',dead_at=now(),
        last_error_code=COALESCE(o.last_error_code,'delivery.lease_expired')
    FROM expired e WHERE o.outbox_id=e.outbox_id;

    RETURN QUERY WITH claimed AS (
        SELECT o.outbox_id FROM delivery.outbox o
        WHERE ((o.state IN ('PENDING','RETRY_WAIT') AND o.next_attempt_at <= now())
            OR (o.state='LEASED' AND o.lease_until <= now())) AND o.attempt_count < v_max
        ORDER BY o.created_at,o.outbox_id FOR UPDATE SKIP LOCKED LIMIT p_limit
    )
    UPDATE delivery.outbox o SET state='LEASED',lease_owner=p_owner,lease_version=o.lease_version+1,
        lease_until=now()+make_interval(secs=>greatest(1,delivery.setting('outbox_lease_ms',2000))/1000.0),
        attempt_count=o.attempt_count+1
    FROM claimed c,delivery.external_requests e,payment.operations op
    WHERE o.outbox_id=c.outbox_id AND e.external_request_id=o.external_request_id AND op.operation_id=e.operation_id
    RETURNING o.outbox_id,o.lease_version,o.external_request_id,e.correlation_id,op.amount::text,op.currency;
END;
$$;

CREATE OR REPLACE FUNCTION delivery.fail_outbox(p_outbox_id uuid,p_owner text,p_lease_version bigint,p_error_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_row delivery.outbox%ROWTYPE; v_retry boolean; v_delay double precision;
BEGIN
    SELECT * INTO v_row FROM delivery.outbox WHERE outbox_id=p_outbox_id
        AND lease_owner=p_owner AND lease_version=p_lease_version AND state='LEASED' AND lease_until>now()
        FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('updated',false); END IF;
    IF p_error_code IS NULL OR length(p_error_code)>128 OR p_error_code !~ '^[a-z][a-z0-9_.]*$' THEN
        p_error_code := 'delivery.invalid_error';
    END IF;
    v_retry := p_error_code LIKE '%.retryable' AND v_row.attempt_count < greatest(1,delivery.setting('outbox_max_attempts',4));
    v_delay := least(greatest(0,delivery.setting('outbox_backoff_max_ms',800)),
        greatest(0,delivery.setting('outbox_backoff_base_ms',200))*power(2.0,least(v_row.attempt_count-1,30)))
        + floor(random()*(greatest(0,delivery.setting('outbox_jitter_max_ms',100))+1));
    UPDATE delivery.outbox SET state=CASE WHEN v_retry THEN 'RETRY_WAIT' ELSE 'DEAD' END,
        last_error_code=p_error_code, next_attempt_at=CASE WHEN v_retry THEN now()+make_interval(secs=>v_delay/1000.0) ELSE next_attempt_at END,
        dead_at=CASE WHEN v_retry THEN dead_at ELSE now() END,lease_until=NULL
    WHERE outbox_id=p_outbox_id RETURNING * INTO v_row;
    RETURN jsonb_build_object('updated',true,'state',v_row.state,'attemptCount',v_row.attempt_count,
        'nextAttemptAt',v_row.next_attempt_at,'errorCode',v_row.last_error_code);
END;
$$;

CREATE OR REPLACE FUNCTION delivery.succeed_outbox(p_outbox_id uuid,p_owner text,p_lease_version bigint,p_provider_payment_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_external text; v_row delivery.outbox%ROWTYPE;
BEGIN
    -- Same lock order as receipt.accept, including early/late receipts.
    SELECT e.external_request_id INTO v_external FROM delivery.external_requests e
        JOIN delivery.outbox o USING(external_request_id) WHERE o.outbox_id=p_outbox_id FOR UPDATE OF e;
    UPDATE delivery.outbox SET state='DELIVERED',delivered_at=now(),lease_until=NULL
    WHERE outbox_id=p_outbox_id AND lease_owner=p_owner AND lease_version=p_lease_version
        AND state='LEASED' AND lease_until>now() RETURNING * INTO v_row;
    IF NOT FOUND THEN RETURN jsonb_build_object('updated',false); END IF;
    UPDATE delivery.external_requests SET state='SENT' WHERE external_request_id=v_external AND state='CREATED';
    RETURN jsonb_build_object('updated',true,'state',v_row.state,'attemptCount',v_row.attempt_count);
END;
$$;

CREATE OR REPLACE VIEW autocheck.outbox AS
SELECT outbox_id,external_request_id,state,attempt_count,next_attempt_at,last_error_code,created_at,delivered_at,
       lease_owner,lease_version,lease_until,dead_at FROM delivery.outbox;
REVOKE ALL ON FUNCTION delivery.setting(text,integer) FROM PUBLIC;
RESET ROLE;
