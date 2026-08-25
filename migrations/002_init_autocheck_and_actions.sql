-- 002_init_autocheck_and_actions.sql
-- Phase 1: autocheck views, api.invoke, payment.request_v1, operation.get_v1, catalog registration

CREATE SCHEMA IF NOT EXISTS operation AUTHORIZATION course_owner;

-- ============================================================
-- 1. AUTOCHECK VIEWS (read-only projections for black-box tests)
-- ============================================================

CREATE OR REPLACE VIEW autocheck.contract_info AS
    SELECT 'course-1'::text AS contract_version, now() AS generated_at;
ALTER VIEW autocheck.contract_info OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.action_definitions AS
    SELECT module, action, version, http_method,
           target_schema, target_function, outcomes,
           enabled, is_default
      FROM catalog.actions;
ALTER VIEW autocheck.action_definitions OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.action_dispatches AS
    SELECT correlation_id, request_id, module, action, version,
           principal, payload_hash, status, outcome, occurred_at
      FROM catalog.action_dispatches;
ALTER VIEW autocheck.action_dispatches OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.operations AS
    SELECT operation_id, request_id, operation_kind, amount,
           currency, status, process_id, created_at, updated_at
      FROM payment.operations;
ALTER VIEW autocheck.operations OWNER TO course_owner;

CREATE OR REPLACE VIEW autocheck.operation_events AS
    SELECT event_id, operation_id, event_type, payload_hash, occurred_at
      FROM payment.operation_events;
ALTER VIEW autocheck.operation_events OWNER TO course_owner;

-- PostgreSQL, not process-local state, enforces one enabled default per route.
CREATE UNIQUE INDEX IF NOT EXISTS actions_one_enabled_default
    ON catalog.actions (module, action)
    WHERE enabled AND is_default;

-- Ensure course_runtime and course_publication can SELECT these views
GRANT SELECT ON autocheck.contract_info       TO course_runtime, course_publication;
GRANT SELECT ON autocheck.action_definitions  TO course_runtime, course_publication;
GRANT SELECT ON autocheck.action_dispatches   TO course_runtime, course_publication;
GRANT SELECT ON autocheck.operations          TO course_runtime, course_publication;
GRANT SELECT ON autocheck.operation_events    TO course_runtime, course_publication;

-- ============================================================
-- 2. CORE: api.invoke — generic action dispatcher with idempotency
-- ============================================================

