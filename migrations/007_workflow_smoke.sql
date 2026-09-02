-- 007_workflow_smoke.sql

CREATE SCHEMA IF NOT EXISTS training AUTHORIZATION course_owner;

CREATE TABLE IF NOT EXISTS training.canary_effects (
    execution_id text PRIMARY KEY,
    value text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE training.canary_effects OWNER TO course_owner;

CREATE OR REPLACE FUNCTION training.canary_v1(
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp, training, api, catalog
AS $$
DECLARE
    v_exec_id text := p_context ->> 'executionId';
    v_value text := p_payload ->> 'value';
BEGIN
    IF v_exec_id IS NOT NULL AND v_exec_id <> '' THEN
        INSERT INTO training.canary_effects (execution_id, value)
        VALUES (v_exec_id, v_value)
        ON CONFLICT (execution_id) DO NOTHING;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'APPLIED',
        'result', jsonb_build_object(
            'executionId', COALESCE(v_exec_id, ''),
            'value', v_value
        ),
        'meta', jsonb_build_object(
            'correlationId', p_context ->> 'correlationId',
            'actionVersion', 1
        )
    );
END;
$$;
ALTER FUNCTION training.canary_v1(jsonb, jsonb) OWNER TO course_owner;

INSERT INTO catalog.actions (
    module, action, version, manifest_json, manifest_hash,
    target_schema, target_function, http_method, outcomes,
    required_policy, idempotency_mode, idempotency_scope,
    timeout_ms, enabled, is_default
) VALUES (
    'training', 'canary', 1,
    '{
        "contract_version": "course-1",
        "module": "training",
        "action": "canary",
        "version": 1,
        "http_method": "POST",
        "target_schema": "training",
        "target_function": "canary_v1",
        "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["value"],
            "properties": {
                "value": { "type": "string" }
            },
            "additionalProperties": false
        },
        "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["executionId", "value"],
            "properties": {
                "executionId": { "type": "string" },
                "value": { "type": "string" }
            },
            "additionalProperties": false
        },
        "outcomes": ["APPLIED"],
        "required_policy": ["workflow:execute"],
        "idempotency_mode": "none",
        "idempotency_scope": "none",
        "timeout_ms": 2000,
        "enabled": true,
        "is_default": true
    }'::jsonb,
    encode(sha256('{
        "contract_version": "course-1",
        "module": "training",
        "action": "canary",
        "version": 1,
        "http_method": "POST",
        "target_schema": "training",
        "target_function": "canary_v1",
        "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["value"],
            "properties": {
                "value": { "type": "string" }
            },
            "additionalProperties": false
        },
        "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "required": ["executionId", "value"],
            "properties": {
                "executionId": { "type": "string" },
                "value": { "type": "string" }
            },
            "additionalProperties": false
        },
        "outcomes": ["APPLIED"],
        "required_policy": ["workflow:execute"],
        "idempotency_mode": "none",
        "idempotency_scope": "none",
        "timeout_ms": 2000,
        "enabled": true,
        "is_default": true
    }'::bytea), 'hex'),
    'training', 'canary_v1', 'POST', '["APPLIED"]'::jsonb,
    '["workflow:execute"]'::jsonb, 'none', 'none',
    2000, true, true
)
ON CONFLICT (module, action, version) DO NOTHING;
