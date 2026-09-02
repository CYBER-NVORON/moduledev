-- 004_workflow_schema.sql

-- ============================================================
-- 1. SCHEMA & ROLES
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'workflow_worker') THEN
        CREATE ROLE workflow_worker LOGIN;
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS workflow AUTHORIZATION course_owner;

GRANT CONNECT, TEMPORARY ON DATABASE course TO workflow_worker;
GRANT USAGE ON SCHEMA workflow TO workflow_worker;
GRANT USAGE ON SCHEMA api TO workflow_worker;
GRANT USAGE ON SCHEMA autocheck TO workflow_worker;

GRANT USAGE ON SCHEMA workflow TO course_runtime, course_publication;

-- ============================================================
-- 2. DEFINITION TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS workflow.flow_definitions (
    flow_name text PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE workflow.flow_definitions OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.flow_versions (
    flow_name text NOT NULL REFERENCES workflow.flow_definitions(flow_name),
    flow_version integer NOT NULL,
    map_json jsonb NOT NULL,
    map_hash text NOT NULL,
    status text NOT NULL DEFAULT 'PUBLISHED' CHECK (status IN ('PUBLISHED')),
    is_active boolean NOT NULL DEFAULT false,
    published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (flow_name, flow_version)
);
ALTER TABLE workflow.flow_versions OWNER TO course_owner;

CREATE UNIQUE INDEX IF NOT EXISTS flow_versions_one_active
    ON workflow.flow_versions (flow_name)
    WHERE is_active;

-- ============================================================
-- 3. RUNTIME STATE TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS workflow.process_instances (
    process_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    business_key text NOT NULL,
    flow_name text NOT NULL,
    flow_version integer NOT NULL,
    state text NOT NULL DEFAULT 'CREATED' CHECK (
        state IN ('CREATED', 'RUNNING', 'WAITING_SIGNAL', 'WAITING_MANUAL', 'COMPLETED', 'FAILED')
    ),
    current_step_key text NULL,
    data_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (flow_name, flow_version) REFERENCES workflow.flow_versions (flow_name, flow_version),
    UNIQUE (flow_name, business_key)
);
ALTER TABLE workflow.process_instances OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.step_instances (
    step_instance_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id uuid NOT NULL REFERENCES workflow.process_instances(process_id),
    step_key text NOT NULL,
    step_type text NOT NULL CHECK (
        step_type IN ('AUTOMATIC', 'WAIT_SIGNAL', 'MANUAL', 'END')
    ),
    state text NOT NULL DEFAULT 'PENDING' CHECK (
        state IN ('PENDING', 'READY', 'RUNNING', 'WAITING', 'COMPLETED', 'FAILED')
    ),
    outcome text NULL,
    entered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz NULL
);
ALTER TABLE workflow.step_instances OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.jobs (
    job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id uuid NOT NULL REFERENCES workflow.process_instances(process_id),
    step_instance_id uuid NOT NULL REFERENCES workflow.step_instances(step_instance_id),
    execution_id uuid NOT NULL DEFAULT gen_random_uuid(),
    state text NOT NULL DEFAULT 'READY' CHECK (
        state IN ('READY', 'LEASED', 'RETRY_WAIT', 'SUCCEEDED', 'DEAD')
    ),
    lease_owner text NULL,
    lease_version bigint NOT NULL DEFAULT 0,
    lease_until timestamptz NULL,
    attempt_count integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 1,
    delays_ms integer[] NOT NULL DEFAULT '{}',
    next_attempt_at timestamptz NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE workflow.jobs OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.attempts (
    attempt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id uuid NOT NULL REFERENCES workflow.jobs(job_id),
    execution_id uuid NOT NULL,
    lease_version bigint NOT NULL,
    attempt_number integer NOT NULL,
    status text NOT NULL DEFAULT 'RUNNING' CHECK (
        status IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'STALE')
    ),
    outcome text NULL,
    error_code text NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz NULL
);
ALTER TABLE workflow.attempts OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.signals (
    message_id text PRIMARY KEY,
    process_id uuid NOT NULL REFERENCES workflow.process_instances(process_id),
    signal_type text NOT NULL,
    body_json jsonb NULL,
    body_hash text NOT NULL,
    status text NOT NULL DEFAULT 'ACCEPTED' CHECK (
        status IN ('ACCEPTED', 'APPLIED')
    ),
    received_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE workflow.signals OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS workflow.events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    process_id uuid NOT NULL REFERENCES workflow.process_instances(process_id),
    step_instance_id uuid NULL REFERENCES workflow.step_instances(step_instance_id),
    event_type text NOT NULL,
    detail_json jsonb NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE workflow.events OWNER TO course_owner;

-- ============================================================
-- 4. TRIGGERS (Append-only & Immutability)
-- ============================================================

CREATE OR REPLACE FUNCTION workflow.trg_events_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'workflow.events is append-only';
END;
$$;
ALTER FUNCTION workflow.trg_events_append_only() OWNER TO course_owner;

DROP TRIGGER IF EXISTS trg_events_append_only_check ON workflow.events;
CREATE TRIGGER trg_events_append_only_check
BEFORE UPDATE OR DELETE ON workflow.events
FOR EACH STATEMENT EXECUTE FUNCTION workflow.trg_events_append_only();

CREATE OR REPLACE FUNCTION workflow.trg_attempts_no_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'workflow.attempts cannot be deleted';
END;
$$;
ALTER FUNCTION workflow.trg_attempts_no_delete() OWNER TO course_owner;

DROP TRIGGER IF EXISTS trg_attempts_no_delete_check ON workflow.attempts;
CREATE TRIGGER trg_attempts_no_delete_check
BEFORE DELETE ON workflow.attempts
FOR EACH STATEMENT EXECUTE FUNCTION workflow.trg_attempts_no_delete();

-- ============================================================
-- 5. GRANTS
-- ============================================================

GRANT SELECT ON ALL TABLES IN SCHEMA workflow TO course_runtime, course_publication;
GRANT INSERT, UPDATE ON TABLE workflow.flow_definitions TO course_publication;
GRANT INSERT, UPDATE ON TABLE workflow.flow_versions TO course_publication;
