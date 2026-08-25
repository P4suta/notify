#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

for required_command in curl docker jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

readonly username=cluster_admin
readonly password='cluster fault test password'
run_suffix="$(date +%s)-$$"
readonly run_suffix
project_name=${NOTIFY_CLUSTER_FAULT_PROJECT_NAME:-"notify-cluster-fault-$run_suffix"}
if [[ ! $project_name =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "invalid NOTIFY_CLUSTER_FAULT_PROJECT_NAME: $project_name" >&2
  exit 2
fi
readonly project_name
export NOTIFY_CLUSTER_IMAGE="notify:cluster-fault-$run_suffix"
readonly NOTIFY_CLUSTER_IMAGE
readonly -a compose=(
  docker compose
  --project-name "$project_name"
  -f "$root/compose.cluster.yml"
)
temporary_root=${TMPDIR:-/tmp}
readonly temporary_root
fault_directory=$(mktemp -d "$temporary_root/notify-cluster-fault.XXXXXX")
readonly fault_directory
subscriber_pid=""

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n $subscriber_pid ]] && kill -0 "$subscriber_pid" 2>/dev/null; then
    kill "$subscriber_pid" 2>/dev/null || true
    wait "$subscriber_pid" 2>/dev/null || true
  fi
  if ((status != 0)); then
    "${compose[@]}" logs --no-color >&2 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "$NOTIFY_CLUSTER_IMAGE" >/dev/null 2>&1 || true
  if [[ $fault_directory == "$temporary_root"/notify-cluster-fault.* ]] \
    && [[ -d $fault_directory ]]; then
    find "$fault_directory" -depth -delete
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

wait_for_health() {
  local url=$1
  local attempt
  for ((attempt = 0; attempt < 90; attempt += 1)); do
    if curl --fail --silent --show-error "$url/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "node did not become healthy: $url" >&2
  return 1
}

publish() {
  local url=$1
  local publish_topic=$2
  local publish_message=$3
  local response=$fault_directory/publish.json
  curl --fail --silent --show-error \
    --user "$username:$password" \
    --data-binary "$publish_message" \
    "$url/$publish_topic" >"$response"
  jq -er \
    --arg topic "$publish_topic" \
    --arg message "$publish_message" \
    'select(.event == "message" and .topic == $topic and .message == $message)
     | .id | select(type == "string" and length == 12)' \
    "$response"
}

wait_for_ordered_pair() {
  local file=$1
  local pid=$2
  local expected_first_id=$3
  local expected_second_id=$4
  local attempt
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if jq -se --arg first "$expected_first_id" \
      --arg second "$expected_second_id" \
      '[.[] | select(.event == "message") | .id] == [$first, $second]' \
      "$file" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "live subscriber exited before receiving both messages" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "live subscriber did not receive exactly two ordered messages" >&2
  return 1
}

wait_for_single_message() {
  local file=$1
  local pid=$2
  local expected_id=$3
  local attempt
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if jq -se --arg expected "$expected_id" \
      '[.[] | select(.event == "message") | .id] == [$expected]' \
      "$file" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "resumed subscriber exited before receiving its message" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "resumed subscriber did not receive exactly one new message" >&2
  return 1
}

"${compose[@]}" build notify-a
"${compose[@]}" up --detach --wait --wait-timeout 120 postgres minio
"${compose[@]}" run --rm --no-deps \
  --env "NOTIFY_PASSWORD=$password" \
  notify-a run setup \
  --username "$username" \
  --anonymous-access deny >"$fault_directory/setup.log"
grep -Fx "setup complete; administrator $username created" \
  "$fault_directory/setup.log" >/dev/null
"${compose[@]}" up --detach --no-build --wait --wait-timeout 180 \
  notify-a notify-b notify-c

readonly node_a=http://127.0.0.1:8080
readonly node_b=http://127.0.0.1:8081
readonly node_c=http://127.0.0.1:8082
wait_for_health "$node_a"
wait_for_health "$node_b"
wait_for_health "$node_c"

readonly topic="cluster-fault-$run_suffix"
readonly live_before=$fault_directory/live-before.ndjson
curl --fail --silent --show-error --no-buffer \
  --user "$username:$password" \
  "$node_b/$topic/json?since=all" >"$live_before" &
subscriber_pid=$!
sleep 1
first_id=$(publish "$node_a" "$topic" "cluster message one")
readonly first_id
second_id=$(publish "$node_c" "$topic" "cluster message two")
readonly second_id
wait_for_ordered_pair "$live_before" "$subscriber_pid" "$first_id" "$second_id"
kill "$subscriber_pid" 2>/dev/null || true
wait "$subscriber_pid" 2>/dev/null || true
subscriber_pid=""

"${compose[@]}" kill notify-b
third_id=$(publish "$node_a" "$topic" "cluster message three")
readonly third_id
fourth_id=$(publish "$node_c" "$topic" "cluster message four")
readonly fourth_id
"${compose[@]}" start notify-b
wait_for_health "$node_b"

readonly replay=$fault_directory/replay.ndjson
curl --fail --silent --show-error \
  --user "$username:$password" \
  "$node_b/$topic/json?poll=1&since=all" >"$replay"
jq -se \
  --arg first "$first_id" \
  --arg second "$second_id" \
  --arg third "$third_id" \
  --arg fourth "$fourth_id" \
  '[.[] | select(.event == "message") | .id]
   == [$first, $second, $third, $fourth]' \
  "$replay" >/dev/null

readonly live_after=$fault_directory/live-after.ndjson
curl --fail --silent --show-error --no-buffer --get \
  --user "$username:$password" \
  --data-urlencode "since=$fourth_id" \
  "$node_b/$topic/json" >"$live_after" &
subscriber_pid=$!
sleep 1
fifth_id=$(publish "$node_a" "$topic" "cluster message five")
readonly fifth_id
wait_for_single_message "$live_after" "$subscriber_pid" "$fifth_id"
kill "$subscriber_pid" 2>/dev/null || true
wait "$subscriber_pid" 2>/dev/null || true
subscriber_pid=""

echo "three-node stable delivery, crash recovery, replay, and resume passed"
