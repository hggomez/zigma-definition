#!/bin/sh
set -eu

validator=$1
liquibase_bin=$2
project_root=$(CDPATH= cd "$3" && pwd)

if [ -z "${DATABASE_URL:-}" ] || [ -z "${LIQUIBASE_COMMAND_URL:-}" ]; then
    echo "DATABASE_URL (libpq) and LIQUIBASE_COMMAND_URL (JDBC) are required" >&2
    exit 1
fi

change_count=$(find "$project_root/db/changes" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')
if [ "$change_count" -ne 1 ] || [ ! -f "$project_root/db/changes/000001_baseline.sql" ]; then
    echo "baseline-existing is allowed only while history contains the initial baseline" >&2
    exit 1
fi

ZIGMA_ACTUAL_SCHEMA="${ZIGMA_ACTUAL_SCHEMA:-public}" "$validator" --baseline-adoption

"$liquibase_bin" \
    --changelog-file="$project_root/db/changelog-root.yaml" \
    --default-schema-name="${ZIGMA_ACTUAL_SCHEMA:-public}" \
    changelog-sync
