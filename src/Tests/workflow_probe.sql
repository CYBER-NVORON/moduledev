SET ROLE course_migration;
CREATE SCHEMA regression;
CREATE TABLE regression.effects (
    process_id uuid NOT NULL, execution_id uuid NOT NULL,
    payload jsonb NOT NULL, context jsonb NOT NULL
);
ALTER TABLE regression.effects OWNER TO course_owner;
CREATE FUNCTION regression.execute(p_context jsonb, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    INSERT INTO regression.effects VALUES (
        (p_context->>'processId')::uuid, (p_context->>'executionId')::uuid, p_payload, p_context);
    IF p_payload->>'value' = 'retry-once' AND NOT EXISTS (
        SELECT 1 FROM workflow.attempts
        WHERE job_id=(p_context->>'jobId')::uuid AND status='FAILED'
    ) THEN
        RETURN '{"status":"error","code":"test.retryable","message":"sensitive-regression-message","retryable":true}'::jsonb;
    END IF;
    IF p_payload->>'value' = 'raise-error' THEN
        RAISE EXCEPTION 'sensitive-regression-message';
    END IF;
    IF p_payload->>'value' = 'null-result' THEN
        RETURN '{"status":"ok","outcome":"DONE","result":null}'::jsonb;
    END IF;
    RETURN '{"status":"ok","outcome":"DONE","result":{}}'::jsonb;
END;
$$;
REVOKE ALL ON FUNCTION regression.execute(jsonb, jsonb) FROM PUBLIC;
RESET ROLE;
