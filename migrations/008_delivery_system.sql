-- Durable delivery and domain actions on the generic workflow runtime.
CREATE SCHEMA receipt AUTHORIZATION course_owner;
CREATE SCHEMA delivery AUTHORIZATION course_owner;
SET ROLE course_owner;
REVOKE EXECUTE ON FUNCTION payment.trg_events_append_only() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION payment.trg_operations_immutability() FROM PUBLIC;

CREATE TABLE payment.flow_bindings (
    operation_kind text PRIMARY KEY,
    flow_name text NOT NULL REFERENCES workflow.flow_definitions
);

CREATE TABLE delivery.external_requests (
    external_request_id text PRIMARY KEY,
    operation_id uuid NOT NULL UNIQUE REFERENCES payment.operations,
    process_id uuid NOT NULL REFERENCES workflow.process_instances,
    correlation_id uuid NOT NULL,
    state text NOT NULL DEFAULT 'CREATED' CHECK (state IN ('CREATED', 'SENT', 'CONFIRMED')),
    payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE delivery.receipts (
    message_id text PRIMARY KEY,
    external_request_id text NOT NULL UNIQUE REFERENCES delivery.external_requests,
    message_version integer NOT NULL CHECK (message_version = 1),
    outcome text NOT NULL CHECK (outcome IN ('COMPLETED', 'REJECTED')),
    signature_valid boolean NOT NULL CHECK (signature_valid),
    body_hash text NOT NULL CHECK (body_hash ~ '^[0-9a-f]{64}$'),
    occurred_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    applied_at timestamptz
);
CREATE TABLE delivery.outbox (
    outbox_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_request_id text NOT NULL UNIQUE REFERENCES delivery.external_requests,
    state text NOT NULL DEFAULT 'PENDING' CHECK (state IN ('PENDING', 'LEASED', 'RETRY_WAIT', 'DELIVERED', 'DEAD', 'CONFIRMED')),
    attempt_count integer NOT NULL DEFAULT 0,
    lease_version bigint NOT NULL DEFAULT 0,
    lease_owner text,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz
);
CREATE TABLE delivery.inbox (
    message_id text PRIMARY KEY REFERENCES delivery.receipts,
    body_hash text NOT NULL CHECK (body_hash ~ '^[0-9a-f]{64}$'),
    state text NOT NULL DEFAULT 'RECEIVED' CHECK (state IN ('RECEIVED', 'APPLIED', 'CONFLICT')),
    received_at timestamptz NOT NULL DEFAULT now(),
    applied_at timestamptz
);
CREATE TABLE delivery.decisions (
    decision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id uuid NOT NULL UNIQUE REFERENCES workflow.process_instances,
    step_instance_id uuid NOT NULL REFERENCES workflow.step_instances,
    source text NOT NULL CHECK (source IN ('LIMIT_RULE', 'MANUAL')),
    principal text NOT NULL,
    reason_hash text CHECK (reason_hash ~ '^[0-9a-f]{64}$'),
    outcome text NOT NULL CHECK (outcome IN ('APPROVED', 'REJECTED')),
    rule_version text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((source = 'LIMIT_RULE' AND rule_version = 'course-limit-v1') OR
           (source = 'MANUAL' AND reason_hash IS NOT NULL))
);
CREATE TRIGGER decisions_append_only BEFORE UPDATE OR DELETE ON delivery.decisions
FOR EACH ROW EXECUTE FUNCTION payment.trg_events_append_only();

CREATE FUNCTION payment.submit_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_op payment.operations%ROWTYPE;
    v_process workflow.process_instances%ROWTYPE;
    v_started jsonb;
    v_flow text;
BEGIN
    SELECT * INTO v_op FROM payment.operations
    WHERE operation_id = (p_payload->>'operationId')::uuid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status','error','code','operation.not_found','message','operation not found');
    END IF;
    IF v_op.principal <> p_context->>'principal' THEN
        RETURN jsonb_build_object('status','error','code','access.denied','message','access denied');
    END IF;
    IF v_op.process_id IS NULL THEN
        SELECT flow_name INTO v_flow FROM payment.flow_bindings WHERE operation_kind=v_op.operation_kind;
        v_started := workflow.start_process(v_flow, v_op.operation_id::text,
                                            jsonb_build_object('operationId',v_op.operation_id));
        IF v_started->>'status' <> 'ok' THEN RETURN v_started; END IF;
        v_op.process_id := (v_started->>'processId')::uuid;
        UPDATE payment.operations SET status='PROCESSING', process_id=v_op.process_id, updated_at=now()
        WHERE operation_id=v_op.operation_id;
        INSERT INTO payment.operation_events(operation_id,event_type,payload_hash)
        VALUES(v_op.operation_id,'OperationSubmitted',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    SELECT * INTO v_process FROM workflow.process_instances WHERE process_id=v_op.process_id;
    RETURN jsonb_build_object('status','ok','outcome','SUBMITTED','result',jsonb_build_object(
        'operationId',v_op.operation_id,'processId',v_process.process_id,'flowName',v_process.flow_name,
        'flowVersion',v_process.flow_version,'status','PROCESSING'));
END;
$$;

CREATE FUNCTION operation.events_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_events jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid) THEN
        RETURN jsonb_build_object('status','error','code','operation.not_found','message','operation not found');
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('eventId',event_id,'eventType',event_type,
             'occurredAt',occurred_at,'payloadHash',payload_hash) ORDER BY occurred_at,event_id),'[]'::jsonb)
    INTO v_events FROM payment.operation_events WHERE operation_id=(p_payload->>'operationId')::uuid;
    RETURN jsonb_build_object('status','ok','outcome','FOUND','result',jsonb_build_object('events',v_events));
