-- 006_workflow_views_and_actions.sql

-- ============================================================
-- 1. AUTOCHECK VIEWS
-- ============================================================

CREATE OR REPLACE VIEW autocheck.flow_versions AS
    SELECT flow_name, flow_version, status, is_active, published_at
    FROM workflow.flow_versions;
ALTER VIEW autocheck.flow_versions OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.processes AS
    SELECT process_id, business_key, flow_name, flow_version,
           state, current_step_key, created_at, updated_at
    FROM workflow.process_instances;
ALTER VIEW autocheck.processes OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.steps AS
    SELECT step_instance_id, process_id, step_key, step_type,
           state, outcome, entered_at, completed_at
    FROM workflow.step_instances;
ALTER VIEW autocheck.steps OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.jobs AS
    SELECT job_id, process_id, step_instance_id, execution_id,
           state, lease_owner, lease_version, lease_until,
           attempt_count, next_attempt_at
    FROM workflow.jobs;
ALTER VIEW autocheck.jobs OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.attempts AS
    SELECT attempt_id, job_id, execution_id, lease_version,
           attempt_number, status, outcome, error_code,
           started_at, finished_at
    FROM workflow.attempts;
ALTER VIEW autocheck.attempts OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.signals AS
    SELECT message_id, process_id, signal_type, body_hash,
           status, received_at
    FROM workflow.signals;
ALTER VIEW autocheck.signals OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.workflow_events AS
    SELECT event_id, process_id, step_instance_id, event_type, occurred_at
    FROM workflow.events;
ALTER VIEW autocheck.workflow_events OWNER TO course_owner;

-- View grants
GRANT SELECT ON autocheck.flow_versions TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.processes TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.steps TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.jobs TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.attempts TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.signals TO course_runtime, course_publication, workflow_worker;
GRANT SELECT ON autocheck.workflow_events TO course_runtime, course_publication, workflow_worker;

-- ============================================================
-- 2. ACTION: workflow.get v1
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.get_v1(
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp, workflow, api, catalog
AS $$
DECLARE
    v_process_id_text text;
    v_process_id uuid;
    v_process jsonb;
    v_steps jsonb;
    v_jobs jsonb;
    v_attempts jsonb;
    v_meta jsonb;
BEGIN
    v_meta := jsonb_build_object(
        'correlationId', p_context ->> 'correlationId',
        'actionVersion', 1
    );

    v_process_id_text := p_payload ->> 'processId';
    IF v_process_id_text IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'processId is required',
            'retryable', false,
            'details', '{}'::jsonb,
            'meta', v_meta
        );
    END IF;

    BEGIN
        v_process_id := v_process_id_text::uuid;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'payload.invalid',
            'message', 'processId must be a valid UUID',
            'retryable', false,
            'details', '{}'::jsonb,
            'meta', v_meta
        );
    END;

    -- Process details
    SELECT jsonb_build_object(
        'processId', process_id,
        'businessKey', business_key,
        'flowName', flow_name,
        'flowVersion', flow_version,
        'state', state,
        'currentStepKey', current_step_key,
        'createdAt', created_at,
        'updatedAt', updated_at
    ) INTO v_process
    FROM workflow.process_instances
    WHERE process_id = v_process_id;

    IF v_process IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'workflow.not_found',
            'message', 'Process not found',
            'retryable', false,
            'details', '{}'::jsonb,
            'meta', v_meta
        );
    END IF;

    -- Steps details
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'stepInstanceId', step_instance_id,
        'processId', process_id,
        'stepKey', step_key,
        'stepType', step_type,
        'state', state,
        'outcome', outcome,
        'enteredAt', entered_at,
        'completedAt', completed_at
    ) ORDER BY entered_at ASC), '[]'::jsonb) INTO v_steps
    FROM workflow.step_instances
    WHERE process_id = v_process_id;

    -- Jobs details
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'jobId', job_id,
        'processId', process_id,
        'stepInstanceId', step_instance_id,
        'executionId', execution_id,
        'state', state,
        'leaseOwner', lease_owner,
        'leaseVersion', lease_version,
        'leaseUntil', lease_until,
        'attemptCount', attempt_count,
        'nextAttemptAt', next_attempt_at
    ) ORDER BY created_at ASC), '[]'::jsonb) INTO v_jobs
    FROM workflow.jobs
    WHERE process_id = v_process_id;

    -- Attempts details
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'attemptId', a.attempt_id,
        'jobId', a.job_id,
        'executionId', a.execution_id,
        'leaseVersion', a.lease_version,
        'attemptNumber', a.attempt_number,
        'status', a.status,
        'outcome', a.outcome,
        'errorCode', a.error_code,
        'startedAt', a.started_at,
        'finishedAt', a.finished_at
    ) ORDER BY a.started_at ASC), '[]'::jsonb) INTO v_attempts
    FROM workflow.attempts a
    JOIN workflow.jobs j ON j.job_id = a.job_id
    WHERE j.process_id = v_process_id;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'FOUND',
        'result', jsonb_build_object(
            'process', v_process,
            'steps', v_steps,
            'jobs', v_jobs,
            'attempts', v_attempts
        ),
        'meta', v_meta
    );
END;
$$;
ALTER FUNCTION workflow.get_v1(jsonb, jsonb) OWNER TO course_owner;

-- ============================================================
-- 3. REGISTER workflow.get v1 IN CATALOG
-- ============================================================

INSERT INTO catalog.actions (
    module, action, version, manifest_json, manifest_hash,
    target_schema, target_function, http_method, outcomes,
    required_policy, idempotency_mode, idempotency_scope,
    timeout_ms, enabled, is_default
) VALUES (
    'workflow', 'get', 1,
    '{
        "contract_version": "course-1",
        "module": "workflow",
        "action": "get",
        "version": 1,
        "http_method": "POST",
        "target_schema": "workflow",
        "target_function": "get_v1",
        "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["processId"],
            "properties": {
                "processId": { "type": "string", "format": "uuid" }
            },
            "additionalProperties": false
        },
        "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["process", "steps", "jobs", "attempts"],
            "properties": {
                "process": { "type": "object" },
                "steps": { "type": "array" },
                "jobs": { "type": "array" },
                "attempts": { "type": "array" }
            },
            "additionalProperties": false
        },
        "outcomes": ["FOUND"],
        "required_policy": ["workflow:read"],
        "idempotency_mode": "none",
        "idempotency_scope": "none",
        "timeout_ms": 5000,
        "enabled": true,
        "is_default": true
    }'::jsonb,
    encode(sha256('{
        "contract_version": "course-1",
        "module": "workflow",
        "action": "get",
        "version": 1,
        "http_method": "POST",
        "target_schema": "workflow",
        "target_function": "get_v1",
        "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["processId"],
            "properties": {
                "processId": { "type": "string", "format": "uuid" }
            },
            "additionalProperties": false
        },
        "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["process", "steps", "jobs", "attempts"],
            "properties": {
                "process": { "type": "object" },
                "steps": { "type": "array" },
                "jobs": { "type": "array" },
                "attempts": { "type": "array" }
            },
            "additionalProperties": false
        },
        "outcomes": ["FOUND"],
        "required_policy": ["workflow:read"],
        "idempotency_mode": "none",
        "idempotency_scope": "none",
        "timeout_ms": 5000,
        "enabled": true,
        "is_default": true
    }'::bytea), 'hex'),
    'workflow', 'get_v1', 'POST', '["FOUND"]'::jsonb,
    '["workflow:read"]'::jsonb, 'none', 'none',
    5000, true, true
)
ON CONFLICT (module, action, version) DO NOTHING;
