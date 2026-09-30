-- Enforce wall-clock lease deadlines and age stalled deliveries without rewriting applied migrations.
SET ROLE course_owner;


CREATE OR REPLACE FUNCTION workflow.finish_job(
    p_job_id uuid,
    p_owner text,
    p_lease_version bigint,
    p_outcome text,
    p_result jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_job record;
    v_step record;
    v_proc record;
    v_map_json jsonb;
    v_trans jsonb;
    v_next_step_key text;
BEGIN
    -- Check the deadline after acquiring the lock; transaction-start time is not sufficient.
    SELECT j.job_id, j.process_id, j.step_instance_id, j.execution_id,
           j.state, j.lease_owner, j.lease_version, j.lease_until
    INTO v_job
    FROM workflow.jobs j
    WHERE j.job_id = p_job_id
    FOR UPDATE;

    IF v_job.job_id IS NULL OR p_owner IS NULL OR p_lease_version IS NULL
       OR v_job.state IS DISTINCT FROM 'LEASED'
       OR v_job.lease_owner IS DISTINCT FROM p_owner
       OR v_job.lease_version IS DISTINCT FROM p_lease_version
       OR (v_job.lease_until > clock_timestamp()) IS NOT TRUE THEN
        RAISE EXCEPTION 'workflow.lease_stale';
    END IF;

    -- Load step & process
    SELECT step_instance_id, process_id, step_key, step_type
    INTO v_step
    FROM workflow.step_instances
    WHERE step_instance_id = v_job.step_instance_id;

    SELECT p.process_id, p.flow_name, p.flow_version, p.data_json
    INTO v_proc
    FROM workflow.process_instances p
    WHERE p.process_id = v_job.process_id;

    SELECT map_json INTO v_map_json
    FROM workflow.flow_versions
    WHERE flow_name = v_proc.flow_name AND flow_version = v_proc.flow_version;

    -- Check transition exists for outcome
    SELECT elem INTO v_trans
    FROM jsonb_array_elements(v_map_json->'transitions') elem
    WHERE elem->>'from' = v_step.step_key AND elem->>'outcome' = p_outcome;

    IF v_trans IS NULL THEN
        RAISE EXCEPTION 'workflow.unknown_outcome: outcome % not transitioned from step %', p_outcome, v_step.step_key;
    END IF;

    v_next_step_key := v_trans->>'to';

    -- Update job state to SUCCEEDED
    UPDATE workflow.jobs
    SET state = 'SUCCEEDED'
    WHERE job_id = p_job_id;

    -- Update running attempt to SUCCEEDED
    UPDATE workflow.attempts
    SET status = 'SUCCEEDED',
        outcome = p_outcome,
        finished_at = clock_timestamp()
    WHERE job_id = p_job_id
      AND lease_version = p_lease_version
      AND status = 'RUNNING';

    -- Update step to COMPLETED
    UPDATE workflow.step_instances
    SET state = 'COMPLETED',
        outcome = p_outcome,
        completed_at = clock_timestamp()
    WHERE step_instance_id = v_step.step_instance_id;

    -- Record TaskCompleted & StepCompleted events
    INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
    VALUES (v_proc.process_id, v_step.step_instance_id, 'TaskCompleted', jsonb_build_object(
        'jobId', p_job_id, 'outcome', p_outcome, 'result', p_result
    ));

    INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
    VALUES (v_proc.process_id, v_step.step_instance_id, 'StepCompleted', jsonb_build_object(
        'stepKey', v_step.step_key, 'outcome', p_outcome
    ));

    -- Advance to next step
    PERFORM workflow.enter_step(v_proc.process_id, v_map_json, v_next_step_key);

    RETURN jsonb_build_object(
        'status', 'ok',
        'jobId', p_job_id,
        'nextStep', v_next_step_key
    );
END;
$$;

CREATE OR REPLACE FUNCTION workflow.fail_job(
    p_job_id uuid,
    p_owner text,
    p_lease_version bigint,
    p_error_code text,
    p_retryable boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_job record;
    v_step record;
    v_delay_ms int := 0;
    v_failure_count int;
    v_new_state text;
BEGIN
    SELECT j.job_id, j.process_id, j.step_instance_id, j.execution_id,
           j.state, j.lease_owner, j.lease_version, j.lease_until, j.attempt_count,
           j.max_attempts, j.delays_ms
    INTO v_job
    FROM workflow.jobs j
    WHERE j.job_id = p_job_id
    FOR UPDATE;

    IF v_job.job_id IS NULL OR p_owner IS NULL OR p_lease_version IS NULL
       OR v_job.state IS DISTINCT FROM 'LEASED'
       OR v_job.lease_owner IS DISTINCT FROM p_owner
       OR v_job.lease_version IS DISTINCT FROM p_lease_version
       OR (v_job.lease_until > clock_timestamp()) IS NOT TRUE THEN
        RAISE EXCEPTION 'workflow.lease_stale';
    END IF;

    SELECT step_instance_id, process_id, step_key
    INTO v_step
    FROM workflow.step_instances
    WHERE step_instance_id = v_job.step_instance_id;

    -- Update running attempt to FAILED
    UPDATE workflow.attempts
    SET status = 'FAILED',
        error_code = p_error_code,
        finished_at = clock_timestamp()
    WHERE job_id = p_job_id
      AND lease_version = p_lease_version
      AND status = 'RUNNING';

    -- STALE claims remain in attempt history but do not consume the failure budget.
    SELECT count(*) INTO v_failure_count
    FROM workflow.attempts WHERE job_id = p_job_id AND status = 'FAILED';

    IF p_retryable AND v_failure_count < v_job.max_attempts THEN
        -- PostgreSQL arrays are 1-based: first failure uses the first delay.
        IF v_failure_count <= cardinality(v_job.delays_ms) THEN
            v_delay_ms := v_job.delays_ms[v_failure_count];
        END IF;

        UPDATE workflow.jobs
        SET state = 'RETRY_WAIT',
            next_attempt_at = clock_timestamp() + (v_delay_ms || ' milliseconds')::interval
        WHERE job_id = p_job_id;

        v_new_state := 'RETRY_WAIT';

        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (v_job.process_id, v_step.step_instance_id, 'TaskRetrying', jsonb_build_object(
            'jobId', p_job_id, 'attempt', v_job.attempt_count, 'errorCode', p_error_code
        ));
    ELSE
        -- Dead job -> failed step -> failed process
        UPDATE workflow.jobs
        SET state = 'DEAD'
        WHERE job_id = p_job_id;

        UPDATE workflow.step_instances
        SET state = 'FAILED',
            completed_at = clock_timestamp()
        WHERE step_instance_id = v_step.step_instance_id;

        UPDATE workflow.process_instances
        SET state = 'FAILED',
            updated_at = clock_timestamp()
        WHERE process_id = v_job.process_id;

        v_new_state := 'DEAD';

        -- TaskFailed event is mandatory when retries are exhausted / fatal error
        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (v_job.process_id, v_step.step_instance_id, 'TaskFailed', jsonb_build_object(
            'jobId', p_job_id, 'attempt', v_job.attempt_count, 'errorCode', p_error_code
        ));

        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (v_job.process_id, v_step.step_instance_id, 'ProcessFailed', jsonb_build_object(
            'errorCode', p_error_code
        ));
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'jobId', p_job_id,
        'jobState', v_new_state
    );
END;
$$;

CREATE OR REPLACE FUNCTION delivery.claim_outbox(p_owner text, p_limit integer)
RETURNS TABLE(outbox_id uuid, lease_version bigint, external_request_id text, correlation_id uuid, amount text, currency text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_max integer := greatest(1,delivery.setting('outbox_max_attempts',4));
BEGIN
    IF NULLIF(p_owner,'') IS NULL OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
        RAISE EXCEPTION 'delivery.claim_invalid';
    END IF;
    -- A crash on the final attempt still consumes the finite delivery budget.
    WITH expired AS (
        SELECT o.outbox_id FROM delivery.outbox o
        WHERE o.state='LEASED' AND o.lease_until <= clock_timestamp() AND o.attempt_count >= v_max
        FOR UPDATE SKIP LOCKED LIMIT p_limit
    )
    UPDATE delivery.outbox o SET state='DEAD',dead_at=clock_timestamp(),
        last_error_code=COALESCE(o.last_error_code,'delivery.lease_expired')
    FROM expired e WHERE o.outbox_id=e.outbox_id;

    RETURN QUERY WITH claimed AS (
        SELECT o.outbox_id FROM delivery.outbox o
        WHERE ((o.state IN ('PENDING','RETRY_WAIT') AND o.next_attempt_at <= clock_timestamp())
            OR (o.state='LEASED' AND o.lease_until <= clock_timestamp())) AND o.attempt_count < v_max
        ORDER BY o.created_at,o.outbox_id FOR UPDATE SKIP LOCKED LIMIT p_limit
    )
    UPDATE delivery.outbox o SET state='LEASED',lease_owner=p_owner,lease_version=o.lease_version+1,
        lease_until=clock_timestamp()+make_interval(secs=>greatest(1,delivery.setting('outbox_lease_ms',2000))/1000.0),
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
    SELECT * INTO v_row FROM delivery.outbox WHERE outbox_id=p_outbox_id FOR UPDATE;
    -- A lock wait can outlive the lease even when the transaction began on time.
    IF NOT FOUND OR p_owner IS NULL OR p_lease_version IS NULL OR v_row.state IS DISTINCT FROM 'LEASED'
        OR v_row.lease_owner IS DISTINCT FROM p_owner
        OR v_row.lease_version IS DISTINCT FROM p_lease_version
        OR (v_row.lease_until > clock_timestamp()) IS NOT TRUE THEN
        RETURN jsonb_build_object('updated',false);
    END IF;
    IF p_error_code IS NULL OR length(p_error_code)>128 OR p_error_code !~ '^[a-z][a-z0-9_.]*$' THEN
        p_error_code := 'delivery.invalid_error';
    END IF;
    v_retry := p_error_code LIKE '%.retryable' AND v_row.attempt_count < greatest(1,delivery.setting('outbox_max_attempts',4));
    v_delay := least(greatest(0,delivery.setting('outbox_backoff_max_ms',800)),
        greatest(0,delivery.setting('outbox_backoff_base_ms',200))*power(2.0,least(v_row.attempt_count-1,30)))
        + floor(random()*(greatest(0,delivery.setting('outbox_jitter_max_ms',100))+1));
    UPDATE delivery.outbox SET state=CASE WHEN v_retry THEN 'RETRY_WAIT' ELSE 'DEAD' END,
        last_error_code=p_error_code, next_attempt_at=CASE WHEN v_retry THEN clock_timestamp()+make_interval(secs=>v_delay/1000.0) ELSE next_attempt_at END,
        dead_at=CASE WHEN v_retry THEN dead_at ELSE clock_timestamp() END,lease_until=NULL
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
    SELECT * INTO v_row FROM delivery.outbox WHERE outbox_id=p_outbox_id FOR UPDATE;
    -- A lock wait can outlive the lease even when the transaction began on time.
    IF NOT FOUND OR p_owner IS NULL OR p_lease_version IS NULL OR v_row.state IS DISTINCT FROM 'LEASED'
        OR v_row.lease_owner IS DISTINCT FROM p_owner
        OR v_row.lease_version IS DISTINCT FROM p_lease_version
        OR (v_row.lease_until > clock_timestamp()) IS NOT TRUE THEN
        RETURN jsonb_build_object('updated',false);
    END IF;
    UPDATE delivery.outbox SET state='DELIVERED',delivered_at=clock_timestamp(),lease_until=NULL
    WHERE outbox_id=p_outbox_id RETURNING * INTO v_row;
    UPDATE delivery.external_requests SET state='SENT' WHERE external_request_id=v_external AND state='CREATED';
    RETURN jsonb_build_object('updated',true,'state',v_row.state,'attemptCount',v_row.attempt_count);
END;
$$;

-- The grace period starts at the persisted transition to DEAD; equality includes the boundary.
CREATE OR REPLACE FUNCTION diagnostics.stalled_v1(p_context jsonb,p_payload jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('status','ok','outcome','FOUND','result',jsonb_build_object('items',
        COALESCE(jsonb_agg(jsonb_build_object('operationId',op.operation_id,'processId',p.process_id,
            'externalRequestId',e.external_request_id) ORDER BY op.operation_id),'[]'::jsonb)))
    FROM payment.operations op JOIN workflow.process_instances p USING(process_id)
    JOIN delivery.external_requests e ON e.operation_id=op.operation_id
    JOIN delivery.outbox o USING(external_request_id)
    WHERE o.state='DEAD' AND p.state='WAITING_SIGNAL' AND op.status='PROCESSING'
      AND o.dead_at <= statement_timestamp() - interval '10 seconds'
$$;

RESET ROLE;
