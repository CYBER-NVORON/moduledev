-- 001_init_roles_and_catalog.sql
-- Phase 1: Roles, schemas, core tables, catalog, idempotency, payment

-- ============================================================
-- 1. ROLES (idempotent with IF NOT EXISTS)
-- ============================================================
DO $$
DECLARE
    rt_pass text := current_setting('course.runtime_pwd', true);
    pub_pass text := current_setting('course.publication_pwd', true);
    mig_pass text := current_setting('course.migration_pwd', true);
BEGIN
  -- Создаем роли без паролей (или не трогаем, если есть)
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_owner') THEN
    CREATE ROLE course_owner NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_runtime') THEN
    CREATE ROLE course_runtime LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_publication') THEN
    CREATE ROLE course_publication LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'course_migration') THEN
    CREATE ROLE course_migration LOGIN;
  END IF;

  -- Безопасно обновляем пароли, если они были переданы в сессию
  IF rt_pass IS NOT NULL AND rt_pass <> '' THEN
      EXECUTE format('ALTER ROLE course_runtime WITH PASSWORD %L', rt_pass);
  END IF;
  IF pub_pass IS NOT NULL AND pub_pass <> '' THEN
      EXECUTE format('ALTER ROLE course_publication WITH PASSWORD %L', pub_pass);
  END IF;
  IF mig_pass IS NOT NULL AND mig_pass <> '' THEN
      EXECUTE format('ALTER ROLE course_migration WITH PASSWORD %L', mig_pass);
  END IF;
END $$;

GRANT ALL ON DATABASE course TO course_owner;

GRANT ALL ON DATABASE course TO course_publication;

GRANT CONNECT, TEMPORARY ON DATABASE course TO course_runtime;

GRANT course_owner TO course_migration;

-- ============================================================
-- 2. SCHEMAS
-- ============================================================
CREATE SCHEMA IF NOT EXISTS catalog AUTHORIZATION course_owner;

CREATE SCHEMA IF NOT EXISTS idempotency AUTHORIZATION course_owner;

CREATE SCHEMA IF NOT EXISTS payment AUTHORIZATION course_owner;

CREATE SCHEMA IF NOT EXISTS autocheck AUTHORIZATION course_owner;

CREATE SCHEMA IF NOT EXISTS api AUTHORIZATION course_owner;

-- ============================================================
-- 3. CATALOG TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS catalog.migrations (
    filename text PRIMARY KEY,
    checksum_sha256 text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp ()
);

ALTER TABLE catalog.migrations OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS catalog.actions (
    module text NOT NULL,
    action text NOT NULL,
    version integer NOT NULL,
    manifest_json jsonb NOT NULL,
    manifest_hash text NOT NULL,
    target_schema text NOT NULL,
    target_function text NOT NULL,
    http_method text NOT NULL DEFAULT 'POST',
    outcomes jsonb NOT NULL,
    required_policy jsonb NOT NULL,
    idempotency_mode text NOT NULL DEFAULT 'none',
    idempotency_scope text NOT NULL DEFAULT 'none',
    timeout_ms integer NOT NULL DEFAULT 5000,
    enabled boolean NOT NULL DEFAULT true,
    is_default boolean NOT NULL DEFAULT false,
    published_at timestamptz NOT NULL DEFAULT clock_timestamp (),
    PRIMARY KEY (module, action, version)
);

ALTER TABLE catalog.actions OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS catalog.action_dispatches (
    correlation_id uuid NOT NULL DEFAULT gen_random_uuid (),
    request_id text NULL,
    module text NOT NULL,
    action text NOT NULL,
    version integer NOT NULL,
    principal text NOT NULL,
    payload_hash text NOT NULL,
    status text NOT NULL, -- 'OK' or 'ERROR'
    outcome text NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp ()
);

ALTER TABLE catalog.action_dispatches OWNER TO course_owner;

-- ============================================================
-- 4. IDEMPOTENCY TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS idempotency.records (
    idempotency_key text NOT NULL,
    scope_key text NOT NULL,
    payload_hash text NOT NULL,
    response_json jsonb NOT NULL,
    executed_version integer NOT NULL,
    manifest_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp (),
    PRIMARY KEY (scope_key, idempotency_key)
);

ALTER TABLE idempotency.records OWNER TO course_owner;

-- ============================================================
-- 5. PAYMENT TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS payment.operations (
    operation_id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    principal text NOT NULL,
    request_id text NOT NULL,
    operation_kind text NOT NULL CHECK (
        operation_kind IN (
            'PAYMENT_EXECUTION',
            'PAYMENT_APPROVAL'
        )
    ),
    amount numeric(18, 2) NOT NULL CHECK (amount > 0),
    currency text NOT NULL DEFAULT 'RUB' CHECK (currency = 'RUB'),
    status text NOT NULL DEFAULT 'CREATED' CHECK (
        status IN (
            'CREATED',
            'PROCESSING',
            'COMPLETED',
            'REJECTED'
        )
    ),
    process_id uuid NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp (),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp (),
    UNIQUE (principal, request_id)
);

ALTER TABLE payment.operations OWNER TO course_owner;