CREATE OR REPLACE FUNCTION api.invoke(
    p_module  text,
    p_action  text,
    p_version integer,
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, catalog, idempotency, public
AS $$
DECLARE
    v_rec           catalog.actions%ROWTYPE;
    v_result        jsonb;
    v_target_result jsonb;
    v_outcome       text;
    v_scope         text;
    v_correlation   text;
    v_principal     text;
    v_payload_hash  text;
    v_request_id    text;
    v_scope_key     text;
    v_correlation_uuid uuid;
    v_scopes        jsonb;
    v_target_status text;
    v_existing      idempotency.records%ROWTYPE;
BEGIN
    -- Context is trusted only after its shape is checked.
    IF jsonb_typeof(COALESCE(p_context, 'null'::jsonb)) <> 'object'
       OR jsonb_typeof(COALESCE(p_context->'correlationId', 'null'::jsonb)) <> 'string'
       OR jsonb_typeof(COALESCE(p_context->'principal', 'null'::jsonb)) <> 'string'
       OR jsonb_typeof(COALESCE(p_context->'consumer', 'null'::jsonb)) <> 'string'
       OR NULLIF(p_context->>'principal', '') IS NULL
       OR NULLIF(p_context->>'consumer', '') IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'request.invalid',
            'message', 'context has invalid required fields'
        );
    END IF;

    IF jsonb_typeof(COALESCE(p_context->'scopes', 'null'::jsonb)) <> 'array' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'request.invalid',
            'message', 'context scopes must be an array'
        );
    END IF;

    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(COALESCE(p_context->'scopes', '[]'::jsonb)) AS scope(value)
         WHERE jsonb_typeof(scope.value) <> 'string'
            OR NULLIF(scope.value #>> '{}', '') IS NULL
    ) THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'request.invalid',
            'message', 'context scopes must contain non-empty strings'
        );
    END IF;

    IF p_context ? 'requestId'
       AND jsonb_typeof(COALESCE(p_context->'requestId', 'null'::jsonb)) <> 'string' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'request.invalid',
            'message', 'context requestId must be a string'
        );
    END IF;

    BEGIN
        v_correlation_uuid := (p_context->>'correlationId')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'request.invalid',
            'message', 'context correlationId must be a UUID'
        );
    END;

    -- Extract context fields after validation.
    v_correlation  := p_context->>'correlationId';
    v_principal    := p_context->>'principal';
    v_request_id   := p_context->>'requestId';
    v_scopes       := COALESCE(p_context->'scopes', '[]'::jsonb);
    v_payload_hash := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');

    -- Resolve action version
    IF p_version IS NOT NULL THEN
        SELECT * INTO v_rec
          FROM catalog.actions a
         WHERE a.module = p_module
           AND a.action = p_action
           AND a.version = p_version;
    ELSE
        SELECT * INTO v_rec
          FROM catalog.actions a
         WHERE a.module = p_module
           AND a.action = p_action
           AND a.is_default = true
           AND a.enabled = true;
    END IF;

    IF v_rec.module IS NULL THEN
        -- Log dispatch as ERROR
        INSERT INTO catalog.action_dispatches
            (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome)
        VALUES
            (v_correlation::uuid, v_request_id, p_module, p_action, COALESCE(p_version, 0),
             v_principal, v_payload_hash, 'ERROR', NULL);
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.not_found',
            'message', format('action %s.%s not found or disabled', p_module, p_action)
        );
    END IF;

    -- Check enabled
    IF NOT v_rec.enabled THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.not_found',
            'message', format('action %s.%s v%s is disabled', p_module, p_action, v_rec.version)
        );
    END IF;

    -- Check required_policy scopes
    IF v_rec.required_policy IS NOT NULL AND jsonb_array_length(v_rec.required_policy) > 0 THEN
        FOR v_scope IN SELECT jsonb_array_elements_text(v_rec.required_policy) LOOP
            IF NOT (v_scopes @> jsonb_build_array(v_scope)) THEN
                RETURN jsonb_build_object(
                    'status', 'error',
                    'code', 'access.denied',
                    'message', format('missing required scope: %s', v_scope)
                );
            END IF;
        END LOOP;
    END IF;

    IF v_rec.idempotency_mode = 'required' AND NULLIF(v_request_id, '') IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'idempotency.required',
            'message', 'Idempotency-Key is required'
        );
    END IF;

    -- Verify the exact target signature, never just the function name.
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = v_rec.target_schema
          AND p.proname = v_rec.target_function
          AND p.prokind = 'f'
          AND p.pronargs = 2
          AND p.proargtypes = ARRAY['jsonb'::regtype, 'jsonb'::regtype]::oidvector
          AND p.prorettype = 'jsonb'::regtype
    ) THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.not_found',
            'message', 'target function does not exist or has invalid signature'
        );
    END IF;

    -- Idempotency checking & pessimistic lock
    IF v_rec.idempotency_mode IN ('required', 'optional') AND v_request_id IS NOT NULL AND v_request_id != '' THEN
        IF v_rec.idempotency_scope = 'principal_action' THEN
            v_scope_key := v_principal || ':' || p_module || '.' || p_action;
        ELSIF v_rec.idempotency_scope = 'consumer_action' THEN
            v_scope_key := (p_context->>'consumer') || ':' || p_module || '.' || p_action;
        ELSIF v_rec.idempotency_scope = 'global_action' THEN
            v_scope_key := p_module || '.' || p_action;
        END IF;

        IF v_scope_key IS NOT NULL THEN
            -- Используем перегрузку pg_advisory_xact_lock(int, int) для 64-битного пространства блокировок,
            -- чтобы исключить коллизии хэшей под высокой нагрузкой (Birthday paradox).
            PERFORM pg_advisory_xact_lock(
                hashtext(v_scope_key || ':' || v_request_id),
                hashtext(v_request_id || ':' || v_scope_key)
            );

            SELECT * INTO v_existing
              FROM idempotency.records r
             WHERE r.scope_key = v_scope_key
               AND r.idempotency_key = v_request_id;

            IF v_existing.idempotency_key IS NOT NULL THEN
                IF v_existing.payload_hash != v_payload_hash THEN
                    RETURN jsonb_build_object(
                        'status', 'error',
                        'code', 'idempotency.conflict',
                        'message', 'same idempotency key with different payload'
                    );
                END IF;

                -- Replay: return stored response envelope as-is (original correlationId)
                INSERT INTO catalog.action_dispatches
                    (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome)
                VALUES
                    (v_correlation::uuid, v_request_id, p_module, p_action, v_rec.version,
                     v_principal, v_payload_hash, 'OK', v_existing.response_json->>'outcome');

                RETURN v_existing.response_json;
            END IF;
        END IF;
    END IF;

    -- Call target function dynamically
    EXECUTE format('SELECT %I.%I($1, $2)', v_rec.target_schema, v_rec.target_function)
       INTO v_target_result
      USING p_context, p_payload;

    -- Target functions must return a strict envelope of their own.
    IF COALESCE(jsonb_typeof(v_target_result), '') <> 'object' THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.contract_violation',
            'message', 'target returned a non-object envelope'
        );
    END IF;

    v_target_status := v_target_result->>'status';
    IF v_target_status IS NULL OR v_target_status NOT IN ('ok', 'error') THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.contract_violation',
            'message', 'target returned an invalid status'
        );
    END IF;

    -- Extract outcome from target result
    v_outcome := v_target_result->>'outcome';

    -- Check if target returned an error
    IF v_target_status = 'error' THEN
        IF jsonb_typeof(v_target_result->'code') <> 'string'
           OR jsonb_typeof(v_target_result->'message') <> 'string'
           OR NULLIF(v_target_result->>'code', '') IS NULL
           OR NULLIF(v_target_result->>'message', '') IS NULL THEN
            RETURN jsonb_build_object(
                'status', 'error',
                'code', 'action.contract_violation',
                'message', 'target returned an invalid error envelope'
            );
        END IF;
        RETURN v_target_result;
    END IF;

    -- Validate outcome against manifest
    IF v_outcome IS NULL OR NOT (v_rec.outcomes @> jsonb_build_array(v_outcome)) THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'action.contract_violation',
            'message', format('unexpected outcome: %s', COALESCE(v_outcome, 'NULL'))
        );
    END IF;

    -- Build final envelope
    v_result := jsonb_build_object(
        'status', 'ok',
        'outcome', v_outcome,
        'result', v_target_result->'result',
        'meta', jsonb_build_object(
            'correlationId', v_correlation,
            'actionVersion', v_rec.version
        )
    );

    -- Success: log dispatch
    INSERT INTO catalog.action_dispatches
        (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome)
    VALUES
        (v_correlation::uuid, v_request_id, p_module, p_action, v_rec.version,
         v_principal, v_payload_hash, 'OK', v_outcome);

    -- Store idempotency record if applicable
    IF v_scope_key IS NOT NULL AND v_request_id IS NOT NULL AND v_request_id != '' THEN
        INSERT INTO idempotency.records (idempotency_key, scope_key, payload_hash, response_json)
        VALUES (v_request_id, v_scope_key, v_payload_hash, v_result)
        ON CONFLICT (scope_key, idempotency_key) DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;

