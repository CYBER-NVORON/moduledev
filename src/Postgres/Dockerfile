FROM postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685
COPY src/Postgres/prepare_database.sql /opt/prepare_database.sql
COPY migrations/ /docker-entrypoint-initdb.d/
COPY src/Postgres/000_set_passwords.sh /docker-entrypoint-initdb.d/000_set_passwords.sh
COPY src/Postgres/999_record_migrations.sh /docker-entrypoint-initdb.d/999_record_migrations.sh
RUN sed -i 's/\r$//' /docker-entrypoint-initdb.d/*.sh && chmod +x /docker-entrypoint-initdb.d/*.sh
