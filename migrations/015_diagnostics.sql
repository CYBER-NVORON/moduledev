SET ROLE course_owner;
CREATE SCHEMA diagnostics AUTHORIZATION course_owner;
ALTER TABLE catalog.action_dispatches ADD COLUMN dispatch_id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE catalog.action_dispatches ADD PRIMARY KEY(dispatch_id);
CREATE TABLE catalog.dispatch_links (
    dispatch_id uuid PRIMARY KEY REFERENCES catalog.action_dispatches,
    operation_id uuid REFERENCES payment.operations,
    process_id uuid REFERENCES workflow.process_instances
);
CREATE TRIGGER dispatch_links_append_only BEFORE UPDATE OR DELETE ON catalog.dispatch_links
    FOR EACH ROW EXECUTE FUNCTION payment.trg_events_append_only();

-- Preserve the proven dispatcher, adding only durable, payload-free audit links.
CREATE FUNCTION diagnostics.link_dispatch(p_module text,p_action text,p_context jsonb,p_payload jsonb,p_result jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_oid uuid; v_pid uuid;
BEGIN
    IF p_result->>'status' IS DISTINCT FROM 'ok' OR p_module='diagnostics' THEN RETURN; END IF;
    SELECT operation_id,process_id INTO v_oid,v_pid FROM payment.operations
    WHERE operation_id::text=COALESCE(p_result#>>'{result,operationId}',p_payload->>'operationId')
       OR (request_id=p_context->>'requestId' AND principal=p_context->>'principal')
    ORDER BY created_at,operation_id LIMIT 1;
    IF v_pid IS NULL THEN
        SELECT process_id INTO v_pid FROM workflow.process_instances
        WHERE process_id::text=COALESCE(p_context->>'processId',p_result#>>'{result,processId}',p_payload->>'processId');
    END IF;
    IF v_oid IS NULL THEN
        SELECT e.operation_id,e.process_id INTO v_oid,v_pid FROM delivery.external_requests e
        WHERE e.external_request_id=COALESCE(p_payload->>'externalRequestId',p_result#>>'{result,externalRequestId}');
        IF v_oid IS NULL THEN
            SELECT op.operation_id,op.process_id INTO v_oid,v_pid FROM payment.operations op
            WHERE op.process_id::text=COALESCE(p_context->>'processId',p_result#>>'{result,processId}',p_payload->>'processId');
        END IF;
    END IF;
    -- Non-payment workflows also have a useful trace.
    IF v_pid IS NULL THEN
        SELECT process_id INTO v_pid FROM workflow.process_instances
        WHERE process_id::text=COALESCE(p_context->>'processId',p_result#>>'{result,processId}',p_payload->>'processId');
    END IF;
    INSERT INTO catalog.dispatch_links(dispatch_id,operation_id,process_id)
    SELECT dispatch_id,v_oid,v_pid FROM catalog.action_dispatches
    WHERE correlation_id::text=p_context->>'correlationId' AND module=p_module AND action=p_action
    ON CONFLICT DO NOTHING;
END;
$$;

ALTER FUNCTION api.invoke(text,text,integer,jsonb,jsonb) RENAME TO invoke_core;
CREATE FUNCTION api.invoke(p_module text,p_action text,p_version integer,p_context jsonb,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
    v_result := api.invoke_core(p_module,p_action,p_version,p_context,p_payload);
    PERFORM diagnostics.link_dispatch(p_module,p_action,p_context,p_payload,v_result);
    RETURN v_result;
END;
$$;
CREATE FUNCTION diagnostics.link_replay() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    INSERT INTO catalog.dispatch_links(dispatch_id,operation_id,process_id)
    SELECT NEW.dispatch_id,l.operation_id,l.process_id FROM catalog.action_dispatches d
    JOIN catalog.dispatch_links l USING(dispatch_id)
    WHERE d.request_id=NEW.request_id AND d.principal=NEW.principal
        AND d.module=NEW.module AND d.action=NEW.action AND d.version=NEW.version
        AND (l.operation_id IS NOT NULL OR l.process_id IS NOT NULL)
    ORDER BY d.occurred_at,d.dispatch_id LIMIT 1 ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$;
CREATE TRIGGER dispatch_replay_link AFTER INSERT ON catalog.action_dispatches
    FOR EACH ROW WHEN (NEW.replay_marker) EXECUTE FUNCTION diagnostics.link_replay();
REVOKE ALL ON FUNCTION api.invoke_core(text,text,integer,jsonb,jsonb)
    FROM PUBLIC,course_runtime,workflow_worker,course_publication;
REVOKE ALL ON FUNCTION api.invoke(text,text,integer,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.invoke(text,text,integer,jsonb,jsonb) TO course_runtime,workflow_worker;

-- Backfill identifiable legacy dispatches without changing any existing audit row.
INSERT INTO catalog.dispatch_links(dispatch_id,operation_id,process_id)
SELECT d.dispatch_id,op.operation_id,COALESCE(op.process_id,j.process_id)
FROM catalog.action_dispatches d
LEFT JOIN payment.operations op ON op.request_id=d.request_id AND op.principal=d.principal
LEFT JOIN workflow.jobs j ON j.execution_id::text=d.request_id
WHERE op.operation_id IS NOT NULL OR j.process_id IS NOT NULL;

CREATE VIEW diagnostics.identifiers AS
    SELECT operation_id::text AS identifier,'operationId'::text AS kind,operation_id,process_id FROM payment.operations
    UNION ALL SELECT request_id,'requestId',operation_id,process_id FROM payment.operations
    UNION ALL SELECT p.process_id::text,'processId',op.operation_id,p.process_id FROM workflow.process_instances p
        LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT s.step_instance_id::text,'stepInstanceId',op.operation_id,s.process_id FROM workflow.step_instances s
        LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT j.job_id::text,'jobId',op.operation_id,j.process_id FROM workflow.jobs j LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT j.execution_id::text,'executionId',op.operation_id,j.process_id FROM workflow.jobs j LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT a.attempt_id::text,'attemptId',op.operation_id,j.process_id FROM workflow.attempts a
        JOIN workflow.jobs j USING(job_id) LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT external_request_id,'externalRequestId',operation_id,process_id FROM delivery.external_requests
    UNION ALL SELECT correlation_id::text,'correlationId',operation_id,process_id FROM delivery.external_requests
    UNION ALL SELECT r.message_id,'messageId',e.operation_id,e.process_id FROM delivery.receipts r JOIN delivery.external_requests e USING(external_request_id)
    UNION ALL SELECT d.decision_id::text,'decisionId',op.operation_id,d.process_id FROM delivery.decisions d LEFT JOIN payment.operations op USING(process_id)
    UNION ALL SELECT d.correlation_id::text,'correlationId',COALESCE(l.operation_id,op.operation_id),COALESCE(l.process_id,op.process_id)
        FROM catalog.action_dispatches d LEFT JOIN catalog.dispatch_links l USING(dispatch_id)
        LEFT JOIN payment.operations op ON op.operation_id=l.operation_id OR op.process_id=l.process_id WHERE d.module<>'diagnostics'
    UNION ALL SELECT d.request_id,'requestId',COALESCE(l.operation_id,op.operation_id),COALESCE(l.process_id,op.process_id)
        FROM catalog.action_dispatches d LEFT JOIN catalog.dispatch_links l USING(dispatch_id)
        LEFT JOIN payment.operations op ON op.operation_id=l.operation_id OR op.process_id=l.process_id WHERE d.module<>'diagnostics';

CREATE FUNCTION diagnostics.stalled_v1(p_context jsonb,p_payload jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
    SELECT jsonb_build_object('status','ok','outcome','FOUND','result',jsonb_build_object('items',
        COALESCE(jsonb_agg(jsonb_build_object('operationId',op.operation_id,'processId',p.process_id,
            'externalRequestId',e.external_request_id) ORDER BY op.operation_id),'[]'::jsonb)))
    FROM payment.operations op JOIN workflow.process_instances p USING(process_id)
    JOIN delivery.external_requests e ON e.operation_id=op.operation_id
    JOIN delivery.outbox o USING(external_request_id)
    WHERE o.state='DEAD' AND p.state='WAITING_SIGNAL' AND op.status='PROCESSING'
$$;

-- Both Outbox metrics read created_at from the same active-state subset.
CREATE INDEX outbox_pending_created_at_idx ON delivery.outbox(created_at)
    WHERE state IN ('PENDING','LEASED','RETRY_WAIT');

CREATE VIEW autocheck.metrics AS
WITH ready AS (
    SELECT created_at FROM workflow.jobs WHERE state='READY'
        OR (state='RETRY_WAIT' AND next_attempt_at<=now()) OR (state='LEASED' AND lease_until<now())
), pending AS (SELECT created_at FROM delivery.outbox WHERE state IN ('PENDING','LEASED','RETRY_WAIT'))
SELECT (SELECT count(*) FROM ready) AS workflow_jobs_ready,
    (SELECT COALESCE(greatest(0,extract(epoch FROM now()-min(created_at))),0) FROM ready) AS workflow_job_oldest_age_seconds,
    (SELECT count(*) FROM workflow.process_instances WHERE state IN ('WAITING_SIGNAL','WAITING_MANUAL')) AS workflow_processes_waiting,
    (SELECT count(*) FROM pending) AS outbox_pending,
    (SELECT COALESCE(greatest(0,extract(epoch FROM now()-min(created_at))),0) FROM pending) AS outbox_oldest_age_seconds,
    (SELECT count(*) FROM workflow.events WHERE event_type='TaskFailed') AS workflow_failures_total;
GRANT SELECT ON autocheck.metrics TO course_runtime;

-- Trace and manifests follow below, using explicit safe-field projections.

CREATE FUNCTION diagnostics.trace_v1(p_context jsonb,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE v_id text:=p_payload->>'identifier'; v_oid uuid; v_pid uuid; v_matched text[]; v_result jsonb;
BEGIN
    SELECT array_agg(DISTINCT kind ORDER BY kind) INTO v_matched FROM diagnostics.identifiers WHERE identifier=v_id;
    IF v_matched IS NULL THEN
        RETURN jsonb_build_object('status','error','code','diagnostics.trace_not_found','message','identifier not found');
    END IF;
    SELECT operation_id,process_id INTO v_oid,v_pid FROM diagnostics.identifiers WHERE identifier=v_id
        ORDER BY operation_id NULLS LAST,process_id NULLS LAST LIMIT 1;
    SELECT jsonb_build_object(
        'query',jsonb_build_object('identifier',v_id,'matchedBy',to_jsonb(v_matched)),
        'operation',(SELECT jsonb_build_object('operationId',op.operation_id,'requestId',op.request_id,'operationKind',op.operation_kind,'amount',op.amount::text,'currency',op.currency,'status',op.status,'processId',op.process_id,'createdAt',op.created_at,'updatedAt',op.updated_at) FROM payment.operations op WHERE op.operation_id=v_oid),
        'process',(SELECT jsonb_build_object('processId',p.process_id,'flowName',p.flow_name,'flowVersion',p.flow_version,'state',p.state,'currentStepKey',p.current_step_key,'createdAt',p.created_at,'updatedAt',p.updated_at) FROM workflow.process_instances p WHERE p.process_id=v_pid),
        'dispatches',(SELECT COALESCE(jsonb_agg(jsonb_build_object('correlationId',d.correlation_id,'requestId',COALESCE(d.request_id,''),'module',d.module,'action',d.action,'version',d.version,'status',d.status,'outcome',d.outcome,'occurredAt',d.occurred_at) ORDER BY d.occurred_at,d.dispatch_id),'[]'::jsonb) FROM catalog.action_dispatches d LEFT JOIN catalog.dispatch_links l USING(dispatch_id) WHERE d.module<>'diagnostics' AND d.version>=1 AND (l.operation_id=v_oid OR l.process_id=v_pid OR (v_oid IS NULL AND v_pid IS NULL AND (d.correlation_id::text=v_id OR d.request_id=v_id)))),
        'operationEvents',(SELECT COALESCE(jsonb_agg(jsonb_build_object('eventId',e.event_id,'eventType',e.event_type,'occurredAt',e.occurred_at) ORDER BY e.occurred_at,e.event_id),'[]'::jsonb) FROM autocheck.operation_events e WHERE e.operation_id=v_oid),
        'steps',(SELECT COALESCE(jsonb_agg(jsonb_build_object('stepInstanceId',s.step_instance_id,'stepKey',s.step_key,'stepType',s.step_type,'state',s.state,'outcome',s.outcome,'enteredAt',s.entered_at,'completedAt',s.completed_at) ORDER BY s.entered_at,s.step_instance_id),'[]'::jsonb) FROM workflow.step_instances s WHERE s.process_id=v_pid),
        'jobs',(SELECT COALESCE(jsonb_agg(jsonb_build_object('jobId',j.job_id,'stepInstanceId',j.step_instance_id,'executionId',j.execution_id,'state',j.state,'leaseVersion',j.lease_version,'attemptCount',j.attempt_count,'nextAttemptAt',j.next_attempt_at) ORDER BY j.created_at,j.job_id),'[]'::jsonb) FROM workflow.jobs j WHERE j.process_id=v_pid),
        'attempts',(SELECT COALESCE(jsonb_agg(jsonb_build_object('attemptId',a.attempt_id,'jobId',a.job_id,'executionId',a.execution_id,'leaseVersion',a.lease_version,'attemptNumber',a.attempt_number,'status',a.status,'outcome',a.outcome,'errorCode',a.error_code,'startedAt',a.started_at,'finishedAt',a.finished_at) ORDER BY a.started_at,a.attempt_id),'[]'::jsonb) FROM workflow.attempts a JOIN workflow.jobs j USING(job_id) WHERE j.process_id=v_pid),
        'outbox',(SELECT COALESCE(jsonb_agg(jsonb_build_object('outboxId',o.outbox_id,'externalRequestId',o.external_request_id,'state',o.state,'attemptCount',o.attempt_count,'leaseVersion',o.lease_version,'nextAttemptAt',o.next_attempt_at,'lastErrorCode',o.last_error_code,'createdAt',o.created_at,'deliveredAt',o.delivered_at,'deadAt',o.dead_at) ORDER BY o.created_at,o.outbox_id),'[]'::jsonb) FROM delivery.outbox o JOIN delivery.external_requests e USING(external_request_id) WHERE e.operation_id=v_oid OR e.process_id=v_pid),
        'inbox',(SELECT COALESCE(jsonb_agg(jsonb_build_object('messageId',i.message_id,'state',i.state,'receivedAt',i.received_at,'appliedAt',i.applied_at) ORDER BY i.received_at,i.message_id),'[]'::jsonb) FROM delivery.inbox i JOIN delivery.receipts r USING(message_id) JOIN delivery.external_requests e USING(external_request_id) WHERE e.operation_id=v_oid OR e.process_id=v_pid),
        'receipts',(SELECT COALESCE(jsonb_agg(jsonb_build_object('messageId',r.message_id,'externalRequestId',r.external_request_id,'outcome',r.outcome,'signatureValid',r.signature_valid,'receivedAt',r.received_at,'appliedAt',r.applied_at) ORDER BY r.received_at,r.message_id),'[]'::jsonb) FROM delivery.receipts r JOIN delivery.external_requests e USING(external_request_id) WHERE e.operation_id=v_oid OR e.process_id=v_pid),
        'decisions',(SELECT COALESCE(jsonb_agg(jsonb_build_object('decisionId',d.decision_id,'stepInstanceId',d.step_instance_id,'source',d.source,'principal',d.principal,'outcome',d.outcome,'ruleVersion',d.rule_version,'createdAt',d.created_at) ORDER BY d.created_at,d.decision_id),'[]'::jsonb) FROM delivery.decisions d WHERE d.process_id=v_pid)
    ) INTO v_result;
    RETURN jsonb_build_object('status','ok','outcome','FOUND','result',v_result);
END;
$$;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"diagnostics","action":"trace","version":1,"http_method":"POST","target_schema":"diagnostics","target_function":"trace_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://moduledev.example/contracts/course-1/diagnostics-trace.payload.schema.json","title":"diagnostics.trace version 1 payload","type":"object","required":["identifier"],"properties":{"identifier":{"type":"string","minLength":1,"maxLength":200,"pattern":"^[^\\r\\n]+$"}},"additionalProperties":false},"response_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://moduledev.example/contracts/course-1/diagnostics-trace.result.schema.json","title":"diagnostics.trace version 1 result","type":"object","required":["query","dispatches","operation","operationEvents","process","steps","jobs","attempts","outbox","inbox","receipts","decisions"],"properties":{"query":{"type":"object","required":["identifier","matchedBy"],"properties":{"identifier":{"type":"string","minLength":1,"maxLength":200},"matchedBy":{"type":"array","minItems":1,"uniqueItems":true,"items":{"enum":["correlationId","requestId","operationId","processId","stepInstanceId","jobId","executionId","attemptId","externalRequestId","messageId","decisionId"]}}},"additionalProperties":false},"dispatches":{"type":"array","items":{"$ref":"#/$defs/dispatch"}},"operation":{"oneOf":[{"type":"null"},{"$ref":"#/$defs/operation"}]},"operationEvents":{"type":"array","items":{"$ref":"#/$defs/operationEvent"}},"process":{"oneOf":[{"type":"null"},{"$ref":"#/$defs/process"}]},"steps":{"type":"array","items":{"$ref":"#/$defs/step"}},"jobs":{"type":"array","items":{"$ref":"#/$defs/job"}},"attempts":{"type":"array","items":{"$ref":"#/$defs/attempt"}},"outbox":{"type":"array","items":{"$ref":"#/$defs/outbox"}},"inbox":{"type":"array","items":{"$ref":"#/$defs/inbox"}},"receipts":{"type":"array","items":{"$ref":"#/$defs/receipt"}},"decisions":{"type":"array","items":{"$ref":"#/$defs/decision"}}},"$defs":{"uuid":{"type":"string","format":"uuid"},"timestamp":{"type":"string","format":"date-time"},"nullableTimestamp":{"type":["string","null"],"format":"date-time"},"nullableString":{"type":["string","null"]},"dispatch":{"type":"object","required":["correlationId","requestId","module","action","version","status","outcome","occurredAt"],"properties":{"correlationId":{"$ref":"#/$defs/uuid"},"requestId":{"type":"string"},"module":{"type":"string"},"action":{"type":"string"},"version":{"type":"integer","minimum":1},"status":{"enum":["OK","ERROR"]},"outcome":{"$ref":"#/$defs/nullableString"},"occurredAt":{"$ref":"#/$defs/timestamp"}},"additionalProperties":false},"operation":{"type":"object","required":["operationId","requestId","operationKind","amount","currency","status","processId","createdAt","updatedAt"],"properties":{"operationId":{"$ref":"#/$defs/uuid"},"requestId":{"type":"string"},"operationKind":{"type":"string"},"amount":{"type":"string","pattern":"^-?[0-9]+\\.[0-9]{2}$"},"currency":{"type":"string"},"status":{"enum":["CREATED","PROCESSING","COMPLETED","REJECTED"]},"processId":{"oneOf":[{"type":"null"},{"$ref":"#/$defs/uuid"}]},"createdAt":{"$ref":"#/$defs/timestamp"},"updatedAt":{"$ref":"#/$defs/timestamp"}},"additionalProperties":false},"operationEvent":{"type":"object","required":["eventId","eventType","occurredAt"],"properties":{"eventId":{"$ref":"#/$defs/uuid"},"eventType":{"type":"string"},"occurredAt":{"$ref":"#/$defs/timestamp"}},"additionalProperties":false},"process":{"type":"object","required":["processId","flowName","flowVersion","state","currentStepKey","createdAt","updatedAt"],"properties":{"processId":{"$ref":"#/$defs/uuid"},"flowName":{"type":"string"},"flowVersion":{"type":"integer","minimum":1},"state":{"enum":["CREATED","RUNNING","WAITING_SIGNAL","WAITING_MANUAL","COMPLETED","FAILED"]},"currentStepKey":{"$ref":"#/$defs/nullableString"},"createdAt":{"$ref":"#/$defs/timestamp"},"updatedAt":{"$ref":"#/$defs/timestamp"}},"additionalProperties":false},"step":{"type":"object","required":["stepInstanceId","stepKey","stepType","state","outcome","enteredAt","completedAt"],"properties":{"stepInstanceId":{"$ref":"#/$defs/uuid"},"stepKey":{"type":"string"},"stepType":{"enum":["AUTOMATIC","WAIT_SIGNAL","MANUAL","END"]},"state":{"enum":["PENDING","READY","RUNNING","WAITING","COMPLETED","FAILED"]},"outcome":{"$ref":"#/$defs/nullableString"},"enteredAt":{"$ref":"#/$defs/timestamp"},"completedAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"job":{"type":"object","required":["jobId","stepInstanceId","executionId","state","leaseVersion","attemptCount","nextAttemptAt"],"properties":{"jobId":{"$ref":"#/$defs/uuid"},"stepInstanceId":{"$ref":"#/$defs/uuid"},"executionId":{"$ref":"#/$defs/uuid"},"state":{"enum":["READY","LEASED","RETRY_WAIT","SUCCEEDED","DEAD"]},"leaseVersion":{"type":"integer","minimum":0},"attemptCount":{"type":"integer","minimum":0},"nextAttemptAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"attempt":{"type":"object","required":["attemptId","jobId","executionId","leaseVersion","attemptNumber","status","outcome","errorCode","startedAt","finishedAt"],"properties":{"attemptId":{"$ref":"#/$defs/uuid"},"jobId":{"$ref":"#/$defs/uuid"},"executionId":{"$ref":"#/$defs/uuid"},"leaseVersion":{"type":"integer","minimum":1},"attemptNumber":{"type":"integer","minimum":1},"status":{"enum":["RUNNING","SUCCEEDED","FAILED","STALE"]},"outcome":{"$ref":"#/$defs/nullableString"},"errorCode":{"$ref":"#/$defs/nullableString"},"startedAt":{"$ref":"#/$defs/timestamp"},"finishedAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"outbox":{"type":"object","required":["outboxId","externalRequestId","state","attemptCount","leaseVersion","nextAttemptAt","lastErrorCode","createdAt","deliveredAt","deadAt"],"properties":{"outboxId":{"$ref":"#/$defs/uuid"},"externalRequestId":{"type":"string"},"state":{"enum":["PENDING","LEASED","RETRY_WAIT","DELIVERED","DEAD","CONFIRMED"]},"attemptCount":{"type":"integer","minimum":0},"leaseVersion":{"type":"integer","minimum":0},"nextAttemptAt":{"$ref":"#/$defs/nullableTimestamp"},"lastErrorCode":{"$ref":"#/$defs/nullableString"},"createdAt":{"$ref":"#/$defs/timestamp"},"deliveredAt":{"$ref":"#/$defs/nullableTimestamp"},"deadAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"inbox":{"type":"object","required":["messageId","state","receivedAt","appliedAt"],"properties":{"messageId":{"type":"string"},"state":{"enum":["RECEIVED","APPLIED","CONFLICT"]},"receivedAt":{"$ref":"#/$defs/timestamp"},"appliedAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"receipt":{"type":"object","required":["messageId","externalRequestId","outcome","signatureValid","receivedAt","appliedAt"],"properties":{"messageId":{"type":"string"},"externalRequestId":{"type":"string"},"outcome":{"enum":["COMPLETED","REJECTED"]},"signatureValid":{"const":true},"receivedAt":{"$ref":"#/$defs/timestamp"},"appliedAt":{"$ref":"#/$defs/nullableTimestamp"}},"additionalProperties":false},"decision":{"type":"object","required":["decisionId","stepInstanceId","source","principal","outcome","ruleVersion","createdAt"],"properties":{"decisionId":{"$ref":"#/$defs/uuid"},"stepInstanceId":{"$ref":"#/$defs/uuid"},"source":{"enum":["LIMIT_RULE","MANUAL"]},"principal":{"type":"string"},"outcome":{"enum":["APPROVED","REJECTED"]},"ruleVersion":{"$ref":"#/$defs/nullableString"},"createdAt":{"$ref":"#/$defs/timestamp"}},"additionalProperties":false}},"additionalProperties":false},"outcomes":["FOUND"],"required_policy":["diagnostics:read"],"idempotency_mode":"none","idempotency_scope":"none","timeout_ms":5000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

WITH manifest AS (SELECT '{"contract_version":"course-1","module":"diagnostics","action":"stalled","version":1,"http_method":"POST","target_schema":"diagnostics","target_function":"stalled_v1","request_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://moduledev.example/contracts/course-1/diagnostics-stalled.payload.schema.json","title":"diagnostics.stalled version 1 payload","type":"object","properties":{},"additionalProperties":false},"response_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://moduledev.example/contracts/course-1/diagnostics-stalled.result.schema.json","title":"diagnostics.stalled version 1 result","type":"object","required":["items"],"properties":{"items":{"type":"array","uniqueItems":true,"items":{"type":"object","required":["operationId","processId","externalRequestId"],"properties":{"operationId":{"type":"string","format":"uuid"},"processId":{"type":"string","format":"uuid"},"externalRequestId":{"type":"string","minLength":1,"maxLength":200,"not":{"pattern":"[\r\n]"}}},"additionalProperties":false}}},"additionalProperties":false},"outcomes":["FOUND"],"required_policy":["diagnostics:read"],"idempotency_mode":"none","idempotency_scope":"none","timeout_ms":5000,"enabled":true,"is_default":true}'::jsonb AS m)
INSERT INTO catalog.actions(module,action,version,manifest_json,manifest_hash,target_schema,target_function,
    http_method,outcomes,required_policy,idempotency_mode,idempotency_scope,timeout_ms,enabled,is_default)
SELECT m->>'module',m->>'action',(m->>'version')::integer,m,encode(sha256(convert_to(m::text,'UTF8')),'hex'),
    m->>'target_schema',m->>'target_function',m->>'http_method',m->'outcomes',m->'required_policy',
    m->>'idempotency_mode',m->>'idempotency_scope',(m->>'timeout_ms')::integer,true,true FROM manifest;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA diagnostics FROM PUBLIC;
GRANT USAGE ON SCHEMA autocheck TO autocheck_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA autocheck TO autocheck_reader;
RESET ROLE;
