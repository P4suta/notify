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

run_suffix="$(date +%s)-$$"
readonly run_suffix
project_name=${NOTIFY_SOAK_PROJECT_NAME:-"notify-sqlite-soak-$run_suffix"}
if [[ ! $project_name =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "invalid NOTIFY_SOAK_PROJECT_NAME: $project_name" >&2
  exit 2
fi
readonly project_name
export NOTIFY_SQLITE_IMAGE="notify:sqlite-soak-$run_suffix"
readonly NOTIFY_SQLITE_IMAGE
readonly -a compose=(
  docker compose
  --project-name "$project_name"
  -f "$root/compose.sqlite.yml"
)

temporary_root=${TMPDIR:-/tmp}
readonly temporary_root
temporary_directory=$(mktemp -d "$temporary_root/notify-sqlite-soak.XXXXXX")
readonly temporary_directory
report_directory=${NOTIFY_SOAK_REPORT_DIRECTORY:-$temporary_directory/report}
readonly report_directory
if [[ -e $report_directory ]]; then
  echo "refusing existing soak report path: $report_directory" >&2
  find "$temporary_directory" -depth -delete
  exit 2
fi
mkdir -p "$report_directory"
: >"$report_directory/resources.ndjson"
resource_sampler_pid=""

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
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
  docker image rm "$NOTIFY_SQLITE_IMAGE" >/dev/null 2>&1 || true
  if [[ $temporary_directory == "$temporary_root"/notify-sqlite-soak.* ]] \
    && [[ -d $temporary_directory ]]; then
    find "$temporary_directory" -depth -delete
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

planned_publishes=$((publish_rate * duration_seconds))
export NOTIFY_SQLITE_RATE_LIMIT_REQUESTS=$((
  subscriptions + planned_publishes + 100000
))
export NOTIFY_SQLITE_RATE_LIMIT_SUBSCRIPTIONS=$((subscriptions + 10000))
export NOTIFY_SQLITE_RATE_LIMIT_TOPIC_CREATIONS=$((
  planned_publishes + topics + 100000
))
export NOTIFY_SQLITE_RATE_LIMIT_WINDOW_SECONDS=$((
  duration_seconds + settle_seconds + 600
))
case $scenario in
  webpush-relay)
    export NOTIFY_SQLITE_RELAY_URL=http://relay-benchmark:9090
    export NOTIFY_SQLITE_RELAY_TOKEN=benchmark-relay-token
    export NOTIFY_RELAY_DELAY_MS=0
    ;;
  slow-provider)
    export NOTIFY_SQLITE_RELAY_URL=http://relay-benchmark:9090
    export NOTIFY_SQLITE_RELAY_TOKEN=benchmark-relay-token
    export NOTIFY_RELAY_DELAY_MS=250
    ;;
esac

"${compose[@]}" build notify
case $scenario in
  webpush-relay | slow-provider)
    "${compose[@]}" up --detach --no-build relay-benchmark
    ;;
esac
"${compose[@]}" run --rm --no-deps \
  --env "NOTIFY_PASSWORD=sqlite soak test password" \
  notify run setup \
  --username soak_admin \
  --anonymous-access read-write >"$temporary_directory/setup.log"
grep -Fx "setup complete; administrator soak_admin created" \
  "$temporary_directory/setup.log" >/dev/null
"${compose[@]}" up --detach --no-build --wait --wait-timeout 240 notify

readonly endpoint=http://127.0.0.1:8080
for ((attempt = 0; attempt < 180; attempt += 1)); do
  if curl --fail --silent --show-error "$endpoint/readyz" >/dev/null 2>&1; then
    break
  fi
  if ((attempt == 179)); then
    echo "SQLite node did not become ready" >&2
    exit 1
  fi
  sleep 1
done

server_containers=("$project_name-notify-1")
container_names=("${server_containers[@]}")
case $scenario in
  webpush-relay | slow-provider)
    container_names+=("$project_name-relay-benchmark-1")
    ;;
esac
readonly -a container_names
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
    curl --fail --silent --show-error "$endpoint/metrics" \
      >"$report_directory/metrics-latest.prom" || true
    sleep "$resource_sample_seconds"
  done
}
sample_resources &
resource_sampler_pid=$!

jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg kernel "$(uname -srvmo)" \
  --arg docker "$(docker version --format '{{.Server.Version}}')" \
  --arg compose "$(docker compose version --short)" \
  --argjson resource_sample_seconds "$resource_sample_seconds" \
  '{generated_at: $generated_at, kernel: $kernel, docker: $docker,
    docker_compose: $compose, database: "SQLite WAL",
    resource_sample_seconds: $resource_sample_seconds}' \
  >"$report_directory/environment.json"

export NOTIFY_SOAK_BACKEND=sqlite
export NOTIFY_SOAK_ENDPOINTS=$endpoint
export NOTIFY_SOAK_SUBSCRIPTIONS=$subscriptions
export NOTIFY_SOAK_TOPICS=$topics
export NOTIFY_SOAK_PUBLISH_RATE=$publish_rate
export NOTIFY_SOAK_DURATION_SECONDS=$duration_seconds
export NOTIFY_SOAK_SETTLE_SECONDS=$settle_seconds
export NOTIFY_SOAK_FORMAT=$format
export NOTIFY_SOAK_TOPIC_PREFIX="sqlite-soak-$$"
export NOTIFY_SOAK_REPORT_PATH="$report_directory/report.json"
export NOTIFY_SOAK_SEQUENCE_PATH="$report_directory/observed-sequences.ndjson"

server_cpu_before_usec=$(cgroup_total /sys/fs/cgroup/cpu.stat usage_usec)
driver_status=0
node --max-old-space-size=4096 test/cluster_soak.mjs \
  >"$temporary_directory/driver.json" || driver_status=$?
server_cpu_after_usec=$(cgroup_total /sys/fs/cgroup/cpu.stat usage_usec)
server_memory_peak_bytes=$(cgroup_total /sys/fs/cgroup/memory.peak "")
curl --fail --silent --show-error "$endpoint/metrics" \
  >"$report_directory/metrics-final.prom" || driver_status=1
beam_run_queue=$(prometheus_metric \
  "$report_directory/metrics-final.prom" notify_beam_run_queue)
beam_mailbox_messages=$(prometheus_metric \
  "$report_directory/metrics-final.prom" notify_beam_mailbox_messages)
beam_max_mailbox_messages=$(prometheus_metric \
  "$report_directory/metrics-final.prom" notify_beam_max_mailbox_messages)
beam_processes=$(prometheus_metric \
  "$report_directory/metrics-final.prom" notify_beam_processes)
scheduler_delay_milliseconds=$(prometheus_metric \
  "$report_directory/metrics-final.prom" notify_scheduler_delay_milliseconds)
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

if kill -0 "$resource_sampler_pid" 2>/dev/null; then
  kill "$resource_sampler_pid" 2>/dev/null || true
  wait "$resource_sampler_pid" 2>/dev/null || true
fi
resource_sampler_pid=""

docker inspect --format '{{json .State}}' "${container_names[@]}" \
  | jq -s . >"$report_directory/container-state.json"
if ! jq -e 'all(.[]; .OOMKilled == false and .Running == true)' \
  "$report_directory/container-state.json" >/dev/null; then
  echo "SQLite soak container stopped or was OOM-killed" >&2
  driver_status=1
fi
docker exec "$project_name-notify-1" stat -c '%s' /data/notify.db \
  >"$report_directory/database-bytes.txt"
jq . "$report_directory/report.json"
echo "SQLite soak reports: $report_directory"
exit "$driver_status"
