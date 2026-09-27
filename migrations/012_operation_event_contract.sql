-- Forward-only correction: preserve checksums and append-only legacy history.
SET ROLE course_owner;

-- NOT VALID deliberately keeps legacy rows unchanged while checking every new row.
-- Public readers below translate only the three historical names.
ALTER TABLE payment.operation_events
ADD CONSTRAINT operation_events_canonical_type CHECK (event_type IN (
    'OPERATION_CREATED', 'OPERATION_SUBMITTED',
    'OPERATION_COMPLETED', 'OPERATION_REJECTED'
)) NOT VALID;

CREATE OR REPLACE VIEW autocheck.operation_events AS
SELECT event_id, operation_id,
       CASE event_type
           WHEN 'OperationSubmitted' THEN 'OPERATION_SUBMITTED'
           WHEN 'OperationCompleted' THEN 'OPERATION_COMPLETED'
           WHEN 'OperationRejected' THEN 'OPERATION_REJECTED'
           ELSE event_type
       END AS event_type,
       payload_hash, occurred_at
FROM payment.operation_events;

CREATE OR REPLACE FUNCTION payment.submit_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
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
        VALUES(v_op.operation_id,'OPERATION_SUBMITTED',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    SELECT * INTO v_process FROM workflow.process_instances WHERE process_id=v_op.process_id;
    RETURN jsonb_build_object('status','ok','outcome','SUBMITTED','result',jsonb_build_object(
        'operationId',v_op.operation_id,'processId',v_process.process_id,'flowName',v_process.flow_name,
        'flowVersion',v_process.flow_version,'status','PROCESSING'));
END;
$$;

CREATE OR REPLACE FUNCTION payment.complete_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
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
        VALUES(v_op.operation_id,'OPERATION_COMPLETED',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','COMPLETED','result','{}'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION payment.reject_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
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
        VALUES(v_op.operation_id,'OPERATION_REJECTED',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','REJECTED','result','{}'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION payment.approve_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
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
        VALUES(v_op.operation_id,'OPERATION_COMPLETED',encode(sha256(convert_to(p_payload::text,'UTF8')),'hex'));
    END IF;
    RETURN jsonb_build_object('status','ok','outcome','COMPLETED','result','{}'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION operation.events_v1(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_events jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM payment.operations WHERE operation_id=(p_payload->>'operationId')::uuid) THEN
        RETURN jsonb_build_object('status','error','code','operation.not_found','message','operation not found');
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('eventId',event_id,'eventType',event_type,
             'occurredAt',occurred_at,'payloadHash',payload_hash) ORDER BY occurred_at,event_id),'[]'::jsonb)
    INTO v_events FROM autocheck.operation_events WHERE operation_id=(p_payload->>'operationId')::uuid;
    RETURN jsonb_build_object('status','ok','outcome','FOUND','result',jsonb_build_object('events',v_events));
END;
$$;

RESET ROLE;

