#!/bin/sh
set -eu

migration_tool=$1
validator=$2
liquibase_bin=$3
project_root=$(CDPATH= cd "$4" && pwd)

draft_count=$(find "$project_root/db/drafts" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')
if [ "$draft_count" -ne 1 ]; then
    echo "accept-migration requires exactly one SQL draft" >&2
    exit 1
fi
draft_file=$(find "$project_root/db/drafts" -maxdepth 1 -type f -name '*.sql')
if grep -Fq -- 'ZIGMA-BLOCKER:' "$draft_file"; then
    echo "accept-migration refuses unresolved ZIGMA-BLOCKER markers" >&2
    exit 1
fi

container_name="zigma-migration-$$"
temp_dir=$(mktemp -d)
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
}
trap cleanup EXIT INT TERM

docker run --detach --rm \
    --name "$container_name" \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=zigma_test \
    -p 127.0.0.1::5432 \
    postgres:18.4-alpine3.24 >/dev/null

until docker exec "$container_name" pg_isready -U postgres -d zigma_test >/dev/null 2>&1; do
    sleep 1
done
published_port=$(docker port "$container_name" 5432/tcp | sed -n 's/.*://p')
docker exec "$container_name" psql -U postgres -d zigma_test -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA actual' >/dev/null

temp_changelog="$temp_dir/changelog-root.yaml"
printf '%s\n' \
    'databaseChangeLog:' \
    '  - include:' \
    "      file: $project_root/db/changelog-root.yaml" \
    '  - include:' \
    "      file: $draft_file" >"$temp_changelog"

LIQUIBASE_COMMAND_URL="jdbc:postgresql://127.0.0.1:${published_port}/zigma_test" \
LIQUIBASE_COMMAND_USERNAME=postgres \
LIQUIBASE_COMMAND_PASSWORD=postgres \
"$liquibase_bin" \
    --changelog-file="$temp_changelog" \
    --default-schema-name=actual \
    update

DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${published_port}/zigma_test" \
ZIGMA_ACTUAL_SCHEMA=actual \
"$validator"

"$migration_tool" accept-files
