-- 003_catalog_routines.sql
ALTER TABLE catalog.action_dispatches ADD COLUMN error_code text;
ALTER TABLE catalog.action_dispatches ADD COLUMN duration_ms integer;
ALTER TABLE catalog.action_dispatches ADD COLUMN replay_marker boolean NOT NULL DEFAULT false;

DROP VIEW IF EXISTS autocheck.action_dispatches;

CREATE VIEW autocheck.action_dispatches AS
    SELECT correlation_id, request_id, module, action, version,
           principal, payload_hash, status, outcome, occurred_at
      FROM catalog.action_dispatches;

ALTER VIEW autocheck.action_dispatches OWNER TO course_owner;
GRANT SELECT ON autocheck.action_dispatches TO course_runtime, course_publication;
-- Removed DML grants for course_runtime on autocheck schema

CREATE OR REPLACE FUNCTION catalog.check_action_immutability()
RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'actions cannot be deleted' USING ERRCODE = 'data_exception';
    END IF;

    IF OLD.module <> NEW.module OR OLD.action <> NEW.action OR OLD.version <> NEW.version OR
       OLD.manifest_json <> NEW.manifest_json OR OLD.manifest_hash <> NEW.manifest_hash OR
       OLD.target_schema <> NEW.target_schema OR OLD.target_function <> NEW.target_function OR
       OLD.outcomes <> NEW.outcomes OR OLD.http_method <> NEW.http_method OR
       OLD.required_policy <> NEW.required_policy OR OLD.idempotency_mode <> NEW.idempotency_mode OR
       OLD.idempotency_scope <> NEW.idempotency_scope OR OLD.timeout_ms <> NEW.timeout_ms THEN
        RAISE EXCEPTION 'action signature and payload are immutable' USING ERRCODE = 'data_exception';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_action_immutability
BEFORE UPDATE OR DELETE ON catalog.actions
FOR EACH ROW EXECUTE FUNCTION catalog.check_action_immutability();

-- Publish
CREATE OR REPLACE FUNCTION catalog.publish_action(
    p_module text, p_action text, p_version int,
    p_manifest_json jsonb, p_manifest_hash text,
    p_target_schema text, p_target_function text,
    p_http_method text, p_outcomes jsonb,
    p_required_policy jsonb, p_idempotency_mode text,
    p_idempotency_scope text, p_timeout_ms int
) RETURNS void AS $$
BEGIN
    INSERT INTO catalog.actions (
        module, action, version,
        manifest_json, manifest_hash,
        target_schema, target_function, http_method,
        outcomes, required_policy, idempotency_mode,
        idempotency_scope, timeout_ms, enabled, is_default
    ) VALUES (
        p_module, p_action, p_version,
        p_manifest_json, p_manifest_hash,
        p_target_schema, p_target_function, p_http_method,
        p_outcomes, p_required_policy, p_idempotency_mode,
        p_idempotency_scope, p_timeout_ms,
        COALESCE((p_manifest_json->>'enabled')::boolean, false),
        COALESCE((p_manifest_json->>'is_default')::boolean, false)
    ) ON CONFLICT (module, action, version) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;

-- Activate
CREATE OR REPLACE FUNCTION catalog.activate_action(
    p_module text, p_action text, p_version int
) RETURNS void AS $$
BEGIN
    PERFORM 1 FROM catalog.actions
    WHERE module = p_module AND action = p_action AND version = p_version;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'action.not_found';
    END IF;

    UPDATE catalog.actions SET is_default = false
    WHERE module = p_module AND action = p_action AND is_default = true;

    UPDATE catalog.actions SET enabled = true, is_default = true
    WHERE module = p_module AND action = p_action AND version = p_version;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;

-- Disable
CREATE OR REPLACE FUNCTION catalog.disable_action(
    p_module text, p_action text, p_version int, p_replacement int DEFAULT NULL
) RETURNS void AS $$
DECLARE
    v_was_default boolean;
    v_was_enabled boolean;
    v_rep_enabled boolean;
BEGIN
    SELECT enabled, is_default INTO v_was_enabled, v_was_default
    FROM catalog.actions
    WHERE module = p_module AND action = p_action AND version = p_version;

    IF v_was_enabled IS NULL THEN
        RAISE EXCEPTION 'action.not_found';
    END IF;

    IF v_was_default AND p_replacement IS NULL THEN
        IF EXISTS (
            SELECT 1 FROM catalog.actions
            WHERE module = p_module AND action = p_action AND version != p_version AND enabled = true
        ) THEN
            RAISE EXCEPTION 'manifest.conflict';
        END IF;
    END IF;

    IF p_replacement IS NOT NULL THEN
        IF NOT v_was_default THEN
            RAISE EXCEPTION 'request.invalid';
        END IF;

        IF p_replacement = p_version THEN
            RAISE EXCEPTION 'request.invalid';
        END IF;

        SELECT enabled INTO v_rep_enabled FROM catalog.actions
        WHERE module = p_module AND action = p_action AND version = p_replacement;

        IF v_rep_enabled IS NULL THEN
            RAISE EXCEPTION 'action.not_found';
        END IF;

        IF NOT v_rep_enabled THEN
            RAISE EXCEPTION 'request.invalid';
        END IF;
    END IF;

    IF NOT v_was_enabled THEN
        RETURN;
    END IF;

    UPDATE catalog.actions SET enabled = false, is_default = false
    WHERE module = p_module AND action = p_action AND version = p_version;

    IF p_replacement IS NOT NULL THEN
        UPDATE catalog.actions SET is_default = false
        WHERE module = p_module AND action = p_action;

        UPDATE catalog.actions SET enabled = true, is_default = true
        WHERE module = p_module AND action = p_action AND version = p_replacement;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA catalog TO course_publication;

-- Helper to check replay before schema validation
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
          AND r.scope_key IN (
              v_principal || ':' || p_module || '.' || p_action,
              v_consumer || ':' || p_module || '.' || p_action,
              p_module || '.' || p_action
          )
        ORDER BY r.created_at DESC
        LIMIT 1;
        
        IF v_existing.idempotency_key IS NOT NULL THEN
            v_payload_hash := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex');
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
