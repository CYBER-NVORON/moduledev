-- Administrative bootstrap, also used explicitly when upgrading an existing volume.
-- check_pass is a psql variable; no secret is stored in a migration or image layer.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='autocheck_reader') THEN
        CREATE ROLE autocheck_reader LOGIN;
    END IF;
END $$;
SELECT format('ALTER ROLE autocheck_reader PASSWORD %L',NULLIF(:'check_pass','')) \gexec
ALTER ROLE autocheck_reader SET default_transaction_read_only=on;
GRANT CONNECT ON DATABASE course TO autocheck_reader;
REVOKE TEMPORARY ON DATABASE course FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE course_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Upgrades may have functions created before these defaults were installed.
SELECT format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC',nspname)
FROM pg_namespace WHERE nspname IN ('api','catalog','workflow','payment','operation','delivery','receipt','training','diagnostics') \gexec
