-- 001_init_roles_and_catalog.sql
-- Phase 1: Roles, schemas, core tables, catalog, idempotency, payment

-- ============================================================
-- 1. ROLES (idempotent with IF NOT EXISTS)
-- ============================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_owner') THEN
    CREATE ROLE course_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_runtime') THEN
    CREATE ROLE course_runtime LOGIN PASSWORD 'runtime_pass';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_publication') THEN
    CREATE ROLE course_publication LOGIN PASSWORD 'publication_pass';
  END IF;
END $$;

GRANT ALL ON DATABASE course TO course_owner;
GRANT ALL ON DATABASE course TO course_publication;
GRANT CONNECT, TEMPORARY ON DATABASE course TO course_runtime;

GRANT course_owner TO course_publication;

-- ============================================================
-- 2. SCHEMAS
-- ============================================================
CREATE SCHEMA IF NOT EXISTS catalog  AUTHORIZATION course_owner;
CREATE SCHEMA IF NOT EXISTS idempotency AUTHORIZATION course_owner;
CREATE SCHEMA IF NOT EXISTS payment  AUTHORIZATION course_owner;
CREATE SCHEMA IF NOT EXISTS autocheck AUTHORIZATION course_owner;
CREATE SCHEMA IF NOT EXISTS api      AUTHORIZATION course_owner;

-- ============================================================
-- 3. CATALOG TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS catalog.migrations (
    filename        text        PRIMARY KEY,
    checksum_sha256 text        NOT NULL,
    applied_at      timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE catalog.migrations OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS catalog.actions (
    module           text     NOT NULL,
    action           text     NOT NULL,
    version          integer  NOT NULL,
    manifest_json    jsonb    NOT NULL,
    manifest_hash    text     NOT NULL,
    target_schema    text     NOT NULL,
    target_function  text     NOT NULL,
    http_method      text     NOT NULL DEFAULT 'POST',
    outcomes         jsonb    NOT NULL,
    required_policy  jsonb    NOT NULL,
    idempotency_mode text     NOT NULL DEFAULT 'none',
    idempotency_scope text    NOT NULL DEFAULT 'none',
    timeout_ms       integer  NOT NULL DEFAULT 5000,
    enabled          boolean  NOT NULL DEFAULT true,
    is_default       boolean  NOT NULL DEFAULT false,
    published_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (module, action, version)
);
ALTER TABLE catalog.actions OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS catalog.action_dispatches (
    correlation_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    request_id     text        NULL,
    module         text        NOT NULL,
    action         text        NOT NULL,
    version        integer     NOT NULL,
    principal      text        NOT NULL,
    payload_hash   text        NOT NULL,
    status         text        NOT NULL,  -- 'OK' or 'ERROR'
    outcome        text        NULL,
    occurred_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE catalog.action_dispatches OWNER TO course_owner;

-- ============================================================
-- 4. IDEMPOTENCY TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS idempotency.records (
    idempotency_key text        NOT NULL,
    scope_key       text        NOT NULL,
    payload_hash    text        NOT NULL,
    response_json   jsonb       NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (scope_key, idempotency_key)
);
ALTER TABLE idempotency.records OWNER TO course_owner;

-- ============================================================
-- 5. PAYMENT TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS payment.operations (
    operation_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    principal      text        NOT NULL,
    request_id     text        NOT NULL,
    operation_kind text        NOT NULL,
    amount         numeric(18,2) NOT NULL,
    currency       text        NOT NULL DEFAULT 'RUB',
    status         text        NOT NULL DEFAULT 'CREATED',
    process_id     uuid        NULL,
    created_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (principal, request_id)
);
ALTER TABLE payment.operations OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS payment.operation_events (
    event_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_id  uuid        NOT NULL REFERENCES payment.operations(operation_id),
    event_type    text        NOT NULL,
    payload_hash  text        NOT NULL,
    occurred_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE payment.operation_events OWNER TO course_owner;

-- ============================================================
-- 6. GRANTS
-- ============================================================

-- course_runtime: execute api.invoke, read catalog + autocheck
GRANT USAGE ON SCHEMA api        TO course_runtime;
GRANT USAGE ON SCHEMA catalog    TO course_runtime;
GRANT USAGE ON SCHEMA autocheck  TO course_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA catalog   TO course_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA autocheck TO course_runtime;

-- course_publication: full DDL/DML on catalog, migrations management
GRANT USAGE, CREATE ON SCHEMA catalog     TO course_publication;
GRANT USAGE, CREATE ON SCHEMA idempotency TO course_publication;
GRANT USAGE, CREATE ON SCHEMA payment     TO course_publication;
GRANT USAGE, CREATE ON SCHEMA autocheck   TO course_publication;
GRANT USAGE, CREATE ON SCHEMA api         TO course_publication;
GRANT ALL    ON ALL TABLES IN SCHEMA catalog     TO course_publication;
GRANT ALL    ON ALL TABLES IN SCHEMA idempotency TO course_publication;
GRANT ALL    ON ALL TABLES IN SCHEMA payment     TO course_publication;
GRANT SELECT ON ALL TABLES IN SCHEMA autocheck   TO course_publication;

-- Default privileges for future tables/objects
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
    GRANT SELECT ON TABLES TO course_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA autocheck
    GRANT SELECT ON TABLES TO course_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
    GRANT ALL ON TABLES TO course_publication;

ALTER DEFAULT PRIVILEGES FOR ROLE course_publication GRANT ALL ON TABLES TO course_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE course_publication GRANT ALL ON ROUTINES TO course_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE course_publication GRANT ALL ON SEQUENCES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner GRANT ALL ON TABLES TO course_publication;
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner GRANT ALL ON ROUTINES TO course_publication;
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner GRANT ALL ON SEQUENCES TO course_publication;

-- Аutomatically enforce ownership of dynamic schemas
CREATE OR REPLACE FUNCTION catalog.trg_set_schema_owner()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO course_owner', obj.object_identity);
    END LOOP;
END;
$$;
ALTER FUNCTION catalog.trg_set_schema_owner() OWNER TO course_owner;

CREATE EVENT TRIGGER enforce_schema_ownership
ON ddl_command_end
WHEN TAG IN ('CREATE SCHEMA')
EXECUTE FUNCTION catalog.trg_set_schema_owner();
