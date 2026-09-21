-- Published definitions are immutable; only operational activation may change.
-- Forward migration: keep the checksums of already applied 001..010 unchanged.
CREATE OR REPLACE FUNCTION workflow.trg_flow_versions_immutability()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF (to_jsonb(NEW) - 'is_active') IS DISTINCT FROM (to_jsonb(OLD) - 'is_active') THEN
        RAISE EXCEPTION 'workflow.flow_versions definition fields are immutable';
    END IF;
    RETURN NEW;
END;
$$;
ALTER FUNCTION workflow.trg_flow_versions_immutability() OWNER TO course_owner;
REVOKE ALL ON FUNCTION workflow.trg_flow_versions_immutability() FROM PUBLIC;

CREATE TRIGGER trg_flow_versions_immutability_check
BEFORE UPDATE ON workflow.flow_versions
FOR EACH ROW EXECUTE FUNCTION workflow.trg_flow_versions_immutability();

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
           j.state, j.lease_owner, j.lease_version, j.attempt_count,
           j.max_attempts, j.delays_ms
    INTO v_job
    FROM workflow.jobs j
    WHERE j.job_id = p_job_id
    FOR UPDATE;

    IF v_job.job_id IS NULL
       OR v_job.state <> 'LEASED'
       OR v_job.lease_owner <> p_owner
       OR v_job.lease_version <> p_lease_version THEN
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
ALTER FUNCTION workflow.fail_job(uuid, text, bigint, text, boolean) OWNER TO course_owner;
