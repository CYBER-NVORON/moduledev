-- 005_workflow_functions.sql

-- ============================================================
-- 1. HELPER: workflow.enter_step
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.enter_step(
    p_process_id uuid,
    p_map_json jsonb,
    p_step_key text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_step jsonb;
    v_step_type text;
    v_step_id uuid;
    v_signal_type text;
    v_expected_outcome text;
    v_signal record;
    v_trans jsonb;
    v_next_step_key text;
    v_delays integer[];
    v_d jsonb;
    v_max_attempts int;
BEGIN
    -- Find step definition in map_json->'steps'
    SELECT elem INTO v_step
    FROM jsonb_array_elements(p_map_json->'steps') elem
    WHERE elem->>'key' = p_step_key;

    IF v_step IS NULL THEN
        RAISE EXCEPTION 'Step % not found in map', p_step_key;
    END IF;

    v_step_type := v_step->>'type';

    IF v_step_type = 'automatic' THEN
        -- Parse delays array
        v_delays := '{}';
        IF v_step->'task'->'retry'->'delays_ms' IS NOT NULL THEN
            FOR v_d IN SELECT * FROM jsonb_array_elements(v_step->'task'->'retry'->'delays_ms')
            LOOP
                v_delays := array_append(v_delays, (v_d#>>'{}')::integer);
            END LOOP;
        END IF;
        v_max_attempts := COALESCE((v_step->'task'->'retry'->>'max_attempts')::integer, 1);

        -- Create step instance
        INSERT INTO workflow.step_instances (
            process_id, step_key, step_type, state, entered_at
        ) VALUES (
            p_process_id, p_step_key, 'AUTOMATIC', 'READY', clock_timestamp()
        ) RETURNING step_instance_id INTO v_step_id;

        -- Create job
        INSERT INTO workflow.jobs (
            process_id, step_instance_id, execution_id, state,
            max_attempts, delays_ms, created_at
        ) VALUES (
            p_process_id, v_step_id, gen_random_uuid(), 'READY',
            v_max_attempts, v_delays, clock_timestamp()
        );

        -- Update process
        UPDATE workflow.process_instances
        SET state = 'RUNNING',
            current_step_key = p_step_key,
            updated_at = clock_timestamp()
        WHERE process_id = p_process_id;

        -- Event
        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (p_process_id, v_step_id, 'StepEntered', jsonb_build_object('stepKey', p_step_key, 'type', 'AUTOMATIC'));

    ELSIF v_step_type = 'wait_signal' THEN
        v_signal_type := v_step->>'signal_type';
        v_expected_outcome := v_step->>'outcome';

        -- Create step instance
        INSERT INTO workflow.step_instances (
            process_id, step_key, step_type, state, entered_at
        ) VALUES (
            p_process_id, p_step_key, 'WAIT_SIGNAL', 'WAITING', clock_timestamp()
        ) RETURNING step_instance_id INTO v_step_id;

        -- Check pre-arrived signals
        SELECT message_id INTO v_signal
        FROM workflow.signals
        WHERE process_id = p_process_id
          AND signal_type = v_signal_type
          AND status = 'ACCEPTED'
        ORDER BY received_at ASC
        LIMIT 1
        FOR UPDATE;

        IF v_signal.message_id IS NOT NULL THEN
            -- Apply signal immediately
            UPDATE workflow.signals
            SET status = 'APPLIED'
            WHERE message_id = v_signal.message_id;

            UPDATE workflow.step_instances
            SET state = 'COMPLETED',
                outcome = v_expected_outcome,
                completed_at = clock_timestamp()
            WHERE step_instance_id = v_step_id;

            INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
            VALUES (p_process_id, v_step_id, 'SignalApplied', jsonb_build_object('messageId', v_signal.message_id, 'signalType', v_signal_type));

            INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
            VALUES (p_process_id, v_step_id, 'StepCompleted', jsonb_build_object('stepKey', p_step_key, 'outcome', v_expected_outcome));

            -- Find transition
            SELECT elem INTO v_trans
            FROM jsonb_array_elements(p_map_json->'transitions') elem
            WHERE elem->>'from' = p_step_key AND elem->>'outcome' = v_expected_outcome;

            IF v_trans IS NULL THEN
                RAISE EXCEPTION 'Transition not found for step % outcome %', p_step_key, v_expected_outcome;
            END IF;

            v_next_step_key := v_trans->>'to';
            PERFORM workflow.enter_step(p_process_id, p_map_json, v_next_step_key);
        ELSE
            -- Wait for signal
            UPDATE workflow.process_instances
            SET state = 'WAITING_SIGNAL',
                current_step_key = p_step_key,
                updated_at = clock_timestamp()
            WHERE process_id = p_process_id;

            INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
            VALUES (p_process_id, v_step_id, 'ProcessWaitingSignal', jsonb_build_object('stepKey', p_step_key, 'signalType', v_signal_type));
        END IF;

    ELSIF v_step_type = 'manual' THEN
        INSERT INTO workflow.step_instances (
            process_id, step_key, step_type, state, entered_at
        ) VALUES (
            p_process_id, p_step_key, 'MANUAL', 'WAITING', clock_timestamp()
        ) RETURNING step_instance_id INTO v_step_id;

        UPDATE workflow.process_instances
        SET state = 'WAITING_MANUAL',
            current_step_key = p_step_key,
            updated_at = clock_timestamp()
        WHERE process_id = p_process_id;

        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (p_process_id, v_step_id, 'ProcessWaitingManual', jsonb_build_object('stepKey', p_step_key));

    ELSIF v_step_type = 'end' THEN
        v_expected_outcome := v_step->>'outcome';

        INSERT INTO workflow.step_instances (
            process_id, step_key, step_type, state, outcome, entered_at, completed_at
        ) VALUES (
            p_process_id, p_step_key, 'END', 'COMPLETED', v_expected_outcome, clock_timestamp(), clock_timestamp()
        ) RETURNING step_instance_id INTO v_step_id;

        UPDATE workflow.process_instances
        SET state = 'COMPLETED',
            current_step_key = p_step_key,
            updated_at = clock_timestamp()
        WHERE process_id = p_process_id;

        INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
        VALUES (p_process_id, v_step_id, 'ProcessCompleted', jsonb_build_object('outcome', v_expected_outcome));
    END IF;
END;
$$;
ALTER FUNCTION workflow.enter_step(uuid, jsonb, text) OWNER TO course_owner;

-- ============================================================
-- 2. WORKFLOW: claim_jobs
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.claim_jobs(
    p_owner text,
    p_limit int,
    p_lease_seconds int
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_job record;
    v_claimed jsonb := '[]'::jsonb;
    v_new_attempt_id uuid;
    v_map_json jsonb;
    v_proc_data jsonb;
    v_step_def jsonb;
    v_task jsonb;
    v_expected_outcomes jsonb;
    v_action_manifest jsonb;
    v_lease_until timestamptz;
BEGIN
    v_lease_until := clock_timestamp() + (p_lease_seconds || ' seconds')::interval;

    FOR v_job IN
        SELECT j.job_id, j.process_id, j.step_instance_id, j.execution_id,
               j.state, j.lease_version, j.attempt_count,
               s.step_key, p.flow_name, p.flow_version, p.data_json
        FROM workflow.jobs j
        JOIN workflow.step_instances s ON s.step_instance_id = j.step_instance_id
        JOIN workflow.process_instances p ON p.process_id = j.process_id
        WHERE j.state = 'READY'
           OR (j.state = 'RETRY_WAIT' AND j.next_attempt_at <= clock_timestamp())
           OR (j.state = 'LEASED' AND j.lease_until < clock_timestamp())
        ORDER BY j.created_at ASC
        LIMIT p_limit
        FOR UPDATE OF j SKIP LOCKED
    LOOP
        -- If reclaiming an expired lease, mark any running attempt as STALE
        IF v_job.state = 'LEASED' THEN
            UPDATE workflow.attempts
            SET status = 'STALE',
                finished_at = clock_timestamp()
            WHERE job_id = v_job.job_id
              AND status = 'RUNNING';
        END IF;

        -- Increment lease version and attempt count
        UPDATE workflow.jobs
        SET state = 'LEASED',
            lease_owner = p_owner,
            lease_version = v_job.lease_version + 1,
            lease_until = v_lease_until,
            attempt_count = v_job.attempt_count + 1
        WHERE job_id = v_job.job_id;

        -- Update step instance to RUNNING
        UPDATE workflow.step_instances
        SET state = 'RUNNING'
        WHERE step_instance_id = v_job.step_instance_id;

        -- Create new attempt record
        v_new_attempt_id := gen_random_uuid();
        INSERT INTO workflow.attempts (
            attempt_id, job_id, execution_id, lease_version,
            attempt_number, status, started_at
        ) VALUES (
            v_new_attempt_id, v_job.job_id, v_job.execution_id, v_job.lease_version + 1,
            v_job.attempt_count + 1, 'RUNNING', clock_timestamp()
        );

        -- Load flow version map
        SELECT map_json INTO v_map_json
        FROM workflow.flow_versions
        WHERE flow_name = v_job.flow_name AND flow_version = v_job.flow_version;

        -- Extract step definition & task
        SELECT elem INTO v_step_def
        FROM jsonb_array_elements(v_map_json->'steps') elem
        WHERE elem->>'key' = v_job.step_key;

        v_task := v_step_def->'task';

        -- Extract expected outcomes for this step from transitions
        SELECT COALESCE(jsonb_agg(elem->>'outcome'), '[]'::jsonb) INTO v_expected_outcomes
        FROM jsonb_array_elements(v_map_json->'transitions') elem
        WHERE elem->>'from' = v_job.step_key;

        -- Extract request and response schemas from catalog.actions
        SELECT manifest_json INTO v_action_manifest
        FROM catalog.actions
        WHERE module = v_task->>'module'
          AND action = v_task->>'action'
          AND version = (v_task->>'action_version')::integer;

        v_claimed := v_claimed || jsonb_build_array(jsonb_build_object(
            'jobId', v_job.job_id,
            'processId', v_job.process_id,
            'stepInstanceId', v_job.step_instance_id,
            'executionId', v_job.execution_id,
            'attemptId', v_new_attempt_id,
            'leaseVersion', v_job.lease_version + 1,
            'stepKey', v_job.step_key,
            'service', v_task->>'service',
            'module', v_task->>'module',
            'action', v_task->>'action',
            'actionVersion', (v_task->>'action_version')::integer,
            'requiredPolicy', COALESCE(v_task->'required_policy', '[]'::jsonb),
            'timeoutMs', COALESCE((v_task->>'timeout_ms')::integer, 5000),
            'inputMapping', COALESCE(v_task->'input_mapping', '{}'::jsonb),
            'inputConstants', COALESCE(v_task->'input_constants', '{}'::jsonb),
            'processData', COALESCE(v_job.data_json, '{}'::jsonb),
            'expectedOutcomes', v_expected_outcomes,
            'requestSchema', v_action_manifest->'request_schema',
            'responseSchema', v_action_manifest->'response_schema'
        ));
    END LOOP;

    RETURN v_claimed;
END;
$$;
ALTER FUNCTION workflow.claim_jobs(text, int, int) OWNER TO course_owner;

-- ============================================================
-- 3. WORKFLOW: finish_job
-- ============================================================

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
    -- Fencing check: lock and verify job ownership & lease version
    SELECT j.job_id, j.process_id, j.step_instance_id, j.execution_id,
           j.state, j.lease_owner, j.lease_version
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
ALTER FUNCTION workflow.finish_job(uuid, text, bigint, text, jsonb) OWNER TO course_owner;

-- ============================================================
-- 4. WORKFLOW: fail_job
-- ============================================================

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

    -- Determine retry vs dead
    IF p_retryable AND v_job.attempt_count < v_job.max_attempts THEN
        -- Get delay from delays_ms (attempt_count is 1-based index)
        IF v_job.attempt_count <= cardinality(v_job.delays_ms) THEN
            v_delay_ms := v_job.delays_ms[v_job.attempt_count];
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

-- ============================================================
-- 5. WORKFLOW: start_process
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.start_process(
    p_flow_name text,
    p_business_key text,
    p_data jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_ver record;
    v_existing record;
    v_process_id uuid;
    v_start_step text;
    v_proc_state text;
    v_curr_step text;
    v_input_data jsonb;
BEGIN
    v_input_data := COALESCE(p_data, '{}'::jsonb);

    -- Find active flow version
    SELECT flow_version, map_json
    INTO v_ver
    FROM workflow.flow_versions
    WHERE flow_name = p_flow_name AND is_active = true;

    IF v_ver.flow_version IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'flow.not_active',
            'message', format('No active version found for flow %s', p_flow_name)
        );
    END IF;

    -- Check idempotency by (flow_name, business_key)
    SELECT process_id, data_json, state, flow_version, current_step_key
    INTO v_existing
    FROM workflow.process_instances
    WHERE flow_name = p_flow_name AND business_key = p_business_key;

    IF v_existing.process_id IS NOT NULL THEN
        IF v_existing.data_json = v_input_data THEN
            RETURN jsonb_build_object(
                'status', 'ok',
                'resource', 'process',
                'operation', 'started',
                'processId', v_existing.process_id,
                'flowName', p_flow_name,
                'flowVersion', v_existing.flow_version,
                'state', v_existing.state
            );
        ELSE
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'process.conflict',
                'message', 'Process already exists with different data'
            );
        END IF;
    END IF;

    -- Create new process instance
    v_process_id := gen_random_uuid();
    INSERT INTO workflow.process_instances (
        process_id, business_key, flow_name, flow_version, state, data_json
    ) VALUES (
        v_process_id, p_business_key, p_flow_name, v_ver.flow_version, 'CREATED', v_input_data
    );

    INSERT INTO workflow.events (process_id, event_type, detail_json)
    VALUES (v_process_id, 'ProcessStarted', jsonb_build_object(
        'flowName', p_flow_name,
        'flowVersion', v_ver.flow_version,
        'businessKey', p_business_key
    ));

    -- Enter start step
    v_start_step := v_ver.map_json->>'start_step';
    PERFORM workflow.enter_step(v_process_id, v_ver.map_json, v_start_step);

    -- Read resulting state
    SELECT state, current_step_key
    INTO v_proc_state, v_curr_step
    FROM workflow.process_instances
    WHERE process_id = v_process_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'resource', 'process',
        'operation', 'started',
        'processId', v_process_id,
        'flowName', p_flow_name,
        'flowVersion', v_ver.flow_version,
        'state', v_proc_state
    );
END;
$$;
ALTER FUNCTION workflow.start_process(text, text, jsonb) OWNER TO course_owner;

-- ============================================================
-- 6. WORKFLOW: accept_signal
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.accept_signal(
    p_process_id uuid,
    p_signal_type text,
    p_message_id text,
    p_body jsonb,
    p_body_hash text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, workflow, api, catalog, public
AS $$
DECLARE
    v_proc record;
    v_ver record;
    v_existing record;
    v_declared boolean := false;
    v_step_def jsonb;
    v_waiting_step record;
    v_expected_outcome text;
    v_trans jsonb;
    v_next_step_key text;
BEGIN
    -- Check process exists
    SELECT process_id, flow_name, flow_version, state, current_step_key
    INTO v_proc
    FROM workflow.process_instances
    WHERE process_id = p_process_id
    FOR UPDATE;

    IF v_proc.process_id IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'process.not_found',
            'message', 'Process not found'
        );
    END IF;

    -- Load map definition
    SELECT flow_version, map_json
    INTO v_ver
    FROM workflow.flow_versions
    WHERE flow_name = v_proc.flow_name AND flow_version = v_proc.flow_version;

    -- Check if signal_type is declared in pinned map
    FOR v_step_def IN SELECT * FROM jsonb_array_elements(v_ver.map_json->'steps')
    LOOP
        IF v_step_def->>'type' = 'wait_signal' AND v_step_def->>'signal_type' = p_signal_type THEN
            v_declared := true;
            EXIT;
        END IF;
    END LOOP;

    IF NOT v_declared THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'signal.invalid',
            'message', format('Signal type %s is not declared in flow map', p_signal_type)
        );
    END IF;

    -- Idempotency check by message_id
    SELECT message_id, process_id, signal_type, body_hash, status
    INTO v_existing
    FROM workflow.signals
    WHERE message_id = p_message_id;

    IF v_existing.message_id IS NOT NULL THEN
        IF v_existing.process_id = p_process_id
           AND v_existing.signal_type = p_signal_type
           AND v_existing.body_hash = p_body_hash THEN
            RETURN jsonb_build_object(
                'status', 'ok',
                'resource', 'signal',
                'processId', p_process_id,
                'messageId', p_message_id,
                'signalType', p_signal_type,
                'status', 'duplicate'
            );
        ELSE
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'signal.conflict',
                'message', 'Message ID already used with different signal data'
            );
        END IF;
    END IF;

    -- Insert signal record
    INSERT INTO workflow.signals (
        message_id, process_id, signal_type, body_json, body_hash, status, received_at
    ) VALUES (
        p_message_id, p_process_id, p_signal_type, p_body, p_body_hash, 'ACCEPTED', clock_timestamp()
    );

    INSERT INTO workflow.events (process_id, event_type, detail_json)
    VALUES (p_process_id, 'SignalAccepted', jsonb_build_object(
        'messageId', p_message_id, 'signalType', p_signal_type
    ));

    -- If process is currently at WAITING_SIGNAL step matching this signal_type, apply it
    IF v_proc.state = 'WAITING_SIGNAL' THEN
        SELECT s.step_instance_id, s.step_key
        INTO v_waiting_step
        FROM workflow.step_instances s
        WHERE s.process_id = p_process_id
          AND s.state = 'WAITING'
          AND s.step_type = 'WAIT_SIGNAL'
        ORDER BY s.entered_at DESC
        LIMIT 1;

        IF v_waiting_step.step_instance_id IS NOT NULL THEN
            -- Find step in map to check signal_type
            SELECT elem INTO v_step_def
            FROM jsonb_array_elements(v_ver.map_json->'steps') elem
            WHERE elem->>'key' = v_waiting_step.step_key;

            IF v_step_def->>'signal_type' = p_signal_type THEN
                v_expected_outcome := v_step_def->>'outcome';

                UPDATE workflow.signals
                SET status = 'APPLIED'
                WHERE message_id = p_message_id;

                UPDATE workflow.step_instances
                SET state = 'COMPLETED',
                    outcome = v_expected_outcome,
                    completed_at = clock_timestamp()
                WHERE step_instance_id = v_waiting_step.step_instance_id;

                INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
                VALUES (p_process_id, v_waiting_step.step_instance_id, 'SignalApplied', jsonb_build_object(
                    'messageId', p_message_id, 'signalType', p_signal_type
                ));

                INSERT INTO workflow.events (process_id, step_instance_id, event_type, detail_json)
                VALUES (p_process_id, v_waiting_step.step_instance_id, 'StepCompleted', jsonb_build_object(
                    'stepKey', v_waiting_step.step_key, 'outcome', v_expected_outcome
                ));

                -- Find transition
                SELECT elem INTO v_trans
                FROM jsonb_array_elements(v_ver.map_json->'transitions') elem
                WHERE elem->>'from' = v_waiting_step.step_key AND elem->>'outcome' = v_expected_outcome;

                IF v_trans IS NOT NULL THEN
                    v_next_step_key := v_trans->>'to';
                    PERFORM workflow.enter_step(p_process_id, v_ver.map_json, v_next_step_key);
                END IF;
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'resource', 'signal',
        'processId', p_process_id,
        'messageId', p_message_id,
        'signalType', p_signal_type,
        'status', 'accepted'
    );
END;
$$;
ALTER FUNCTION workflow.accept_signal(uuid, text, text, jsonb, text) OWNER TO course_owner;

-- ============================================================
-- 7. REVOKE PUBLIC & ASSIGN LEAST-PRIVILEGE ROLES
-- ============================================================

-- Revoke default PUBLIC execute on all routines in api and workflow schemas
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA workflow FROM PUBLIC;

-- Workflow worker: minimal required execution privileges
GRANT EXECUTE ON FUNCTION workflow.claim_jobs(text, int, int) TO workflow_worker;
GRANT EXECUTE ON FUNCTION api.invoke(text, text, integer, jsonb, jsonb) TO workflow_worker;
GRANT EXECUTE ON FUNCTION workflow.finish_job(uuid, text, bigint, text, jsonb) TO workflow_worker;
GRANT EXECUTE ON FUNCTION workflow.fail_job(uuid, text, bigint, text, boolean) TO workflow_worker;

-- Course runtime: api.invoke
GRANT EXECUTE ON FUNCTION api.invoke(text, text, integer, jsonb, jsonb) TO course_runtime;

-- Course publication: CLI operations
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA workflow TO course_publication;
