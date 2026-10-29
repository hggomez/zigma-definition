#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: run_rest_postgres.sh <bootstrap-binary> <rest-server-binary>" >&2
    exit 2
fi

bootstrap_binary=$1
server_binary=$2
container_name="zigma-rest-postgres-$$"
server_pid=""
server_log="${TMPDIR:-/tmp}/zigma-rest-server-$$.log"

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" >/dev/null 2>&1 || true
    fi
    docker rm --force "$container_name" >/dev/null 2>&1 || true
    rm -f "$server_log"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

docker run \
    --detach \
    --rm \
    --name "$container_name" \
    --publish 127.0.0.1::5432 \
    --env POSTGRES_DB=zigma_rest_test \
    --env POSTGRES_USER=postgres \
    --env POSTGRES_PASSWORD=postgres \
    postgres:18.4-alpine3.24 >/dev/null

attempt=0
until docker exec "$container_name" pg_isready --username postgres --dbname zigma_rest_test >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "PostgreSQL did not become ready within 60 seconds" >&2
        exit 1
    fi
    sleep 1
done

published_address=$(docker port "$container_name" 5432/tcp)
published_port=${published_address##*:}
database_url="postgresql://postgres:postgres@127.0.0.1:${published_port}/zigma_rest_test"
DATABASE_URL="$database_url" "$bootstrap_binary"

http_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
DATABASE_URL="$database_url" HTTP_PORT="$http_port" "$server_binary" >"$server_log" 2>&1 &
server_pid=$!
base_url="http://127.0.0.1:${http_port}/api"

attempt=0
until curl --silent --show-error --output /dev/null "$base_url/materias" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo "REST server did not become ready" >&2
        cat "$server_log" >&2
        exit 1
    fi
    sleep 1
done

request() {
    response=$(curl --silent --show-error --write-out '\n%{http_code}' "$@")
    HTTP_STATUS=${response##*
}
    HTTP_BODY=${response%
*}
}

expect_response() {
    expected_status=$1
    expected_body=$2
    if [ "$HTTP_STATUS" != "$expected_status" ] || [ "$HTTP_BODY" != "$expected_body" ]; then
        echo "unexpected HTTP response" >&2
        echo "expected: $expected_status $expected_body" >&2
        echo "actual:   $HTTP_STATUS $HTTP_BODY" >&2
        cat "$server_log" >&2
        exit 1
    fi
}

request "$base_url/materias"
expect_response 200 '[]'

# Casos compartidos con el backend en memoria, sobre este proceso descartable.
python3 "$(dirname "$0")/docente_age_http.py" "$base_url"

oversized_body=$(python3 -c 'print("x" * 257)')
request --request POST --header 'content-type: application/json' --data "$oversized_body" "$base_url/materias"
if [ "$HTTP_STATUS" != 413 ]; then
    echo "expected body limit error, received $HTTP_STATUS $HTTP_BODY" >&2
    exit 1
fi

request --request POST --header 'content-type: application/json' \
    --data '{"docente":"d1","nombres":"Ada"}' "$base_url/docentes"
expect_response 201 '{"docente":"d1","apellido":null,"nombres":"Ada","cargo":null,"email":null,"email_alternativo":null,"jefe":null,"telefono":null,"experiencia":null,"esImportador":null,"fecha_nacimiento":null}'

# La regla concreta se ejecuta antes de escribir, también con valores de libpq.
request --request POST --header 'content-type: application/json' \
    --data '{"docente":"d2","nombres":"Grace","cargo":"teorico","experiencia":4}' "$base_url/docentes"
expect_response 422 '{"error":{"code":"teorico_requires_five_years_experience","message":"A docente with cargo '\''teorico'\'' requires at least 5 years of experiencia"}}'
request "$base_url/docentes?docente=d2"
expect_response 200 '[]'

request --request PUT --header 'content-type: application/json' \
    --data '{"cargo":"teorico","experiencia":5,"esImportador":false,"fecha_nacimiento":{"año":1980,"mes":1,"día":1}}' "$base_url/docentes?docente=d1"
expect_response 200 '[{"docente":"d1","apellido":null,"nombres":"Ada","cargo":"teorico","email":null,"email_alternativo":null,"jefe":null,"telefono":null,"experiencia":5,"esImportador":false,"fecha_nacimiento":{"año":1980,"mes":1,"día":1}}]'

request --request PUT --header 'content-type: application/json' \
    --data '{"experiencia":4}' "$base_url/docentes?docente=d1"
expect_response 422 '{"error":{"code":"teorico_requires_five_years_experience","message":"A docente with cargo '\''teorico'\'' requires at least 5 years of experiencia"}}'
request "$base_url/docentes?docente=d1"
expect_response 200 '[{"docente":"d1","apellido":null,"nombres":"Ada","cargo":"teorico","email":null,"email_alternativo":null,"jefe":null,"telefono":null,"experiencia":5,"esImportador":false,"fecha_nacimiento":{"año":1980,"mes":1,"día":1}}]'

request --request POST --header 'content-type: application/json' \
    --data '{"materia":"m1","denominacion":"Álgebra"}' "$base_url/materias"
expect_response 201 '{"materia":"m1","denominacion":"Álgebra"}'

request --request POST --header 'content-type: application/json' \
    --data '{"periodo":"p1"}' "$base_url/periodos"
expect_response 201 '{"periodo":"p1"}'

request --request POST --header 'content-type: application/json' \
    --data '{"periodo":"p1","materia":"m1","docente":"d1"}' "$base_url/cursos"
expect_response 201 '{"periodo":"p1","materia":"m1","docente":"d1"}'

request --request POST --header 'content-type: application/json' \
    --data '{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Introducción"}' "$base_url/clases"
expect_response 201 '{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Introducción"}'

request --get --data-urlencode 'orden=1' --data-urlencode 'materia=m1' --data-urlencode 'periodo=p1' "$base_url/clases"
expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Introducción"}]'

request --request PUT --header 'content-type: application/json' \
    --data '{"tema":"Actualizado"}' "$base_url/clases?orden=1&materia=m1&periodo=p1"
expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Actualizado"}]'

request --get --data-urlencode "tema=x' OR '1'='1" "$base_url/clases"
expect_response 200 '[]'

request --request POST --header 'content-type: application/json' \
    --data '{"materia":"m2","denominacion":"Álgebra"}' "$base_url/materias"
if [ "$HTTP_STATUS" != 409 ]; then
    echo "expected UK conflict, received $HTTP_STATUS $HTTP_BODY" >&2
    exit 1
fi

request --request POST --header 'content-type: application/json' \
    --data '{"periodo":"missing","materia":"m1"}' "$base_url/cursos"
if [ "$HTTP_STATUS" != 409 ]; then
    echo "expected FK conflict, received $HTTP_STATUS $HTTP_BODY" >&2
    exit 1
fi

request --request POST --header 'content-type: application/json' \
    --data '{"materia":"m3"}' "$base_url/materias"
if [ "$HTTP_STATUS" != 400 ]; then
    echo "expected nullability validation error, received $HTTP_STATUS $HTTP_BODY" >&2
    exit 1
fi

request --request POST --header 'content-type: application/json' \
    --data '{"periodo":"p1","materia":"m1","orden":2,"fecha":{"año":2025,"mes":2,"día":30}}' "$base_url/clases"
# El mismo codec rechaza la fecha antes de ejecutar INSERT o UPDATE.
invalid_date_response='{"error":{"code":"invalid_request","message":"Request fields or values are invalid"}}'
expect_response 400 "$invalid_date_response"
request "$base_url/clases?orden=2&materia=m1&periodo=p1"
expect_response 200 '[]'

for invalid_date in '{"año":2025,"mes":2,"día":30}' '{"año":0,"mes":1,"día":1}' '{"año":10000,"mes":1,"día":1}' '"2024-02-29"'; do
    request --request PUT --header 'content-type: application/json' \
        --data "{\"fecha\":$invalid_date}" "$base_url/clases?orden=1&materia=m1&periodo=p1"
    expect_response 400 "$invalid_date_response"
    request "$base_url/clases?orden=1&materia=m1&periodo=p1"
    expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Actualizado"}]'
done

for invalid_filter in '2025-02-30' '{"año":1900,"mes":2,"día":29}'; do
    request --get --data-urlencode "fecha=$invalid_filter" "$base_url/clases"
    expect_response 400 "$invalid_date_response"
done

# Los extremos y febrero bisiesto conservan su JSON; ambos formatos de query funcionan.
for iso_date in 0001-01-01 2000-02-29 9999-12-31; do
    case "$iso_date" in
        0001-01-01) date_json='{"año":1,"mes":1,"día":1}' ;;
        2000-02-29) date_json='{"año":2000,"mes":2,"día":29}' ;;
        9999-12-31) date_json='{"año":9999,"mes":12,"día":31}' ;;
    esac
    expected_clase="[{\"periodo\":\"p1\",\"materia\":\"m1\",\"orden\":1,\"fecha\":$date_json,\"tema\":\"Actualizado\"}]"
    request --request PUT --header 'content-type: application/json' \
        --data "{\"fecha\":$date_json}" "$base_url/clases?orden=1&materia=m1&periodo=p1"
    expect_response 200 "$expected_clase"
    for date_filter in "$iso_date" "$date_json"; do
        request --get --data-urlencode "fecha=$date_filter" "$base_url/clases"
        expect_response 200 "$expected_clase"
    done
done
request --request PUT --header 'content-type: application/json' \
    --data '{"fecha":null}' "$base_url/clases?orden=1&materia=m1&periodo=p1"
expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":null,"tema":"Actualizado"}]'
request --request PUT --header 'content-type: application/json' \
    --data '{"fecha":{"año":2026,"mes":8,"día":31}}' "$base_url/clases?orden=1&materia=m1&periodo=p1"
expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Actualizado"}]'

request --request PUT --header 'content-type: application/json' \
    --data '{"materia":"m2"}' "$base_url/materias?materia=m1"
if [ "$HTTP_STATUS" != 400 ]; then
    echo "expected PK update rejection, received $HTTP_STATUS $HTTP_BODY" >&2
    exit 1
fi

request --request DELETE "$base_url/clases?materia=m1&periodo=p1&orden=1"
expect_response 200 '[{"periodo":"p1","materia":"m1","orden":1,"fecha":{"año":2026,"mes":8,"día":31},"tema":"Actualizado"}]'

request "$base_url/clases"
expect_response 200 '[]'

echo "REST PostgreSQL integration passed"
