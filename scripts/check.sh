#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project="dockerhw-check-$(date +%s)-$$"
tmp_dir=$(mktemp -d)
backup="$root/backups/$project.tar"
stage="preflight"
export HOST_PORT=0 GREETING="Recovery check"

# One project name and explicit paths keep every operation inside this test.
compose() {
    docker compose --project-name "$project" --project-directory "$root" \
        --env-file "$root/.env.example" -f "$root/compose.yaml" "$@"
}

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$result" -ne 0 ]; then
        printf '\nFAIL: stage=%s, exit=%s\n' "$stage" "$result" >&2
        compose logs --no-color --tail 60 >&2 || true
    fi
    if ! compose down --volumes --remove-orphans --rmi local; then
        printf 'FAIL: cleanup of project %s\n' "$project" >&2
        result=1
    fi
    rm -rf "$tmp_dir"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

request() {
    method=$1 path=$2 expected_status=$3
    status=$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
        --request "$method" --output "$tmp_dir/body.json" \
        --write-out '%{http_code}' "$url$path")
    printf '%s %s -> %s ' "$method" "$path" "$status"
    cat "$tmp_dir/body.json"
    printf '\n'
    [ "$status" = "$expected_status" ]
    if [ "$#" -eq 4 ]; then
        compose exec -T app python -c \
            'import json,sys; data=json.load(sys.stdin); assert data["count"] == int(sys.argv[1]), data' \
            "$4" < "$tmp_dir/body.json"
    fi
}

wait_ready() {
    deadline=$(( $(date +%s) + 60 ))
    until curl --fail --silent --connect-timeout 2 --max-time 3 \
        "$url/readyz" > /dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 1
    done
}

printf 'Project: %s\n' "$project"
docker info > /dev/null
docker compose version
mkdir -p "$root/backups"

stage="1: isolated project with empty storage"
printf '\n%s\n' "$stage"
compose up --build -d --wait --wait-timeout 90
url="http://$(compose port app 8000)"
request GET / 200 0

stage="2: increment counter to N=3"
printf '\n%s\n' "$stage"
for count in 1 2 3; do
    request POST /increment 200 "$count"
done
request GET / 200 3

stage="3: recreate only app"
printf '\n%s\n' "$stage"
old_app=$(compose ps -q app)
redis_id=$(compose ps -q redis)
compose up -d --no-deps --force-recreate --wait --wait-timeout 60 app
[ "$(compose ps -q app)" != "$old_app" ]
[ "$(compose ps -q redis)" = "$redis_id" ]
url="http://$(compose port app 8000)"
request GET / 200 3

stage="4a: down/up without deleting volumes"
printf '\n%s\n' "$stage"
compose down
compose up -d --wait --wait-timeout 60
url="http://$(compose port app 8000)"
request GET / 200 3

stage="4b: Redis outage and automatic recovery"
printf '\n%s\n' "$stage"
app_id=$(compose ps -q app)
started_at=$(docker inspect --format '{{.State.StartedAt}}' "$app_id")
compose stop redis
request GET /healthz 200
request GET /readyz 503
request POST /increment 503
compose start redis
wait_ready
request GET / 200 3
request POST /increment 200 4
[ "$(compose ps -q app)" = "$app_id" ]
[ "$(docker inspect --format '{{.State.StartedAt}}' "$app_id")" = "$started_at" ]
printf 'App recovered without restart.\n'

stage="application limits"
printf '\n%s\n' "$stage"
uid=$(compose exec -T app id -u)
[ "$uid" -ne 0 ]
limits=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' "$app_id")
printf 'UID=%s; read_only, RAM bytes, CPU nanocores: %s\n' "$uid" "$limits"
[ "$limits" = 'true 268435456 1000000000' ]

stage="5: consistent external backup"
printf '\n%s\n' "$stage"
compose stop app redis
redis_id=$(compose ps -aq redis)
# Both services are stopped; -a preserves ownership and permission metadata.
docker cp -a "$redis_id:/data/." - > "$backup"
[ -s "$backup" ]
printf 'Backup: %s\n' "$backup"

stage="6: delete original project including volumes"
printf '\n%s\n' "$stage"
compose down --volumes --remove-orphans
[ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$project")" ]
printf 'Original project volumes removed.\n'

stage="restore backup into a new volume"
printf '\n%s\n' "$stage"
compose create redis
redis_id=$(compose ps -aq redis)
docker cp -a - "$redis_id:/data" < "$backup"
compose up -d --wait --wait-timeout 60
url="http://$(compose port app 8000)"
request GET / 200 4
request POST /increment 200 5
printf '\nPASS: all checks and backup restoration completed.\n'
