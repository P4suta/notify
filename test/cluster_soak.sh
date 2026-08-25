#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

for required_command in curl docker jq node; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

subscriptions=${NOTIFY_SOAK_SUBSCRIPTIONS:-10000}
topics=${NOTIFY_SOAK_TOPICS:-1000}
publish_rate=${NOTIFY_SOAK_PUBLISH_RATE:-500}
duration_seconds=${NOTIFY_SOAK_DURATION_SECONDS:-600}
settle_seconds=${NOTIFY_SOAK_SETTLE_SECONDS:-60}
connect_timeout_seconds=${NOTIFY_SOAK_CONNECT_TIMEOUT_SECONDS:-180}
format=${NOTIFY_SOAK_FORMAT:-json}
case $format in
  json | raw | sse | websocket) ;;
  *)
    echo "NOTIFY_SOAK_FORMAT must be json, raw, sse, or websocket" >&2
    exit 2
    ;;
esac
for numeric_value in \
  "$subscriptions" \
  "$topics" \
  "$publish_rate" \
  "$duration_seconds" \
  "$settle_seconds" \
  "$connect_timeout_seconds"; do
  if [[ ! $numeric_value =~ ^[1-9][0-9]*$ ]]; then
    echo "soak scale values must be positive integers" >&2
    exit 2
  fi
done
if ((topics > subscriptions)); then
  echo "NOTIFY_SOAK_TOPICS cannot exceed NOTIFY_SOAK_SUBSCRIPTIONS" >&2
  exit 2
fi

minimum_nofile=$((subscriptions + 4096))
current_nofile=$(ulimit -n)
if [[ $current_nofile != unlimited ]] && ((current_nofile < minimum_nofile)); then
  if ! ulimit -n "$minimum_nofile" 2>/dev/null; then
    echo "open-file limit $current_nofile is below required $minimum_nofile" >&2
    exit 2
  fi
fi

run_suffix="$(date +%s)-$$"
readonly run_suffix
project_name=${NOTIFY_SOAK_PROJECT_NAME:-"notify-soak-$run_suffix"}
if [[ ! $project_name =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "invalid NOTIFY_SOAK_PROJECT_NAME: $project_name" >&2
  exit 2
fi
readonly project_name
export NOTIFY_CLUSTER_IMAGE="notify:soak-$run_suffix"
readonly NOTIFY_CLUSTER_IMAGE
readonly -a compose=(
  docker compose
  --project-name "$project_name"
  -f "$root/compose.cluster.yml"
)

project_containers=$(
  docker container ls --all --quiet \
    --filter "label=com.docker.compose.project=$project_name"
)
project_networks=$(
  docker network ls --quiet \
    --filter "label=com.docker.compose.project=$project_name"
)
project_volumes=$(
  docker volume ls --quiet \
    --filter "label=com.docker.compose.project=$project_name"
)
if [[ -n $project_containers || -n $project_networks || -n $project_volumes ]]; then
  echo "refusing existing Compose project resources: $project_name" >&2
  exit 2
fi
if docker image inspect "$NOTIFY_CLUSTER_IMAGE" >/dev/null 2>&1; then
  echo "refusing existing local image: $NOTIFY_CLUSTER_IMAGE" >&2
  exit 2
fi

temporary_root=${TMPDIR:-/tmp}
readonly temporary_root
temporary_directory=$(mktemp -d "$temporary_root/notify-soak.XXXXXX")
readonly temporary_directory
if [[ -n ${NOTIFY_SOAK_REPORT_DIRECTORY:-} ]]; then
  report_directory=$NOTIFY_SOAK_REPORT_DIRECTORY
else
  report_directory=$temporary_directory/report
fi
readonly report_directory
if [[ -e $report_directory ]]; then
  echo "refusing existing soak report path: $report_directory" >&2
  find "$temporary_directory" -depth -delete
  exit 2
fi
mkdir -p "$report_directory"
: >"$report_directory/resources.ndjson"
resource_sampler_pid=""

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT/signal traps.
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n $resource_sampler_pid ]] \
    && kill -0 "$resource_sampler_pid" 2>/dev/null; then
    kill "$resource_sampler_pid" 2>/dev/null || true
    wait "$resource_sampler_pid" 2>/dev/null || true
  fi
  if ((status != 0)); then
    "${compose[@]}" logs --no-color --tail 500 >&2 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "$NOTIFY_CLUSTER_IMAGE" >/dev/null 2>&1 || true
  if [[ $temporary_directory == "$temporary_root"/notify-soak.* ]] \
    && [[ -d $temporary_directory ]]; then
    find "$temporary_directory" -depth -delete
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_for_health() {
  local url=$1
  local attempt
  for ((attempt = 0; attempt < 180; attempt += 1)); do
    if curl --fail --silent --show-error "$url/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "node did not become healthy: $url" >&2
  return 1
}

readonly node_a=http://127.0.0.1:8080
readonly node_b=http://127.0.0.1:8081
readonly node_c=http://127.0.0.1:8082
planned_publishes=$((publish_rate * duration_seconds))
export NOTIFY_CLUSTER_RATE_LIMIT_REQUESTS=$((
  subscriptions + planned_publishes + 100000
))
export NOTIFY_CLUSTER_RATE_LIMIT_SUBSCRIPTIONS=$((subscriptions + 10000))
export NOTIFY_CLUSTER_RATE_LIMIT_TOPIC_CREATIONS=$((
  planned_publishes + topics + 100000
))
export NOTIFY_CLUSTER_RATE_LIMIT_WINDOW_SECONDS=$((
  connect_timeout_seconds + duration_seconds + settle_seconds + 300
))

