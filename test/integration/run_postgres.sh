#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: run_postgres.sh <integration-test-binary> <bootstrap-binary> <schema-validator>" >&2
    exit 2
fi

test_binary=$1
bootstrap_binary=$2
schema_validator=$3
container_name="zigma-postgres-integration-$$"
schema_name="zigma_integration_$$"

cleanup() {
    docker rm --force "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

docker run \
    --detach \
    --rm \
    --name "$container_name" \
    --publish 127.0.0.1::5432 \
    --env POSTGRES_DB=zigma_test \
    --env POSTGRES_USER=postgres \
    --env POSTGRES_PASSWORD=postgres \
    postgres:18.4-alpine3.24 >/dev/null

attempt=0
until docker exec "$container_name" pg_isready --username postgres --dbname zigma_test >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "PostgreSQL did not become ready within 60 seconds" >&2
        exit 1
    fi
    sleep 1
done

published_address=$(docker port "$container_name" 5432/tcp)
published_port=${published_address##*:}
database_url="postgresql://postgres:postgres@127.0.0.1:${published_port}/zigma_test"

# Exercise the actual runtime example, including its DATABASE_URL boundary.
DATABASE_URL="$database_url" "$bootstrap_binary"
DATABASE_URL="$database_url" "$bootstrap_binary"

actual_public_tables=$(docker exec "$container_name" psql \
    --username postgres \
    --dbname zigma_test \
    --tuples-only \
    --no-align \
    --command "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")
expected_public_tables="alumnos,clases,cursos,docentes,inscripciones,materias,mesas,opciones,periodos,preguntas,presencias"
if [ "$actual_public_tables" != "$expected_public_tables" ]; then
    echo "bootstrap created unexpected public tables: $actual_public_tables" >&2
    exit 1
fi

DATABASE_URL="$database_url" ZIGMA_ACTUAL_SCHEMA=public "$schema_validator" --baseline-adoption

# Baselining may ignore Liquibase's own tables, but it must reject any history
# beyond the one initial baseline row.
docker exec "$container_name" psql --username postgres --dbname zigma_test \
    --command "CREATE TABLE public.databasechangelog (id TEXT, author TEXT); INSERT INTO public.databasechangelog VALUES ('000002_later', 'zigma');" \
    >/dev/null
if DATABASE_URL="$database_url" ZIGMA_ACTUAL_SCHEMA=public "$schema_validator" --baseline-adoption >/dev/null 2>&1; then
    echo "schema validator unexpectedly accepted later Liquibase history" >&2
    exit 1
fi
docker exec "$container_name" psql --username postgres --dbname zigma_test \
    --command "DROP TABLE public.databasechangelog" >/dev/null

ZIGMA_POSTGRES_URL="$database_url" \
ZIGMA_POSTGRES_SCHEMA="$schema_name" \
    "$test_binary"
