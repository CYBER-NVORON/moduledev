#!/bin/sh
set -e

[ -z "$COURSE_RUNTIME_PASSWORD" ] && echo "COURSE_RUNTIME_PASSWORD not set" >&2 && exit 1
[ -z "$COURSE_PUBLISHER_PASSWORD" ] && echo "COURSE_PUBLISHER_PASSWORD not set" >&2 && exit 1
[ -z "$COURSE_MIGRATOR_PASSWORD" ] && echo "COURSE_MIGRATOR_PASSWORD not set" >&2 && exit 1
[ -z "$COURSE_WORKER_PASSWORD" ] && echo "COURSE_WORKER_PASSWORD not set" >&2 && exit 1
[ -z "$COURSE_OUTBOX_PASSWORD" ] && echo "COURSE_OUTBOX_PASSWORD not set" >&2 && exit 1
[ -z "$COURSE_INBOX_PASSWORD" ] && echo "COURSE_INBOX_PASSWORD not set" >&2 && exit 1

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v rt_pass="$COURSE_RUNTIME_PASSWORD" \
  -v pub_pass="$COURSE_PUBLISHER_PASSWORD" \
  -v mig_pass="$COURSE_MIGRATOR_PASSWORD" \
  -v wkr_pass="$COURSE_WORKER_PASSWORD" \
  -v out_pass="$COURSE_OUTBOX_PASSWORD" \
  -v in_pass="$COURSE_INBOX_PASSWORD" <<'EOSQL'
    CREATE ROLE course_owner NOLOGIN;
    CREATE ROLE course_runtime LOGIN PASSWORD :'rt_pass';
    CREATE ROLE course_publication LOGIN PASSWORD :'pub_pass';
    CREATE ROLE course_migration LOGIN PASSWORD :'mig_pass';
    CREATE ROLE workflow_worker LOGIN PASSWORD :'wkr_pass';
    CREATE ROLE outbox_dispatcher LOGIN PASSWORD :'out_pass';
    CREATE ROLE inbox_reconciler LOGIN PASSWORD :'in_pass';
EOSQL