END;
$$;

CREATE FUNCTION payment.validate_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid
                   AND process_id=(p_context->>'processId')::uuid AND status='PROCESSING') THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','invalid operation');
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','VALID','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.prepare_external_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_op payment.operations%ROWTYPE;
    v_external text;
    v_body text;
BEGIN
    SELECT * INTO v_op FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid FOR UPDATE;
    IF v_op.operation_kind <> 'PAYMENT_EXECUTION' OR v_op.status <> 'PROCESSING'
       OR v_op.process_id IS DISTINCT FROM (p_context->>'processId')::uuid THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','invalid operation');
    END IF;
    SELECT external_request_id INTO v_external FROM delivery.external_requests WHERE operation_id=v_op.operation_id;
    IF v_external IS NULL THEN
        v_external := gen_random_uuid()::text;
        v_body := '{"operationId":' || to_json(v_external)::text || ',"amount":' || to_json(v_op.amount::text)::text
                  || ',"currency":' || to_json(v_op.currency)::text || '}';
        INSERT INTO delivery.external_requests(external_request_id,operation_id,process_id,correlation_id,payload_hash)
        VALUES(v_external,v_op.operation_id,v_op.process_id,(p_context->>'correlationId')::uuid,
               encode(sha256(convert_to(v_body,'UTF8')),'hex'));
        INSERT INTO delivery.outbox(external_request_id) VALUES(v_external);
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','PREPARED','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.apply_receipt_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_outcome text;
BEGIN
    SELECT r.outcome INTO v_outcome FROM delivery.receipts r
    JOIN delivery.external_requests e USING(external_request_id)
    JOIN delivery.inbox i USING(message_id)
    WHERE e.operation_id=(p_payload->>'operationId')::uuid
      AND e.process_id=(p_context->>'processId')::uuid AND i.state='APPLIED';
    IF v_outcome IS NULL THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','receipt not applied');
    END IF;
    RETURN jsonb_build_object('status','ok','outcome',v_outcome,'result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.complete_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_op payment.operations%ROWTYPE;
BEGIN
    SELECT * INTO v_op FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid FOR UPDATE;
    IF v_op.process_id IS DISTINCT FROM (p_context->>'processId')::uuid OR NOT (EXISTS(SELECT 1 FROM delivery.receipts r JOIN delivery.external_requests e USING(external_request_id)
        JOIN delivery.inbox i USING(message_id) WHERE e.operation_id=v_op.operation_id AND i.state='APPLIED' AND r.outcome='COMPLETED')) THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','final evidence required');
    END IF;
    UPDATE payment.operations SET status='COMPLETED',updated_at=now()
    WHERE operation_id=v_op.operation_id AND status='PROCESSING';
    IF FOUND THEN
        INSERT INTO payment.operation_events(operation_id,event_type,payload_hash)
        VALUES(v_op.operation_id,'OperationCompleted',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','COMPLETED','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.reject_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_op payment.operations%ROWTYPE;
BEGIN
    SELECT * INTO v_op FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid FOR UPDATE;
    IF v_op.process_id IS DISTINCT FROM (p_context->>'processId')::uuid OR NOT ((EXISTS(SELECT 1 FROM delivery.receipts r JOIN delivery.external_requests e USING(external_request_id)
        JOIN delivery.inbox i USING(message_id) WHERE e.operation_id=v_op.operation_id AND i.state='APPLIED' AND r.outcome='REJECTED') OR EXISTS(SELECT 1 FROM delivery.decisions WHERE process_id=v_op.process_id AND outcome='REJECTED'))) THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','final evidence required');
    END IF;
    UPDATE payment.operations SET status='REJECTED',updated_at=now()
    WHERE operation_id=v_op.operation_id AND status='PROCESSING';
    IF FOUND THEN
        INSERT INTO payment.operation_events(operation_id,event_type,payload_hash)
        VALUES(v_op.operation_id,'OperationRejected',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','REJECTED','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.approve_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_op payment.operations%ROWTYPE;
BEGIN
    SELECT * INTO v_op FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid FOR UPDATE;
    IF v_op.process_id IS DISTINCT FROM (p_context->>'processId')::uuid OR NOT (EXISTS(SELECT 1 FROM delivery.decisions WHERE process_id=v_op.process_id AND outcome='APPROVED')) THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','final evidence required');
    END IF;
    UPDATE payment.operations SET status='COMPLETED',updated_at=now()
    WHERE operation_id=v_op.operation_id AND status='PROCESSING';
    IF FOUND THEN
        INSERT INTO payment.operation_events(operation_id,event_type,payload_hash)
        VALUES(v_op.operation_id,'OperationCompleted',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','COMPLETED','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION payment.check_limit_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_op payment.operations%ROWTYPE; v_step uuid;
BEGIN
    SELECT * INTO v_op FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid;
    SELECT step_instance_id INTO v_step FROM workflow.jobs WHERE execution_id=(p_context->>'executionId')::uuid
       AND process_id=v_op.process_id;
    IF v_op.operation_kind <> 'PAYMENT_APPROVAL' OR v_step IS NULL THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','invalid operation');
    END IF;
    IF v_op.amount <= 100000.00 AND v_op.currency='RUB' THEN
        INSERT INTO delivery.decisions(process_id,step_instance_id,source,principal,outcome,rule_version)
        VALUES(v_op.process_id,v_step,'LIMIT_RULE',p_context->>'principal','APPROVED','course-limit-v1');
        RETURN jsonb_build_object('status','ok','outcome','WITHIN_LIMIT','result','{}'::jsonb);
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','REVIEW_REQUIRED','result','{}'::jsonb);
END;
$$;

CREATE FUNCTION receipt.accept_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_id text := p_payload->>'messageId';
    v_external text := p_payload->>'externalRequestId';
    v_hash text := p_context->>'payloadHash';
    v_existing delivery.receipts%ROWTYPE;
    v_state text;
BEGIN
    IF (p_context#>>'{transport,signatureVerified}') IS DISTINCT FROM 'true'
       OR (p_context#>>'{transport,signatureVersion}') IS DISTINCT FROM '1' THEN
        RETURN jsonb_build_object('status','error','code','receipt.signature_required','message','signature required');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_id,0));
    PERFORM 1 FROM delivery.external_requests WHERE external_request_id=v_external FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status','error','code','receipt.external_request_not_found','message','external request not found');
    END IF;
    SELECT * INTO v_existing FROM delivery.receipts WHERE message_id=v_id OR external_request_id=v_external;
    IF FOUND THEN
        IF v_existing.message_id <> v_id OR v_existing.body_hash <> v_hash THEN
            RETURN jsonb_build_object('status','error','code','idempotency.conflict','message','receipt conflict');
        END IF;
        SELECT state INTO v_state FROM delivery.inbox WHERE message_id=v_id;
        RETURN jsonb_build_object('status','ok','outcome','DUPLICATE','result',jsonb_build_object(
            'messageId',v_id,'externalRequestId',v_external,'state',v_state));
    END IF;
    INSERT INTO delivery.receipts(message_id,external_request_id,message_version,outcome,signature_valid,body_hash,occurred_at)
    VALUES(v_id,v_external,1,p_payload->>'outcome',true,v_hash,(p_payload->>'occurredAt')::timestamptz);
    INSERT INTO delivery.inbox(message_id,body_hash) VALUES(v_id,v_hash);
    UPDATE delivery.external_requests SET state='CONFIRMED' WHERE external_request_id=v_external;
    UPDATE delivery.outbox SET state='CONFIRMED' WHERE external_request_id=v_external;
    RETURN jsonb_build_object('status','ok','outcome','RECEIVED','result',jsonb_build_object(
        'messageId',v_id,'externalRequestId',v_external,'state','RECEIVED'));
END;
$$;

CREATE FUNCTION workflow.manual_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_process workflow.process_instances%ROWTYPE;
    v_step workflow.step_instances%ROWTYPE;
    v_map jsonb;
    v_next text;
    v_decision text := p_payload->>'decision';
    v_id uuid;
BEGIN
    SELECT * INTO v_process FROM workflow.process_instances
    WHERE process_id=(p_payload->>'processId')::uuid FOR UPDATE;
    SELECT * INTO v_step FROM workflow.step_instances
    WHERE step_instance_id=(p_payload->>'stepInstanceId')::uuid AND process_id=v_process.process_id FOR UPDATE;
    IF v_process.state IS DISTINCT FROM 'WAITING_MANUAL' OR v_step.state IS DISTINCT FROM 'WAITING'
       OR v_step.step_type IS DISTINCT FROM 'MANUAL' THEN
        RETURN jsonb_build_object('status','error','code','workflow.decision_conflict','message','manual step is not waiting');
    END IF;
    SELECT map_json INTO v_map FROM workflow.flow_versions
    WHERE flow_name=v_process.flow_name AND flow_version=v_process.flow_version;
    SELECT t->>'to' INTO v_next FROM jsonb_array_elements(v_map->'transitions') t
    WHERE t->>'from'=v_step.step_key AND t->>'outcome'=v_decision;
    IF v_next IS NULL THEN
        RETURN jsonb_build_object('status','error','code','payload.invalid','message','invalid decision');
    END IF;
    INSERT INTO delivery.decisions(process_id,step_instance_id,source,principal,reason_hash,outcome)
    VALUES(v_process.process_id,v_step.step_instance_id,'MANUAL',p_context->>'principal',
        encode(sha256(convert_to(p_payload->>'reason','UTF8')),'hex'),v_decision) RETURNING decision_id INTO v_id;
    UPDATE workflow.step_instances SET state='COMPLETED',outcome=v_decision,completed_at=now()
    WHERE step_instance_id=v_step.step_instance_id;
    INSERT INTO workflow.events(process_id,step_instance_id,event_type,detail_json)
    VALUES(v_process.process_id,v_step.step_instance_id,'ManualDecision',jsonb_build_object('decisionId',v_id,'outcome',v_decision));
    INSERT INTO workflow.events(process_id,step_instance_id,event_type,detail_json)
    VALUES(v_process.process_id,v_step.step_instance_id,'StepCompleted',jsonb_build_object('outcome',v_decision));
    PERFORM workflow.enter_step(v_process.process_id,v_map,v_next);
    RETURN jsonb_build_object('status','ok','outcome','DECIDED','result',jsonb_build_object('decisionId',v_id,
        'processId',v_process.process_id,'stepInstanceId',v_step.step_instance_id,'decision',v_decision,
        'source','MANUAL','principal',p_context->>'principal'));
END;
$$;

CREATE FUNCTION delivery.claim_outbox(p_owner text, p_limit integer) RETURNS TABLE(outbox_id uuid, lease_version bigint, external_request_id text, correlation_id uuid, amount text, currency text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    RETURN QUERY WITH claimed AS (
        SELECT o.outbox_id FROM delivery.outbox o
        WHERE o.state IN ('PENDING','RETRY_WAIT','LEASED') AND o.next_attempt_at <= now()
        ORDER BY o.created_at FOR UPDATE SKIP LOCKED LIMIT p_limit
    )
    UPDATE delivery.outbox o SET state='LEASED',lease_owner=p_owner,lease_version=o.lease_version+1,
        next_attempt_at=now()+interval '5 seconds',attempt_count=o.attempt_count+1
    FROM claimed c, delivery.external_requests e, payment.operations op
    WHERE o.outbox_id=c.outbox_id AND e.external_request_id=o.external_request_id AND op.operation_id=e.operation_id
    RETURNING o.outbox_id,o.lease_version,o.external_request_id,e.correlation_id,op.amount::text,op.currency;
END;
$$;

CREATE FUNCTION delivery.succeed_outbox(p_outbox_id uuid, p_owner text, p_lease_version bigint, p_provider_payment_id text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_external text;
BEGIN
    -- Lock external request before outbox, matching receipt acceptance lock order.
    SELECT e.external_request_id INTO v_external FROM delivery.external_requests e
    JOIN delivery.outbox o USING(external_request_id) WHERE o.outbox_id=p_outbox_id FOR UPDATE OF e;
    UPDATE delivery.outbox SET state='DELIVERED',delivered_at=now()
    WHERE outbox_id=p_outbox_id AND lease_owner=p_owner AND lease_version=p_lease_version AND state='LEASED';
    IF NOT FOUND THEN RETURN jsonb_build_object('updated',false); END IF;
    UPDATE delivery.external_requests SET state='SENT' WHERE external_request_id=v_external AND state='CREATED';
    RETURN jsonb_build_object('updated',true);
END;
$$;

CREATE FUNCTION delivery.fail_outbox(p_outbox_id uuid, p_owner text, p_lease_version bigint, p_error_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    UPDATE delivery.outbox SET last_error_code=p_error_code,
        state=CASE WHEN p_error_code LIKE '%.retryable' AND attempt_count < 3 THEN 'RETRY_WAIT' ELSE 'DEAD' END,
        next_attempt_at=now()+interval '200 milliseconds'*attempt_count
    WHERE outbox_id=p_outbox_id AND lease_owner=p_owner AND lease_version=p_lease_version AND state='LEASED';
    RETURN jsonb_build_object('updated',FOUND);
END;
$$;

CREATE FUNCTION delivery.reconcile_inbox(p_limit integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_applied integer := 0; v_rec record; v_result jsonb;
BEGIN
    FOR v_rec IN SELECT i.message_id,i.body_hash,e.process_id FROM delivery.inbox i
        JOIN delivery.receipts r USING(message_id) JOIN delivery.external_requests e USING(external_request_id)
        WHERE i.state='RECEIVED' ORDER BY i.received_at FOR UPDATE OF i SKIP LOCKED LIMIT p_limit
    LOOP
        v_result := workflow.accept_signal(v_rec.process_id,'payment.receipt',v_rec.message_id,'{}'::jsonb,v_rec.body_hash);
        IF v_result->>'status' IN ('accepted', 'duplicate') THEN
            UPDATE delivery.inbox SET state='APPLIED',applied_at=now() WHERE message_id=v_rec.message_id;
            UPDATE delivery.receipts SET applied_at=now() WHERE message_id=v_rec.message_id;
            v_applied := v_applied+1;
        END IF;
    END LOOP;
    RETURN v_applied;
END;
$$;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"submit","version":1,"http_method":"POST","target_schema":"payment","target_function":"submit_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-result","type":"object","additionalProperties":false,"required":["operationId","processId","flowName","flowVersion","status"],"properties":{"operationId":{"type":"string","format":"uuid"},"processId":{"type":"string","format":"uuid"},"flowName":{"enum":["payment-processing","payment-review"]},"flowVersion":{"type":"integer","minimum":1},"status":{"const":"PROCESSING"}}},"outcomes":["SUBMITTED"],"required_policy":["payment:write"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"operation","action":"events","version":1,"http_method":"POST","target_schema":"operation","target_function":"events_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["FOUND"],"required_policy":["payment:read"],"idempotency_mode":"none","idempotency_scope":"none","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"validate","version":1,"http_method":"POST","target_schema":"payment","target_function":"validate_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["VALID"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"prepare_external","version":1,"http_method":"POST","target_schema":"payment","target_function":"prepare_external_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["PREPARED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"apply_receipt","version":1,"http_method":"POST","target_schema":"payment","target_function":"apply_receipt_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["COMPLETED","REJECTED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"complete","version":1,"http_method":"POST","target_schema":"payment","target_function":"complete_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["COMPLETED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"reject","version":1,"http_method":"POST","target_schema":"payment","target_function":"reject_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["REJECTED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"check_limit","version":1,"http_method":"POST","target_schema":"payment","target_function":"check_limit_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["WITHIN_LIMIT","REVIEW_REQUIRED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"payment","action":"approve","version":1,"http_method":"POST","target_schema":"payment","target_function":"approve_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:payment-submit-payload","type":"object","additionalProperties":false,"required":["operationId"],"properties":{"operationId":{"type":"string","format":"uuid"}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["COMPLETED"],"required_policy":["payment:internal"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"receipt","action":"accept","version":1,"http_method":"POST","target_schema":"receipt","target_function":"accept_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:receipt-v1","type":"object","additionalProperties":false,"required":["externalRequestId","messageId","occurredAt","outcome","providerPaymentId","version"],"properties":{"externalRequestId":{"type":"string","minLength":1,"maxLength":128,"not":{"pattern":"[\\r\\n]"}},"messageId":{"type":"string","minLength":1,"maxLength":128,"not":{"pattern":"[\\r\\n]"}},"occurredAt":{"type":"string","format":"date-time","maxLength":64,"pattern":"Z$","not":{"pattern":"[\\r\\n]"}},"outcome":{"enum":["COMPLETED","REJECTED"]},"providerPaymentId":{"type":"string","minLength":1,"maxLength":128,"not":{"pattern":"[\\r\\n]"}},"version":{"const":1}}},"response_schema":{"type":"object","$schema":"https://json-schema.org/draft/2020-12/schema"},"outcomes":["RECEIVED","DUPLICATE"],"required_policy":["receipt:write"],"idempotency_mode":"required","idempotency_scope":"global_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"workflow","action":"manual","version":1,"http_method":"POST","target_schema":"workflow","target_function":"manual_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:workflow-manual-payload","type":"object","additionalProperties":false,"required":["processId","stepInstanceId","decision","reason"],"properties":{"processId":{"type":"string","format":"uuid"},"stepInstanceId":{"type":"string","format":"uuid"},"decision":{"enum":["APPROVED","REJECTED"]},"reason":{"type":"string","minLength":1,"maxLength":500}}},"response_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:course:course-1:workflow-manual-result","type":"object","additionalProperties":false,"required":["decisionId","processId","stepInstanceId","decision","source","principal"],"properties":{"decisionId":{"type":"string","format":"uuid"},"processId":{"type":"string","format":"uuid"},"stepInstanceId":{"type":"string","format":"uuid"},"decision":{"enum":["APPROVED","REJECTED"]},"source":{"const":"MANUAL"},"principal":{"type":"string","minLength":1,"maxLength":128}}},"outcomes":["DECIDED"],"required_policy":["workflow:manual"],"idempotency_mode":"required","idempotency_scope":"principal_action","timeout_ms":2000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

INSERT INTO workflow.flow_definitions(flow_name) VALUES('payment-processing');
WITH flow AS (SELECT '{"contract_version":"course-1","flow_name":"payment-processing","version":1,"start_step":"validate_operation","steps":[{"key":"validate_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"validate","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":1,"delays_ms":[]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"prepare_external_request","type":"automatic","task":{"service":"postgres","module":"payment","action":"prepare_external","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":3,"delays_ms":[200,400]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"wait_receipt","type":"wait_signal","signal_type":"payment.receipt","outcome":"RECEIVED"},{"key":"apply_receipt","type":"automatic","task":{"service":"postgres","module":"payment","action":"apply_receipt","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":2,"delays_ms":[200]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"complete_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"complete","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":2,"delays_ms":[200]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"reject_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"reject","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":2,"delays_ms":[200]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"done","type":"end","outcome":"FINISHED"}],"transitions":[{"from":"validate_operation","outcome":"VALID","to":"prepare_external_request"},{"from":"prepare_external_request","outcome":"PREPARED","to":"wait_receipt"},{"from":"wait_receipt","outcome":"RECEIVED","to":"apply_receipt"},{"from":"apply_receipt","outcome":"COMPLETED","to":"complete_operation"},{"from":"apply_receipt","outcome":"REJECTED","to":"reject_operation"},{"from":"complete_operation","outcome":"COMPLETED","to":"done"},{"from":"reject_operation","outcome":"REJECTED","to":"done"}]}'::jsonb AS m)
INSERT INTO workflow.flow_versions(flow_name,flow_version,map_json,map_hash,is_active)
SELECT m->>'flow_name',1,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),true FROM flow;

INSERT INTO workflow.flow_definitions(flow_name) VALUES('payment-review');
WITH flow AS (SELECT '{"contract_version":"course-1","flow_name":"payment-review","version":1,"start_step":"validate_operation","steps":[{"key":"validate_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"validate","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":1,"delays_ms":[]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"check_limit","type":"automatic","task":{"service":"postgres","module":"payment","action":"check_limit","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":1,"delays_ms":[]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"approve_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"approve","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":2,"delays_ms":[200]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"reject_operation","type":"automatic","task":{"service":"postgres","module":"payment","action":"reject","action_version":1,"required_policy":["payment:internal"],"timeout_ms":2000,"retry":{"max_attempts":2,"delays_ms":[200]},"input_mapping":{"/operationId":"/operationId"},"input_constants":{}}},{"key":"wait_manual_decision","type":"manual","allowed_outcomes":["APPROVED","REJECTED"]},{"key":"done","type":"end","outcome":"FINISHED"}],"transitions":[{"from":"validate_operation","outcome":"VALID","to":"check_limit"},{"from":"check_limit","outcome":"WITHIN_LIMIT","to":"approve_operation"},{"from":"check_limit","outcome":"REVIEW_REQUIRED","to":"wait_manual_decision"},{"from":"wait_manual_decision","outcome":"APPROVED","to":"approve_operation"},{"from":"wait_manual_decision","outcome":"REJECTED","to":"reject_operation"},{"from":"approve_operation","outcome":"COMPLETED","to":"done"},{"from":"reject_operation","outcome":"REJECTED","to":"done"}]}'::jsonb AS m)
INSERT INTO workflow.flow_versions(flow_name,flow_version,map_json,map_hash,is_active)
SELECT m->>'flow_name',1,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),true FROM flow;

INSERT INTO payment.flow_bindings VALUES ('PAYMENT_EXECUTION','payment-processing'),('PAYMENT_APPROVAL','payment-review');

CREATE VIEW autocheck.external_requests AS
SELECT external_request_id,operation_id,state,payload_hash,created_at FROM delivery.external_requests;
CREATE VIEW autocheck.receipts AS
SELECT message_id,external_request_id,message_version,outcome,signature_valid,body_hash,received_at,applied_at FROM delivery.receipts;
CREATE VIEW autocheck.outbox AS
SELECT outbox_id,external_request_id,state,attempt_count,next_attempt_at,last_error_code,created_at,delivered_at FROM delivery.outbox;
CREATE VIEW autocheck.inbox AS
SELECT message_id,body_hash,state,received_at,applied_at FROM delivery.inbox;
CREATE VIEW autocheck.decisions AS
SELECT decision_id,process_id,step_instance_id,source,principal,reason_hash,outcome,rule_version,created_at FROM delivery.decisions;
GRANT SELECT ON autocheck.external_requests,autocheck.receipts,autocheck.outbox,autocheck.inbox,autocheck.decisions
TO course_runtime,course_publication;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA delivery,receipt FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA delivery,receipt FROM course_runtime;
GRANT USAGE ON SCHEMA delivery TO outbox_dispatcher,inbox_reconciler;
GRANT EXECUTE ON FUNCTION delivery.claim_outbox(text,integer),delivery.succeed_outbox(uuid,text,bigint,text),
    delivery.fail_outbox(uuid,text,bigint,text) TO outbox_dispatcher;
GRANT EXECUTE ON FUNCTION delivery.reconcile_inbox(integer) TO inbox_reconciler;
REVOKE ALL ON FUNCTION payment.submit_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION operation.events_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.validate_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.prepare_external_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.apply_receipt_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.complete_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.reject_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.check_limit_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION payment.approve_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION receipt.accept_v1(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION workflow.manual_v1(jsonb,jsonb) FROM PUBLIC;
RESET ROLE;
