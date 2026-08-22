#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: run_postgres.sh <integration-test-binary>" >&2
    exit 2
fi

test_binary=$1
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

ZIGMA_POSTGRES_URL="postgresql://postgres:postgres@127.0.0.1:${published_port}/zigma_test" \
ZIGMA_POSTGRES_SCHEMA="$schema_name" \
    "$test_binary"
