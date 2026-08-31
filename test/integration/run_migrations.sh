#!/bin/sh
set -eu

validator=$1
liquibase_bootstrap=$2
baseline_existing_script=$3
liquibase_bin=$4
project_root=$(CDPATH= cd "$5" && pwd)

case "$("$liquibase_bin" --version 2>&1)" in
    *5.0.4*) ;;
    *)
        echo "test-migrations requires Liquibase Community 5.0.4" >&2
        exit 1
        ;;
esac

container_name="zigma-liquibase-test-$$"
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
jdbc_url="jdbc:postgresql://127.0.0.1:${published_port}/zigma_test"
database_url="postgresql://postgres:postgres@127.0.0.1:${published_port}/zigma_test"

cp -R "$project_root/db" "$temp_dir/db"

LIQUIBASE_BIN="$liquibase_bin" \
LIQUIBASE_URL="$jdbc_url" \
LIQUIBASE_USERNAME=postgres \
LIQUIBASE_PASSWORD=postgres \
LIQUIBASE_CHANGELOG="$temp_dir/db/changelog-root.yaml" \
"$liquibase_bootstrap"

# A second startup must be a no-op and must not duplicate schema objects.
LIQUIBASE_BIN="$liquibase_bin" \
LIQUIBASE_URL="$jdbc_url" \
LIQUIBASE_USERNAME=postgres \
LIQUIBASE_PASSWORD=postgres \
LIQUIBASE_CHANGELOG="$temp_dir/db/changelog-root.yaml" \
"$liquibase_bootstrap"

DATABASE_URL="$database_url" ZIGMA_ACTUAL_SCHEMA=public "$validator"

# Validate-then-mark adoption of a schema previously created from the raw
# bootstrap DDL. This is deliberately a different schema from the normal
# Liquibase startup above.
docker exec "$container_name" psql -U postgres -d zigma_test -v ON_ERROR_STOP=1 \
    -c 'CREATE SCHEMA legacy' >/dev/null
docker exec -i "$container_name" psql -U postgres -d zigma_test -v ON_ERROR_STOP=1 \
    -c 'SET search_path TO legacy, pg_catalog' -f - \
    <"$project_root/db/changes/000001_baseline.sql" >/dev/null
DATABASE_URL="$database_url" \
LIQUIBASE_COMMAND_URL="$jdbc_url" \
LIQUIBASE_COMMAND_USERNAME=postgres \
LIQUIBASE_COMMAND_PASSWORD=postgres \
ZIGMA_ACTUAL_SCHEMA=legacy \
sh "$baseline_existing_script" "$validator" "$liquibase_bin" "$project_root"
legacy_baseline_count=$(docker exec "$container_name" psql -U postgres -d zigma_test -At \
    -c "SELECT count(*) FROM legacy.databasechangelog WHERE id = '000001_baseline' AND author = 'zigma'")
if [ "$legacy_baseline_count" -ne 1 ]; then
    echo "baseline-existing did not mark exactly the initial baseline" >&2
    exit 1
fi

# A compact, independent history exercises the PostgreSQL operations that
# require a manually resolved draft: rename, backfill, USING cast, PK change,
# plus automatically draftable table/column/UK/FK/nullability changes.
mkdir -p "$temp_dir/migration-case/changes"
printf '%s\n' \
    'databaseChangeLog:' \
    '  - includeAll:' \
    '      path: changes' \
    '      relativeToChangelogFile: true' \
    >"$temp_dir/migration-case/changelog-root.yaml"
printf '%s\n' \
    '--liquibase formatted sql' \
    '--changeset zigma:000001_case_baseline' \
    'CREATE TABLE migration_parent (id BIGINT NOT NULL, old_name TEXT NOT NULL, CONSTRAINT pk_migration_parent PRIMARY KEY (id));' \
    'CREATE TABLE migration_child (id BIGINT NOT NULL, note TEXT NOT NULL, CONSTRAINT pk_migration_child PRIMARY KEY (id));' \
    >"$temp_dir/migration-case/changes/000001_case_baseline.sql"
printf '%s\n' \
    '--liquibase formatted sql' \
    '--changeset zigma:000002_representative_changes' \
    'ALTER TABLE migration_parent RENAME COLUMN old_name TO name;' \
    'ALTER TABLE migration_parent ADD COLUMN code BIGINT;' \
    'UPDATE migration_parent SET code = id WHERE code IS NULL;' \
    'ALTER TABLE migration_parent ALTER COLUMN code SET NOT NULL;' \
    'ALTER TABLE migration_parent DROP CONSTRAINT pk_migration_parent;' \
    'ALTER TABLE migration_parent ADD CONSTRAINT pk_migration_parent PRIMARY KEY (id, code);' \
    'ALTER TABLE migration_parent ADD CONSTRAINT uk_migration_parent_id UNIQUE (id);' \
    'ALTER TABLE migration_parent ADD CONSTRAINT uk_migration_parent_name UNIQUE (name);' \
    'ALTER TABLE migration_child ADD COLUMN optional_note TEXT;' \
    'ALTER TABLE migration_child ALTER COLUMN note DROP NOT NULL;' \
    "ALTER TABLE migration_child ALTER COLUMN note TYPE BIGINT USING NULLIF(note, '')::BIGINT;" \
    'ALTER TABLE migration_child ADD COLUMN parent_id BIGINT;' \
    'ALTER TABLE migration_child ADD CONSTRAINT fk_migration_child_parent FOREIGN KEY (parent_id) REFERENCES migration_parent (id);' \
    'CREATE TABLE migration_added (id BIGINT NOT NULL, CONSTRAINT pk_migration_added PRIMARY KEY (id));' \
    >"$temp_dir/migration-case/changes/000002_representative_changes.sql"