ALTER FUNCTION api.invoke(text, text, integer, jsonb, jsonb) OWNER TO course_owner;
GRANT EXECUTE ON FUNCTION api.invoke(text, text, integer, jsonb, jsonb) TO course_runtime;

-- ============================================================
-- 3. BUSINESS FUNCTION: payment.request_v1
-- ============================================================

CREATE OR REPLACE FUNCTION payment.request_v1(
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payment, idempotency, public
AS $$
DECLARE
    v_request_id     text;
    v_payload_hash   text;
    v_op_id          uuid;
BEGIN
    v_request_id   := NULLIF(p_context->>'requestId', '');
    IF v_request_id IS NULL THEN
        v_request_id := gen_random_uuid()::text;
    END IF;
    v_payload_hash := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');

    -- Create operation
    INSERT INTO payment.operations (principal, request_id, operation_kind, amount, currency, status)
    VALUES (
        p_context->>'principal',
        v_request_id,
        p_payload->>'operationKind',
        (p_payload->>'amount')::numeric(18,2),
        p_payload->>'currency',
        'CREATED'
    )
    RETURNING operation_id INTO v_op_id;

    -- Create initial event
    INSERT INTO payment.operation_events (operation_id, event_type, payload_hash)
    VALUES (v_op_id, 'OPERATION_CREATED', v_payload_hash);

    -- Return business result
    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'CREATED',
        'result', jsonb_build_object(
            'operationId', v_op_id,
            'requestId', v_request_id,
            'operationKind', p_payload->>'operationKind',
            'amount', p_payload->>'amount',
            'currency', p_payload->>'currency',
            'status', 'CREATED'
        )
    );
