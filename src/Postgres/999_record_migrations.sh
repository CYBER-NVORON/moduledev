#!/bin/sh
set -eu

# Initdb has just applied these SQL files. Record the same normalized checksums
# as the CLI so the startup migrator can safely handle later deployments.
for migration in /docker-entrypoint-initdb.d/*.sql; do
    checksum=$(sed 's/\r$//' "$migration" | sha256sum | cut -d ' ' -f 1)
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -v filename="$(basename "$migration")" -v checksum="$checksum" <<'SQL'
INSERT INTO catalog.migrations(filename, checksum_sha256)
VALUES (:'filename', :'checksum') ON CONFLICT (filename) DO NOTHING;
SQL
done