"${compose[@]}" build notify-a
"${compose[@]}" up --detach --wait --wait-timeout 180 postgres minio
"${compose[@]}" run --rm --no-deps \
  --env "NOTIFY_PASSWORD=cluster soak test password" \
  notify-a run setup \
  --username soak_admin \
  --anonymous-access read-write >"$temporary_directory/setup.log"
grep -Fx "setup complete; administrator soak_admin created" \
  "$temporary_directory/setup.log" >/dev/null
"${compose[@]}" up --detach --no-build --wait --wait-timeout 240 \
  notify-a notify-b notify-c
wait_for_health "$node_a"
wait_for_health "$node_b"
wait_for_health "$node_c"

container_names=(
  "$project_name-notify-a-1"
  "$project_name-notify-b-1"
  "$project_name-notify-c-1"
  "$project_name-postgres-1"
  "$project_name-minio-1"
)

sample_resources() {
  local sampled_at
  while true; do
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker stats --no-stream --format '{{json .}}' "${container_names[@]}" \
      | jq -c --arg sampled_at "$sampled_at" \
        '{sampled_at: $sampled_at, stats: .}' \
        >>"$report_directory/resources.ndjson"
    sleep 5
  done
}
sample_resources &
resource_sampler_pid=$!

docker_server_version=$(docker version --format '{{.Server.Version}}')
compose_version=$(docker compose version --short)
postgres_version=$(
  "${compose[@]}" exec -T postgres \
    psql --username notify --dbname notify --tuples-only --no-align \
    --command 'SHOW server_version'
)
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg kernel "$(uname -srvmo)" \
  --arg docker "$docker_server_version" \
  --arg compose "$compose_version" \
  --arg postgres "$postgres_version" \
  '{generated_at: $generated_at, kernel: $kernel, docker: $docker,
    docker_compose: $compose, postgresql: $postgres}' \
  >"$report_directory/environment.json"

export NOTIFY_SOAK_SUBSCRIPTIONS=$subscriptions
export NOTIFY_SOAK_TOPICS=$topics
export NOTIFY_SOAK_PUBLISH_RATE=$publish_rate
export NOTIFY_SOAK_DURATION_SECONDS=$duration_seconds
export NOTIFY_SOAK_SETTLE_SECONDS=$settle_seconds
export NOTIFY_SOAK_CONNECT_TIMEOUT_SECONDS=$connect_timeout_seconds
export NOTIFY_SOAK_FORMAT=$format
export NOTIFY_SOAK_ENDPOINTS="$node_a,$node_b,$node_c"
topic_prefix="soak-$$"
readonly topic_prefix
export NOTIFY_SOAK_TOPIC_PREFIX="$topic_prefix"
export NOTIFY_SOAK_REPORT_PATH="$report_directory/report.json"
export NOTIFY_SOAK_SEQUENCE_PATH="$report_directory/observed-sequences.ndjson"

driver_status=0
node --max-old-space-size=4096 test/cluster_soak.mjs \
  >"$temporary_directory/driver.json" || driver_status=$?

event_log_path="$report_directory/event-log.tsv"
readonly event_log_path
"${compose[@]}" exec -T postgres \
  psql --username notify --dbname notify --tuples-only --no-align \
  --command "COPY (
    SELECT topic, message_id
    FROM notify_event_log
    WHERE topic LIKE '$topic_prefix-%'
    ORDER BY sequence
  ) TO STDOUT WITH (FORMAT text)" >"$event_log_path"

database_path="$report_directory/database.json"
readonly database_path
"${compose[@]}" exec -T postgres \
  psql --username notify --dbname notify --tuples-only --no-align \
  --command "SELECT json_build_object(
    'messages', (SELECT COUNT(*) FROM notify_messages),
    'events', (SELECT COUNT(*) FROM notify_event_log),
    'event_head', (SELECT COALESCE(MAX(sequence), 0) FROM notify_event_log),
    'node_cursor_count', (SELECT COUNT(*) FROM notify_node_cursors),
    'node_cursors', (SELECT COALESCE(
      json_agg(json_build_object(
        'node_id', node_id,
        'sequence', sequence
      ) ORDER BY node_id),
      '[]'::json
    ) FROM notify_node_cursors),
    'database_bytes', pg_database_size(current_database()))" \
  | jq . >"$database_path"
oracle_status=0
node test/cluster_soak_oracle.mjs \
  "$report_directory/report.json" \
  "$report_directory/observed-sequences.ndjson" \
  "$event_log_path" \
  "$database_path" || oracle_status=$?
if ((driver_status != 0 || oracle_status != 0)); then
  driver_status=1
fi
jq . "$report_directory/report.json"

if kill -0 "$resource_sampler_pid" 2>/dev/null; then
  kill "$resource_sampler_pid" 2>/dev/null || true
  wait "$resource_sampler_pid" 2>/dev/null || true
fi
resource_sampler_pid=""

docker inspect --format '{{json .State}}' "${container_names[@]}" \
  | jq -s . >"$report_directory/container-states.json"
if ! jq -e 'all(.[]; .OOMKilled == false and .Running == true)' \
  "$report_directory/container-states.json" >/dev/null; then
  echo "a soak dependency stopped or was OOM-killed" >&2
  driver_status=1
fi

echo "soak reports: $report_directory"
exit "$driver_status"
