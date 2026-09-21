-- Forward-only fixes for replay boundary and signed bodies.
ALTER FUNCTION catalog.trg_set_object_owner() SECURITY INVOKER;
ALTER FUNCTION catalog.trg_set_object_owner() OWNER TO course_owner;
REVOKE EXECUTE ON FUNCTION catalog.trg_set_object_owner() FROM PUBLIC;
ALTER TABLE idempotency.records ADD COLUMN signature_version integer;

CREATE OR REPLACE FUNCTION api.invoke(
    p_module  text,
    p_action  text,
    p_version integer,
    p_context jsonb,
    p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, catalog, idempotency, pg_temp
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
    v_payload_hash := CASE WHEN p_context#>>'{transport,signatureVerified}' = 'true' THEN p_context->>'payloadHash' ELSE encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex') END;

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
          AND NOT p.proretset
          AND p.pronargs = 2
          AND (p.proargmodes IS NULL OR p.proargmodes = ARRAY['i', 'i']::"char"[])
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
            -- Используем перегрузку pg_advisory_xact_lock(int, int) для 64-битного пространства блокировок.
            -- Раздельное хеширование scope_key и request_id даёт лучшее распределение бит.
            PERFORM pg_advisory_xact_lock(
                hashtext(v_scope_key),
                hashtext(v_request_id)
            );

            SELECT * INTO v_existing
              FROM idempotency.records r
             WHERE r.scope_key = v_scope_key
               AND r.idempotency_key = v_request_id;

            IF v_existing.idempotency_key IS NOT NULL THEN
            IF v_existing.signature_version IS NOT NULL AND
               (p_context#>>'{transport,signatureVerified}') IS DISTINCT FROM 'true' THEN
                RETURN jsonb_build_object('status','error','code','receipt.signature_required','message','signature required');
            END IF;

                IF v_existing.payload_hash != v_payload_hash THEN
                    RETURN jsonb_build_object(
                        'status', 'error',
                        'code', 'idempotency.conflict',
                        'message', 'same idempotency key with different payload'
                    );
                END IF;

                -- Explicit mismatch
                IF p_version IS NOT NULL AND p_version != v_existing.executed_version THEN
                    RETURN jsonb_build_object(
                        'status', 'error',
                        'code', 'idempotency.conflict',
                        'message', 'same idempotency key with different explicit version'
                    );
                END IF;

                -- Replay: return stored response envelope as-is
                INSERT INTO catalog.action_dispatches
                    (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome, replay_marker)
                VALUES
                    (v_correlation::uuid, v_request_id, p_module, p_action, v_existing.executed_version,
                     v_principal, v_payload_hash, 'OK', v_existing.response_json->>'outcome', true);

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
        (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome, replay_marker)
    VALUES
        (v_correlation::uuid, v_request_id, p_module, p_action, v_rec.version,
         v_principal, v_payload_hash, 'OK', v_outcome, false);

    -- Store idempotency record if applicable
    IF v_scope_key IS NOT NULL AND v_request_id IS NOT NULL AND v_request_id != '' THEN
        INSERT INTO idempotency.records (idempotency_key, scope_key, payload_hash, response_json, executed_version, manifest_hash, signature_version)
        VALUES (v_request_id, v_scope_key, v_payload_hash, v_result, v_rec.version, v_rec.manifest_hash, (p_context#>>'{transport,signatureVersion}')::integer)
        ON CONFLICT (scope_key, idempotency_key) DO NOTHING;
    END IF;

    RETURN v_result;
END;
$$;

ALTER FUNCTION api.invoke(text, text, integer, jsonb, jsonb) OWNER TO course_owner;
REVOKE EXECUTE ON FUNCTION api.invoke(text, text, integer, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.invoke(text, text, integer, jsonb, jsonb) TO course_runtime;

ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;


CREATE OR REPLACE FUNCTION api.check_replay(
    p_module text, p_action text, p_context jsonb, p_payload jsonb
) RETURNS jsonb AS $$
DECLARE
    v_rec catalog.actions%ROWTYPE;
    v_scope_key text;
    v_request_id text := p_context->>'requestId';
    v_principal text := p_context->>'principal';
    v_consumer text := p_context->>'consumer';
    v_correlation text := p_context->>'correlationId';
    v_existing idempotency.records%ROWTYPE;
    v_payload_hash text;
    v_start_ts timestamptz := clock_timestamp();
BEGIN
    IF v_request_id IS NULL OR v_request_id = '' THEN
        RETURN NULL;
    END IF;
    
    SELECT * INTO v_rec FROM catalog.actions
    WHERE module = p_module AND action = p_action AND is_default = true AND enabled = true
    LIMIT 1;

    IF NOT FOUND THEN
        SELECT * INTO v_rec FROM catalog.actions
        WHERE module = p_module AND action = p_action
        ORDER BY version DESC
        LIMIT 1;
    END IF;

    IF v_rec.module IS NULL THEN
        RETURN NULL;
    END IF;

    IF v_rec.idempotency_scope = 'principal_action' THEN
        v_scope_key := v_principal || ':' || p_module || '.' || p_action;
    ELSIF v_rec.idempotency_scope = 'consumer_action' THEN
        v_scope_key := v_consumer || ':' || p_module || '.' || p_action;
    ELSIF v_rec.idempotency_scope = 'global_action' THEN
        v_scope_key := p_module || '.' || p_action;
    ELSE
        v_scope_key := v_principal || ':' || p_module || '.' || p_action;
    END IF;

    IF v_scope_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(v_scope_key), hashtext(v_request_id));

        SELECT * INTO v_existing FROM idempotency.records r
        WHERE r.idempotency_key = v_request_id
          AND r.scope_key = v_scope_key
        ORDER BY r.created_at DESC
        LIMIT 1;
        
        IF v_existing.idempotency_key IS NOT NULL THEN
            IF v_existing.signature_version IS NOT NULL AND
               (p_context#>>'{transport,signatureVerified}') IS DISTINCT FROM 'true' THEN
                RETURN jsonb_build_object('status','error','code','receipt.signature_required','message','signature required');
            END IF;

            v_payload_hash := CASE WHEN p_context#>>'{transport,signatureVerified}' = 'true' THEN p_context->>'payloadHash' ELSE encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex') END;
            IF v_existing.payload_hash != v_payload_hash THEN
                RETURN jsonb_build_object(
                    'status', 'error',
                    'code', 'idempotency.conflict',
                    'message', 'same idempotency key with different payload'
                );
            END IF;

            -- Audit dispatch for replay
            INSERT INTO catalog.action_dispatches
                (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome, duration_ms, replay_marker)
            VALUES
                (COALESCE(NULLIF(v_correlation, '')::uuid, gen_random_uuid()),
                 v_request_id, p_module, p_action, v_existing.executed_version,
                 v_principal, v_payload_hash, 'OK', v_existing.response_json->>'outcome',
                 ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_start_ts)) * 1000)::integer, true);

            RETURN v_existing.response_json;
        END IF;
    END IF;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, api, catalog, idempotency, pg_temp;
GRANT EXECUTE ON FUNCTION api.check_replay(text, text, jsonb, jsonb) TO course_runtime;
