#!/bin/sh
set -e

[ -z "$RUNTIME_PASSWORD" ] && echo "RUNTIME_PASSWORD not set" >&2 && exit 1
[ -z "$PUBLICATION_PASSWORD" ] && echo "PUBLICATION_PASSWORD not set" >&2 && exit 1
[ -z "$MIGRATION_PASSWORD" ] && echo "MIGRATION_PASSWORD not set" >&2 && exit 1
[ -z "$WORKER_PASSWORD" ] && echo "WORKER_PASSWORD not set" >&2 && exit 1

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v rt_pass="$RUNTIME_PASSWORD" \
  -v pub_pass="$PUBLICATION_PASSWORD" \
  -v mig_pass="$MIGRATION_PASSWORD" \
  -v wkr_pass="$WORKER_PASSWORD" <<'EOSQL'
    CREATE ROLE course_owner NOLOGIN;
    CREATE ROLE course_runtime LOGIN PASSWORD :'rt_pass';
    CREATE ROLE course_publication LOGIN PASSWORD :'pub_pass';
    CREATE ROLE course_migration LOGIN PASSWORD :'mig_pass';
    CREATE ROLE workflow_worker LOGIN PASSWORD :'wkr_pass';
EOSQL
