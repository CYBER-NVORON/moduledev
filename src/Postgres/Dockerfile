FROM postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685
COPY migrations/ /docker-entrypoint-initdb.d/
COPY src/Postgres/000_set_passwords.sh /docker-entrypoint-initdb.d/000_set_passwords.sh
RUN sed -i 's/\r$//' /docker-entrypoint-initdb.d/000_set_passwords.sh && chmod +x /docker-entrypoint-initdb.d/000_set_passwords.sh