END;
$$;

ALTER FUNCTION payment.request_v1(jsonb, jsonb) OWNER TO course_owner;

-- ============================================================
-- 4. BUSINESS FUNCTION: operation.get_v1
-- ============================================================

CREATE OR REPLACE FUNCTION operation.get_v1(
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, payment, public
AS $$
DECLARE
    v_op payment.operations%ROWTYPE;
BEGIN
    SELECT * INTO v_op
      FROM payment.operations o
     WHERE o.operation_id = (p_payload->>'operationId')::uuid;

    IF v_op.operation_id IS NULL THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'code', 'operation.not_found',
            'message', 'operation not found'
        );
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', 'FOUND',
        'result', jsonb_build_object(
            'operationId', v_op.operation_id,
            'requestId', v_op.request_id,
            'operationKind', v_op.operation_kind,
            'amount', v_op.amount::text,
            'currency', v_op.currency,
            'status', v_op.status
        )
    );
END;
$$;

ALTER FUNCTION operation.get_v1(jsonb, jsonb) OWNER TO course_owner;

-- ============================================================
-- 5. REGISTER BUILT-IN ACTIONS
-- ============================================================

INSERT INTO catalog.actions
    (module, action, version, manifest_json, manifest_hash,
     target_schema, target_function, http_method, outcomes,
     required_policy, idempotency_mode, idempotency_scope,
     timeout_ms, enabled, is_default)