docker exec "$container_name" psql -U postgres -d zigma_test -v ON_ERROR_STOP=1 \
    -c 'CREATE SCHEMA migration_case' >/dev/null
LIQUIBASE_COMMAND_URL="$jdbc_url" \
LIQUIBASE_COMMAND_USERNAME=postgres \
LIQUIBASE_COMMAND_PASSWORD=postgres \
"$liquibase_bin" --changelog-file="$temp_dir/migration-case/changelog-root.yaml" \
    --default-schema-name=migration_case update >/dev/null
docker exec "$container_name" psql -U postgres -d zigma_test -v ON_ERROR_STOP=1 -c \
    "DO \$\$ BEGIN
       IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='migration_case' AND table_name='migration_parent' AND column_name='old_name') THEN RAISE EXCEPTION 'rename was not applied'; END IF;
       IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='migration_case' AND table_name='migration_parent' AND column_name='name') THEN RAISE EXCEPTION 'renamed column is absent'; END IF;
       IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='migration_case' AND table_name='migration_parent' AND column_name='code' AND is_nullable='NO') THEN RAISE EXCEPTION 'backfilled NOT NULL column differs'; END IF;
       IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='migration_case' AND table_name='migration_child' AND column_name='note' AND data_type='bigint' AND is_nullable='YES') THEN RAISE EXCEPTION 'USING cast or nullability differs'; END IF;
       IF NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='migration_case' AND c.conname='pk_migration_parent' AND c.contype='p' AND array_length(c.conkey,1)=2) THEN RAISE EXCEPTION 'composite PK differs'; END IF;
       IF NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='migration_case' AND c.conname='uk_migration_parent_name' AND c.contype='u') THEN RAISE EXCEPTION 'UK is absent'; END IF;
       IF NOT EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='migration_case' AND c.conname='fk_migration_child_parent' AND c.contype='f') THEN RAISE EXCEPTION 'FK is absent'; END IF;
       IF to_regclass('migration_case.migration_added') IS NULL THEN RAISE EXCEPTION 'new table is absent'; END IF;
     END \$\$;" >/dev/null

# PostgreSQL DDL is transactional: neither the first statement nor the
# changeset history row may survive the invalid second statement.
printf '%s\n' \
    '--liquibase formatted sql' \
    '--changeset zigma:000003_intentional_failure' \
    'CREATE TABLE rollback_probe (id BIGINT);' \
    'THIS IS NOT VALID SQL;' \
    >"$temp_dir/migration-case/changes/000003_intentional_failure.sql"
if LIQUIBASE_COMMAND_URL="$jdbc_url" \
   LIQUIBASE_COMMAND_USERNAME=postgres \
   LIQUIBASE_COMMAND_PASSWORD=postgres \
   "$liquibase_bin" --changelog-file="$temp_dir/migration-case/changelog-root.yaml" \
       --default-schema-name=migration_case update >/dev/null 2>&1; then
    echo "Liquibase unexpectedly accepted a failing changeset" >&2
    exit 1
fi
failed_state=$(docker exec "$container_name" psql -U postgres -d zigma_test -At -c \
    "SELECT format('%s:%s', (to_regclass('migration_case.rollback_probe') IS NULL)::int, count(*)) FROM migration_case.databasechangelog WHERE id='000003_intentional_failure'")
if [ "$failed_state" != "1:0" ]; then
    echo "failed PostgreSQL changeset was not fully rolled back: $failed_state" >&2
    exit 1
fi

# Mutating an already applied changeset must produce a checksum failure.
printf '\nSELECT 2;\n' >>"$temp_dir/db/changes/000001_baseline.sql"
if LIQUIBASE_COMMAND_URL="$jdbc_url" \
   LIQUIBASE_COMMAND_USERNAME=postgres \
   LIQUIBASE_COMMAND_PASSWORD=postgres \
   "$liquibase_bin" --changelog-file="$temp_dir/db/changelog-root.yaml" update >/dev/null 2>&1; then
    echo "Liquibase unexpectedly accepted a modified changeset" >&2
    exit 1
fi
