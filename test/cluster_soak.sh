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
resource_sample_seconds=${NOTIFY_SOAK_RESOURCE_SAMPLE_SECONDS:-60}
format=${NOTIFY_SOAK_FORMAT:-json}
scenario=${NOTIFY_BENCHMARK_SCENARIO:-publish}
case $format in
  json | raw | sse | websocket) ;;
  *)
    echo "NOTIFY_SOAK_FORMAT must be json, raw, sse, or websocket" >&2
    exit 2
    ;;
esac
case $scenario in
  publish | webpush-relay | scheduled | slow-provider | attachments) ;;
  *)
    echo "invalid NOTIFY_BENCHMARK_SCENARIO: $scenario" >&2
    exit 2
    ;;
esac
for numeric_value in \
  "$subscriptions" \
  "$topics" \
  "$publish_rate" \
  "$duration_seconds" \
  "$settle_seconds" \
  "$connect_timeout_seconds" \
  "$resource_sample_seconds"; do
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
case $scenario in
  webpush-relay)
    export NOTIFY_CLUSTER_RELAY_URL=http://relay-benchmark:9090
    export NOTIFY_CLUSTER_RELAY_TOKEN=benchmark-relay-token
    export NOTIFY_RELAY_DELAY_MS=0
    ;;
  slow-provider)
    export NOTIFY_CLUSTER_RELAY_URL=http://relay-benchmark:9090
    export NOTIFY_CLUSTER_RELAY_TOKEN=benchmark-relay-token
    export NOTIFY_RELAY_DELAY_MS=250
    ;;
esac

"${compose[@]}" build notify-a
"${compose[@]}" up --detach --wait --wait-timeout 180 postgres minio
case $scenario in
  webpush-relay | slow-provider)
    "${compose[@]}" up --detach --no-build relay-benchmark
    ;;
esac
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
"${compose[@]}" exec -T postgres \
  psql --username notify --dbname notify --set ON_ERROR_STOP=1 \
  --command 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements' \
  --command 'SELECT pg_stat_reset()' \
  --command 'SELECT pg_stat_statements_reset()' >/dev/null

server_containers=(
  "$project_name-notify-a-1"
  "$project_name-notify-b-1"
  "$project_name-notify-c-1"
)
container_names=(
  "${server_containers[@]}"
  "$project_name-postgres-1"
  "$project_name-minio-1"
)
case $scenario in
  webpush-relay | slow-provider)
    container_names+=("$project_name-relay-benchmark-1")
    ;;
esac

cgroup_total() {
  local file=$1
  local field=$2
  local total=0
  local container
  local value
  for container in "${server_containers[@]}"; do
    if [[ -n $field ]]; then
      value=$(docker exec "$container" awk -v field="$field" \
        '$1 == field { print $2 }' "$file")
    else
      value=$(docker exec "$container" cat "$file")
    fi
    total=$((total + value))
  done
  echo "$total"
}

prometheus_metric() {
  local file=$1
  local metric=$2
  awk -v metric="$metric" '
    $1 == metric { value = $2; found = 1 }
    END { if (found) print value; else print 0 }
  ' "$file"
}

sample_resources() {
  local sampled_at
  while true; do
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker stats --no-stream --format '{{json .}}' "${container_names[@]}" \
      | jq -c --arg sampled_at "$sampled_at" \
        '{sampled_at: $sampled_at, stats: .}' \
        >>"$report_directory/resources.ndjson"
    curl --fail --silent --show-error "$node_a/metrics" \
      >"$report_directory/metrics-node-a-latest.prom" || true
    curl --fail --silent --show-error "$node_b/metrics" \
      >"$report_directory/metrics-node-b-latest.prom" || true
    curl --fail --silent --show-error "$node_c/metrics" \
      >"$report_directory/metrics-node-c-latest.prom" || true
    # `docker stats --no-stream` itself samples the daemon for roughly two
    # seconds. A one-minute default keeps that observer below the p95 tail
    # population while still retaining a time series and a final state check.
    sleep "$resource_sample_seconds"
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
  --argjson resource_sample_seconds "$resource_sample_seconds" \
  '{generated_at: $generated_at, kernel: $kernel, docker: $docker,
    docker_compose: $compose, postgresql: $postgres,
    resource_sample_seconds: $resource_sample_seconds}' \
  >"$report_directory/environment.json"