VALUES
(
    'payment',
    'request',
    1,
    $${
  "contract_version": "course-1",
  "module": "payment",
  "action": "request",
  "version": 1,
  "http_method": "POST",
  "target_schema": "payment",
  "target_function": "request_v1",
  "request_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:payment-request-payload",
    "type": "object",
    "additionalProperties": false,
    "required": ["operationKind", "amount", "currency"],
    "properties": {
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {
        "const": "RUB"
      }
    }
  },
  "response_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-result",
    "type": "object",
    "additionalProperties": false,
    "required": [
      "operationId",
      "requestId",
      "operationKind",
      "amount",
      "currency",
      "status"
    ],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"},
      "requestId": {"type": "string", "minLength": 1, "maxLength": 128},
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {"const": "RUB"},
      "status": {"enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"]}
    }
  },
  "outcomes": ["CREATED"],
  "required_policy": ["payment:write"],
  "idempotency_mode": "required",
  "idempotency_scope": "principal_action",
  "timeout_ms": 5000,
  "enabled": true,
  "is_default": true
}$$::jsonb,
    encode(sha256(convert_to($${
  "contract_version": "course-1",
  "module": "payment",
  "action": "request",
  "version": 1,
  "http_method": "POST",
  "target_schema": "payment",
  "target_function": "request_v1",
  "request_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:payment-request-payload",
    "type": "object",
    "additionalProperties": false,
    "required": ["operationKind", "amount", "currency"],
    "properties": {
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {
        "const": "RUB"
      }
    }
  },
  "response_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-result",
    "type": "object",
    "additionalProperties": false,
    "required": [
      "operationId",
      "requestId",
      "operationKind",
      "amount",
      "currency",
      "status"
    ],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"},
      "requestId": {"type": "string", "minLength": 1, "maxLength": 128},
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {"const": "RUB"},
      "status": {"enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"]}
    }
  },
  "outcomes": ["CREATED"],
  "required_policy": ["payment:write"],
  "idempotency_mode": "required",
  "idempotency_scope": "principal_action",
  "timeout_ms": 5000,
  "enabled": true,
  "is_default": true
}$$, 'UTF8')), 'hex'),
    'payment',
    'request_v1',
    'POST',
    '["CREATED"]'::jsonb,
    '["payment:write"]'::jsonb,
    'required',
    'principal_action',
    5000,
    true,
    true
),
(
    'operation',
    'get',
    1,
    $${
  "contract_version": "course-1",
  "module": "operation",
  "action": "get",
  "version": 1,
  "http_method": "POST",
  "target_schema": "operation",
  "target_function": "get_v1",
  "request_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-get-payload",
    "type": "object",
    "additionalProperties": false,
    "required": ["operationId"],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"}
    }
  },
  "response_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-result",
    "type": "object",
    "additionalProperties": false,
    "required": [
      "operationId",
      "requestId",
      "operationKind",
      "amount",
      "currency",
      "status"
    ],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"},
      "requestId": {"type": "string", "minLength": 1, "maxLength": 128},
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {"const": "RUB"},
      "status": {"enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"]}
    }
  },
  "outcomes": ["FOUND"],
  "required_policy": ["payment:read"],
  "idempotency_mode": "none",
  "idempotency_scope": "none",
  "timeout_ms": 5000,
  "enabled": true,
  "is_default": true
}$$::jsonb,
    encode(sha256(convert_to($${
  "contract_version": "course-1",
  "module": "operation",
  "action": "get",
  "version": 1,
  "http_method": "POST",
  "target_schema": "operation",
  "target_function": "get_v1",
  "request_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-get-payload",
    "type": "object",
    "additionalProperties": false,
    "required": ["operationId"],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"}
    }
  },
  "response_schema": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "urn:course:course-1:operation-result",
    "type": "object",
    "additionalProperties": false,
    "required": [
      "operationId",
      "requestId",
      "operationKind",
      "amount",
      "currency",
      "status"
    ],
    "properties": {
      "operationId": {"type": "string", "format": "uuid"},
      "requestId": {"type": "string", "minLength": 1, "maxLength": 128},
      "operationKind": {
        "enum": ["PAYMENT_EXECUTION", "PAYMENT_APPROVAL"]
      },
      "amount": {
        "type": "string",
        "pattern": "^(?:0\\.0[1-9]|0\\.[1-9][0-9]?|[1-9][0-9]{0,15}(?:\\.[0-9]{1,2})?)$"
      },
      "currency": {"const": "RUB"},
      "status": {"enum": ["CREATED", "PROCESSING", "COMPLETED", "REJECTED"]}
    }
  },
  "outcomes": ["FOUND"],
  "required_policy": ["payment:read"],
  "idempotency_mode": "none",
  "idempotency_scope": "none",
  "timeout_ms": 5000,
  "enabled": true,
  "is_default": true
}$$, 'UTF8')), 'hex'),
    'operation',
    'get_v1',
    'POST',
    '["FOUND"]'::jsonb,
    '["payment:read"]'::jsonb,
    'none',
    'none',
    5000,
    true,
    true
)
ON CONFLICT (module, action, version) DO NOTHING;