CREATE TABLE IF NOT EXISTS payment.operation_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid (),
    operation_id uuid NOT NULL REFERENCES payment.operations (operation_id),
    event_type text NOT NULL,
    payload_hash text NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp ()
);

ALTER TABLE payment.operation_events OWNER TO course_owner;

-- Immutability for payment.operations
CREATE OR REPLACE FUNCTION payment.trg_operations_immutability()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.operation_id <> NEW.operation_id OR
       OLD.principal <> NEW.principal OR
       OLD.request_id <> NEW.request_id OR
       OLD.operation_kind <> NEW.operation_kind OR
       OLD.amount <> NEW.amount OR
       OLD.currency <> NEW.currency OR
       OLD.created_at <> NEW.created_at THEN
        RAISE EXCEPTION 'Immutable columns cannot be modified';
    END IF;
    
    -- Status transition guards
    IF OLD.status = 'CREATED' AND NEW.status NOT IN ('CREATED', 'PROCESSING', 'REJECTED') THEN
        RAISE EXCEPTION 'Invalid status transition from CREATED';
    END IF;
    IF OLD.status = 'PROCESSING' AND NEW.status NOT IN ('PROCESSING', 'COMPLETED', 'REJECTED') THEN
        RAISE EXCEPTION 'Invalid status transition from PROCESSING';
    END IF;
    IF OLD.status IN ('COMPLETED', 'REJECTED') AND NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'Final status cannot be changed';
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION payment.trg_operations_immutability() OWNER TO course_owner;

DROP TRIGGER IF EXISTS trg_operations_immutability_check ON payment.operations;

CREATE TRIGGER trg_operations_immutability_check
BEFORE UPDATE ON payment.operations
FOR EACH ROW EXECUTE FUNCTION payment.trg_operations_immutability();

-- Immutability for payment.operation_events
CREATE OR REPLACE FUNCTION payment.trg_events_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'operation_events is append-only';
END;
$$;

ALTER FUNCTION payment.trg_events_append_only() OWNER TO course_owner;

DROP TRIGGER IF EXISTS trg_events_append_only_check ON payment.operation_events;

CREATE TRIGGER trg_events_append_only_check
BEFORE UPDATE OR DELETE ON payment.operation_events
FOR EACH STATEMENT EXECUTE FUNCTION payment.trg_events_append_only();

-- ============================================================
-- 6. GRANTS
-- ============================================================

-- course_runtime: execute api.invoke, read catalog + autocheck
GRANT USAGE ON SCHEMA api TO course_runtime;

GRANT USAGE ON SCHEMA catalog TO course_runtime;

GRANT USAGE ON SCHEMA autocheck TO course_runtime;

GRANT SELECT ON ALL TABLES IN SCHEMA catalog TO course_runtime;

GRANT SELECT ON ALL TABLES IN SCHEMA autocheck TO course_runtime;

-- course_publication: use routines to modify catalog, can read it
GRANT USAGE ON SCHEMA catalog TO course_publication;

GRANT
SELECT
    ON ALL TABLES IN SCHEMA catalog TO course_publication;

GRANT
SELECT
    ON ALL TABLES IN SCHEMA autocheck TO course_publication;

-- Default privileges for future tables/objects
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
GRANT
SELECT ON TABLES TO course_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA autocheck
GRANT
SELECT ON TABLES TO course_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
GRANT
SELECT ON TABLES TO course_publication;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA autocheck
GRANT
SELECT ON TABLES TO course_publication;

ALTER DEFAULT PRIVILEGES FOR ROLE course_publication
GRANT ALL ON TABLES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_publication
GRANT ALL ON ROUTINES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_publication
GRANT ALL ON SEQUENCES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_migration
GRANT ALL ON TABLES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_migration
GRANT ALL ON ROUTINES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_migration
GRANT ALL ON SEQUENCES TO course_owner;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
GRANT
EXECUTE ON ROUTINES TO course_publication;

ALTER DEFAULT PRIVILEGES FOR ROLE course_owner IN SCHEMA catalog
GRANT USAGE,
SELECT ON SEQUENCES TO course_publication;

-- Аutomatically enforce ownership of dynamic schemas
CREATE OR REPLACE FUNCTION catalog.trg_set_object_owner()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag IN ('CREATE SCHEMA', 'CREATE FUNCTION')
    LOOP
        IF obj.object_type = 'schema' THEN
            EXECUTE format('ALTER SCHEMA %I OWNER TO course_owner', obj.object_identity);
        ELSIF obj.object_type = 'function' THEN
            EXECUTE format('ALTER FUNCTION %s OWNER TO course_owner', obj.object_identity);
        END IF;
    END LOOP;
END;
$$;

ALTER FUNCTION catalog.trg_set_object_owner() OWNER TO postgres;

ALTER FUNCTION catalog.trg_set_object_owner() SECURITY DEFINER;

DROP EVENT TRIGGER IF EXISTS enforce_schema_ownership;

DROP EVENT TRIGGER IF EXISTS enforce_object_ownership;

CREATE EVENT TRIGGER enforce_object_ownership
ON ddl_command_end
WHEN TAG IN ('CREATE SCHEMA', 'CREATE FUNCTION')
EXECUTE FUNCTION catalog.trg_set_object_owner();