export NOTIFY_SOAK_SUBSCRIPTIONS=$subscriptions
export NOTIFY_SOAK_TOPICS=$topics
export NOTIFY_SOAK_PUBLISH_RATE=$publish_rate
export NOTIFY_SOAK_DURATION_SECONDS=$duration_seconds
export NOTIFY_SOAK_SETTLE_SECONDS=$settle_seconds
export NOTIFY_SOAK_CONNECT_TIMEOUT_SECONDS=$connect_timeout_seconds
export NOTIFY_SOAK_FORMAT=$format
export NOTIFY_SOAK_BACKEND=postgres
export NOTIFY_SOAK_ENDPOINTS="$node_a,$node_b,$node_c"
topic_prefix="soak-$$"
readonly topic_prefix
export NOTIFY_SOAK_TOPIC_PREFIX="$topic_prefix"
export NOTIFY_SOAK_REPORT_PATH="$report_directory/report.json"
export NOTIFY_SOAK_SEQUENCE_PATH="$report_directory/observed-sequences.ndjson"

server_cpu_before_usec=$(cgroup_total /sys/fs/cgroup/cpu.stat usage_usec)
driver_status=0
node --max-old-space-size=4096 test/cluster_soak.mjs \
  >"$temporary_directory/driver.json" || driver_status=$?
server_cpu_after_usec=$(cgroup_total /sys/fs/cgroup/cpu.stat usage_usec)
server_memory_peak_bytes=$(cgroup_total /sys/fs/cgroup/memory.peak "")
curl --fail --silent --show-error "$node_a/metrics" \
  >"$report_directory/metrics-node-a-final.prom" || driver_status=1
curl --fail --silent --show-error "$node_b/metrics" \
  >"$report_directory/metrics-node-b-final.prom" || driver_status=1
curl --fail --silent --show-error "$node_c/metrics" \
  >"$report_directory/metrics-node-c-final.prom" || driver_status=1
beam_run_queue=0
beam_mailbox_messages=0
beam_max_mailbox_messages=0
beam_processes=0
scheduler_delay_milliseconds=0
for metrics_file in \
  "$report_directory/metrics-node-a-final.prom" \
  "$report_directory/metrics-node-b-final.prom" \
  "$report_directory/metrics-node-c-final.prom"; do
  value=$(prometheus_metric "$metrics_file" notify_beam_run_queue)
  beam_run_queue=$((beam_run_queue + value))
  value=$(prometheus_metric "$metrics_file" notify_beam_mailbox_messages)
  beam_mailbox_messages=$((beam_mailbox_messages + value))
  value=$(prometheus_metric "$metrics_file" notify_beam_max_mailbox_messages)
  if ((value > beam_max_mailbox_messages)); then
    beam_max_mailbox_messages=$value
  fi
  value=$(prometheus_metric "$metrics_file" notify_beam_processes)
  beam_processes=$((beam_processes + value))
  value=$(prometheus_metric \
    "$metrics_file" notify_scheduler_delay_milliseconds)
  if ((value > scheduler_delay_milliseconds)); then
    scheduler_delay_milliseconds=$value
  fi
done
committed_publishes=$(jq -r '.publishes.committed // 0' \
  "$report_directory/report.json")
jq -n \
  --argjson cpu_before_usec "$server_cpu_before_usec" \
  --argjson cpu_after_usec "$server_cpu_after_usec" \
  --argjson memory_peak_bytes "$server_memory_peak_bytes" \
  --argjson committed "$committed_publishes" \
  --argjson beam_run_queue "$beam_run_queue" \
  --argjson beam_mailbox_messages "$beam_mailbox_messages" \
  --argjson beam_max_mailbox_messages "$beam_max_mailbox_messages" \
  --argjson beam_processes "$beam_processes" \
  --argjson scheduler_delay_milliseconds \
    "$scheduler_delay_milliseconds" \
  '{cpu_before_usec: $cpu_before_usec, cpu_after_usec: $cpu_after_usec,
    cpu_used_usec: ($cpu_after_usec - $cpu_before_usec),
    cpu_usec_per_publish: (if $committed > 0 then
      (($cpu_after_usec - $cpu_before_usec) / $committed) else null end),
    aggregate_memory_peak_bytes: $memory_peak_bytes,
    beam_run_queue: $beam_run_queue,
    beam_mailbox_messages: $beam_mailbox_messages,
    beam_max_mailbox_messages: $beam_max_mailbox_messages,
    beam_processes: $beam_processes,
    scheduler_delay_milliseconds: $scheduler_delay_milliseconds}' \
  >"$report_directory/server-resources.json"

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
    'database_bytes', pg_database_size(current_database()),
    'transactions_committed', (SELECT xact_commit FROM pg_stat_database WHERE datname = current_database()),
    'transactions_rolled_back', (SELECT xact_rollback FROM pg_stat_database WHERE datname = current_database()),
    'statements', (SELECT COALESCE(SUM(calls), 0)::bigint FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())),
    'statement_rows', (SELECT COALESCE(SUM(rows), 0)::bigint FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())),
    'statement_execution_ms', (SELECT COALESCE(SUM(total_exec_time), 0)::double precision FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())))" \
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
