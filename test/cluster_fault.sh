#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

for required_command in cmp curl docker jq seq xargs; do
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
export NOTIFY_CLUSTER_RATE_LIMIT_REQUESTS=${NOTIFY_CLUSTER_RATE_LIMIT_REQUESTS:-10000}
export NOTIFY_CLUSTER_RATE_LIMIT_SUBSCRIPTIONS=${NOTIFY_CLUSTER_RATE_LIMIT_SUBSCRIPTIONS:-1000}
export NOTIFY_CLUSTER_RATE_LIMIT_TOPIC_CREATIONS=${NOTIFY_CLUSTER_RATE_LIMIT_TOPIC_CREATIONS:-1000}
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
slow_subscriber_pid=""
fast_subscriber_pid=""

stop_background() {
  local pid=${1:-}
  if [[ -z $pid ]]; then
    return 0
  fi
  kill -CONT "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  stop_background "$subscriber_pid"
  stop_background "$slow_subscriber_pid"
  stop_background "$fast_subscriber_pid"
  if ((status != 0)); then
    "${compose[@]}" logs --no-color --tail 300 >&2 || true
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

wait_for_endpoint() {
  local url=$1
  local endpoint=$2
  local attempt
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    if curl --fail --silent --show-error "$url/$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "node endpoint did not become available: $url/$endpoint" >&2
  return 1
}

wait_for_ready() {
  wait_for_endpoint "$1" readyz
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

publish_scheduled() {
  local url=$1
  local publish_topic=$2
  local publish_message=$3
  local response=$fault_directory/scheduled-publish.json
  curl --fail --silent --show-error \
    --user "$username:$password" \
    --header 'Delay: 10s' \
    --data-binary "$publish_message" \
    "$url/$publish_topic" >"$response"
  jq -er \
    --arg topic "$publish_topic" \
    --arg message "$publish_message" \
    'select(.event == "message" and .topic == $topic and .message == $message)
     | .id | select(type == "string" and length == 12)' \
    "$response"
}

wait_for_publish() {
  local url=$1
  local publish_topic=$2
  local publish_message=$3
  local attempt published
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    if published=$(publish "$url" "$publish_topic" "$publish_message" 2>/dev/null); then
      printf '%s\n' "$published"
      return 0
    fi
    sleep 1
  done
  echo "publish lane did not recover: $url/$publish_topic" >&2
  return 1
}

wait_for_open() {
  local file=$1
  local pid=$2
  local attempt
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if jq -se 'any(.event == "open")' "$file" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "subscriber exited before its open event" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "subscriber did not emit an open event" >&2
  return 1
}

wait_for_exact_ids() {
  local file=$1
  local pid=$2
  local expected_file=$3
  local label=$4
  local attempt
  for ((attempt = 0; attempt < 600; attempt += 1)); do
    if jq -se --slurpfile expected "$expected_file" \
      '[.[] | select(.event == "message") | .id] == $expected[0]' \
      "$file" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "$label subscriber exited before receiving the expected IDs" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "$label subscriber did not receive the exact ordered IDs" >&2
  return 1
}

assert_poll_ids() {
  local url=$1
  local poll_topic=$2
  local expected_file=$3
  local output=$4
  curl --fail --silent --show-error \
    --user "$username:$password" \
    "$url/$poll_topic/json?poll=1&since=all" >"$output"
  jq -se --slurpfile expected "$expected_file" \
    '[.[] | select(.event == "message") | .id] == $expected[0]' \
    "$output" >/dev/null
}

postgres_scalar() {
  local sql=$1
  "${compose[@]}" exec -T postgres \
    psql -X -qAt -U notify -d notify -c "$sql"
}

listener_pid() {
  local node_id=$1
  postgres_scalar \
    "SELECT pid FROM pg_stat_activity WHERE application_name = 'notify-listener-$node_id' ORDER BY backend_start DESC LIMIT 1"
}

wait_for_listener() {
  local node_id=$1
  local previous_pid=${2:-}
  local attempt pid
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    pid=$(listener_pid "$node_id" | tr -d '[:space:]')
    if [[ $pid =~ ^[0-9]+$ ]] && [[ $pid != "$previous_pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.25
  done
  echo "dedicated listener did not connect for $node_id" >&2
  return 1
}

terminate_listener() {
  local node_id=$1
  local pid
  pid=$(wait_for_listener "$node_id")
  if [[ $(postgres_scalar "SELECT pg_terminate_backend($pid)" | tr -d '[:space:]') != t ]]; then
    echo "could not terminate listener $pid for $node_id" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

send_duplicate_wakes() {
  postgres_scalar \
    "SELECT pg_notify('notify_events', 'duplicate-one'); SELECT pg_notify('notify_events', 'duplicate-two')" \
    >/dev/null
}

wait_for_cursor_at_head() {
  local node_id=$1
  local attempt caught_up
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    caught_up=$(postgres_scalar \
      "SELECT COALESCE((SELECT sequence FROM notify_node_cursors WHERE node_id = '$node_id'), -1) >= COALESCE((SELECT MAX(sequence) FROM notify_event_log), 0)" \
      | tr -d '[:space:]')
    if [[ $caught_up == t ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "durable cursor did not catch up for $node_id" >&2
  return 1
}

wait_for_scheduled_release() {
  local message_id=$1
  local attempt released
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    released=$(postgres_scalar \
      "SELECT COALESCE((SELECT scheduled = FALSE FROM notify_messages WHERE id = '$message_id'), FALSE) AND (SELECT COUNT(*) FROM notify_event_log WHERE message_id = '$message_id') = 2 AND (SELECT COUNT(*) FROM notify_event_log WHERE message_id = '$message_id' AND COALESCE((payload->>'_notify_scheduled')::boolean, FALSE) = FALSE) = 1" \
      | tr -d '[:space:]')
    if [[ $released == t ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "scheduled message was not released exactly once: $message_id" >&2
  return 1
}

wait_for_relay_request_count() {
  local expected=$1
  local attempt observed
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    observed=$("${compose[@]}" exec -T relay-mock \
      cat /tmp/relay-request-count 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $observed =~ ^[0-9]+$ ]] && ((observed >= expected)); then
      return 0
    fi
    sleep 0.25
  done
  echo "relay mock did not receive request $expected" >&2
  return 1
}

wait_for_delivery_owner() {
  local job_id=$1
  local previous_owner=${2:-}
  local attempt owner
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    owner=$(postgres_scalar \
      "SELECT COALESCE(lease_owner, '') FROM notify_delivery_outbox WHERE id = '$job_id'" \
      | tr -d '[:space:]')
    if [[ $owner =~ ^notify-[abc]-relay$ ]] \
      && [[ $owner != "$previous_owner" ]]; then
      printf '%s\n' "$owner"
      return 0
    fi
    sleep 0.25
  done
  echo "delivery job was not leased by a new worker: $job_id" >&2
  return 1
}

wait_for_delivery_removal() {
  local job_id=$1
  local attempt absent
  for ((attempt = 0; attempt < 120; attempt += 1)); do
    absent=$(postgres_scalar \
      "SELECT NOT EXISTS(SELECT 1 FROM notify_delivery_outbox WHERE id = '$job_id')" \
      | tr -d '[:space:]')
    if [[ $absent == t ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "reclaimed delivery job was not completed: $job_id" >&2
  return 1
}

expect_publish_failure() {
  local url=$1
  local publish_topic=$2
  local publish_message=$3
  local output=$4
  local curl_status=0 http_status
  http_status=$(curl --silent --show-error --max-time 20 \
    --user "$username:$password" \
    --data-binary "$publish_message" \
    --output "$output" \
    --write-out '%{http_code}' \
    "$url/$publish_topic") || curl_status=$?
  if ((curl_status == 0)) && [[ $http_status == 2?? ]]; then
    echo "publish unexpectedly succeeded during PostgreSQL outage" >&2
    return 1
  fi
}

expect_attachment_failure() {
  local url=$1
  local publish_topic=$2
  local source=$3
  local output=$4
  local curl_status=0 http_status
  http_status=$(curl --silent --show-error --max-time 20 \
    --user "$username:$password" \
    --header 'Filename: unavailable-object-store.bin' \
    --header 'Message: object store unavailable attachment' \
    --data-binary "@$source" \
    --output "$output" \
    --write-out '%{http_code}' \
    "$url/$publish_topic") || curl_status=$?
  if ((curl_status == 0)) && [[ $http_status == 2?? ]]; then
    echo "attachment unexpectedly succeeded during MinIO outage" >&2
    return 1
  fi
}

assert_message_absent() {
  local url=$1
  local poll_topic=$2
  local unexpected=$3
  local output=$4
  local attempt
  # Auxiliary PostgreSQL lanes fail the first operation on a stale connection,
  # then replace it before the next operation. Poll is read-only, so retry only
  # transport/service failures; a successful response containing the phantom
  # message remains an immediate assertion failure.
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    if curl --fail --silent --show-error \
      --user "$username:$password" \
      "$url/$poll_topic/json?poll=1&since=all" >"$output" 2>/dev/null; then
      if ! jq -se --arg unexpected "$unexpected" \
        '[.[] | select(.event == "message" and .message == $unexpected)]
         | length == 0' \
        "$output" >/dev/null; then
        echo "failed operation became a visible message: $unexpected" >&2
        return 1
      fi
      return 0
    fi
    sleep 1
  done
  echo "poll lane did not recover: $url/$poll_topic" >&2
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
wait_for_ready "$node_a"
wait_for_ready "$node_b"
wait_for_ready "$node_c"

# A terminated LISTEN backend must reconnect with a different PID and catch up
# from the durable event log. Repeated wake-ups must not duplicate delivery.
readonly topic="cluster-fault-$run_suffix"
readonly live_before=$fault_directory/live-before.ndjson
readonly stable_expected=$fault_directory/stable-expected.json
curl --fail --silent --show-error --no-buffer \
  --user "$username:$password" \
  "$node_b/$topic/json?since=all" >"$live_before" &
subscriber_pid=$!
wait_for_open "$live_before" "$subscriber_pid"
first_id=$(publish "$node_a" "$topic" "cluster message one")
readonly first_id
second_id=$(publish "$node_c" "$topic" "cluster message two")
readonly second_id
jq -n --arg first "$first_id" --arg second "$second_id" \
  '[$first, $second]' >"$stable_expected"
wait_for_exact_ids "$live_before" "$subscriber_pid" "$stable_expected" stable

old_listener_pid=$(terminate_listener notify-b)
readonly old_listener_pid
third_id=$(publish "$node_a" "$topic" "cluster message three")
readonly third_id
new_listener_pid=$(wait_for_listener notify-b "$old_listener_pid")
readonly new_listener_pid
if [[ $new_listener_pid == "$old_listener_pid" ]]; then
  echo "listener reconnect reused the terminated backend PID" >&2
  exit 1
fi
send_duplicate_wakes
jq -n \
  --arg first "$first_id" \
  --arg second "$second_id" \
  --arg third "$third_id" \
  '[$first, $second, $third]' >"$stable_expected"
wait_for_exact_ids "$live_before" "$subscriber_pid" "$stable_expected" stable
sleep 1
jq -se --slurpfile expected "$stable_expected" \
  '[.[] | select(.event == "message") | .id] == $expected[0]' \
  "$live_before" >/dev/null
stop_background "$subscriber_pid"
subscriber_pid=""

# Stop one client from reading. Its 128-event credit must overflow without
# delaying or losing the independent fast subscriber on the same node.
readonly slow_topic="cluster-slow-$run_suffix"
readonly slow_output=$fault_directory/slow.ndjson
readonly fast_output=$fault_directory/fast.ndjson
readonly slow_expected=$fault_directory/slow-expected.json
"${compose[@]}" exec -T notify-b erl -noshell -eval "
  {ok, Socket} = gen_tcp:connect(
    {127,0,0,1}, 8080,
    [binary, {packet, raw}, {active, false}, {recbuf, 1024}], 5000),
  ok = gen_tcp:send(Socket,
    <<\"GET /$slow_topic/json?since=all HTTP/1.1\\r\\n\",
      \"Host: localhost\\r\\n\",
      \"Authorization: Basic Y2x1c3Rlcl9hZG1pbjpjbHVzdGVyIGZhdWx0IHRlc3QgcGFzc3dvcmQ=\\r\\n\",
      \"Connection: close\\r\\n\\r\\n\">>),
  {ok, _Initial} = gen_tcp:recv(Socket, 0, 5000),
  timer:sleep(30000),
  Drain = fun Continue(Received) ->
    case gen_tcp:recv(Socket, 0, 5000) of
      {ok, Data} -> Continue(<<Received/binary, Data/binary>>);
      {error, closed} ->
        case binary:match(Received, <<\"\\\"code\\\":42909\">>) of
          nomatch -> halt(1);
          _ -> halt(0)
        end;
      {error, Reason} -> io:format(standard_error, \"~p~n\", [Reason]), halt(1)
    end
  end,
  Drain(<<>>)." >"$slow_output" 2>&1 &
slow_subscriber_pid=$!
sleep 2
if ! kill -0 "$slow_subscriber_pid" 2>/dev/null; then
  wait "$slow_subscriber_pid" 2>/dev/null || true
  cat "$slow_output" >&2
  echo "bounded receive-window subscriber failed to connect" >&2
  exit 1
fi
curl --fail --silent --show-error --no-buffer \
  --user "$username:$password" \
  "$node_b/$slow_topic/json?since=all" >"$fast_output" &
fast_subscriber_pid=$!
wait_for_open "$fast_output" "$fast_subscriber_pid"
slow_padding=$(printf '%03900d' 0)
readonly slow_padding
slow_publish_directory=$fault_directory/slow-publishes
mkdir "$slow_publish_directory"
export slow_publish_url=$node_a
export slow_publish_topic=$slow_topic
export slow_publish_username=$username
export slow_publish_password=$password
export slow_publish_padding=$slow_padding
export slow_publish_directory
# The worker shell expands only the explicitly exported test variables.
# shellcheck disable=SC2016
seq 1 1024 | xargs -P64 -n1 bash -c '
  sequence=$1
  curl --fail --silent --show-error \
    --user "$slow_publish_username:$slow_publish_password" \
    --data-binary "slow-isolation-$sequence-$slow_publish_padding" \
    "$slow_publish_url/$slow_publish_topic" \
    >"$slow_publish_directory/$sequence.json"
' _
unset slow_publish_url slow_publish_topic slow_publish_username
unset slow_publish_password slow_publish_padding slow_publish_directory
curl --fail --silent --show-error \
  --user "$username:$password" \
  "$node_a/$slow_topic/json?poll=1&since=all" \
  >"$fault_directory/slow-authoritative.ndjson"
jq -se '[.[] | select(.event == "message")] | length == 1024' \
  "$fault_directory/slow-authoritative.ndjson" >/dev/null
jq -s '[.[] | select(.event == "message") | .id]' \
  "$fault_directory/slow-authoritative.ndjson" >"$slow_expected"
wait_for_exact_ids "$fast_output" "$fast_subscriber_pid" \
  "$slow_expected" fast
stop_background "$fast_subscriber_pid"
fast_subscriber_pid=""
for _ in $(seq 1 600); do
  if ! kill -0 "$slow_subscriber_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$slow_subscriber_pid" 2>/dev/null; then
  stop_background "$slow_subscriber_pid"
  slow_subscriber_pid=""
  echo "slow subscriber was not disconnected after exhausting credit" >&2
  exit 1
fi
slow_status=0
wait "$slow_subscriber_pid" || slow_status=$?
slow_subscriber_pid=""
if ((slow_status != 0)); then
  cat "$slow_output" >&2
  echo "slow subscriber did not receive the bounded-buffer overflow" >&2
  exit 1
fi

# Two simultaneous node crashes must preserve ordered cache replay and each
# restarted node must advance its durable cursor to the event-log head.
"${compose[@]}" kill notify-b notify-c
fourth_id=$(publish "$node_a" "$topic" "cluster message four")
readonly fourth_id
fifth_id=$(publish "$node_a" "$topic" "cluster message five")
readonly fifth_id
"${compose[@]}" start notify-b notify-c
wait_for_ready "$node_b"
wait_for_ready "$node_c"
jq -n \
  --arg first "$first_id" \
  --arg second "$second_id" \
  --arg third "$third_id" \
  --arg fourth "$fourth_id" \
  --arg fifth "$fifth_id" \
  '[$first, $second, $third, $fourth, $fifth]' >"$stable_expected"
assert_poll_ids "$node_b" "$topic" "$stable_expected" \
  "$fault_directory/replay-b.ndjson"
assert_poll_ids "$node_c" "$topic" "$stable_expected" \
  "$fault_directory/replay-c.ndjson"
wait_for_cursor_at_head notify-b
wait_for_cursor_at_head notify-c

readonly live_after=$fault_directory/live-after.ndjson
readonly resumed_expected=$fault_directory/resumed-expected.json
curl --fail --silent --show-error --no-buffer --get \
  --user "$username:$password" \
  --data-urlencode "since=$fifth_id" \
  "$node_b/$topic/json" >"$live_after" &
subscriber_pid=$!
wait_for_open "$live_after" "$subscriber_pid"
sixth_id=$(publish "$node_c" "$topic" "cluster message six")
readonly sixth_id
jq -n --arg sixth "$sixth_id" '[$sixth]' >"$resumed_expected"
wait_for_exact_ids "$live_after" "$subscriber_pid" \
  "$resumed_expected" resumed
stop_background "$subscriber_pid"
subscriber_pid=""

# A scheduled commit must survive loss of its origin node. The two surviving
# schedulers race the same due row, but only one release event and one live
# delivery may be produced.
readonly scheduled_topic="cluster-scheduled-$run_suffix"
readonly scheduled_output=$fault_directory/scheduled-live.ndjson
readonly scheduled_expected=$fault_directory/scheduled-expected.json
curl --fail --silent --show-error --no-buffer \
  --user "$username:$password" \
  "$node_b/$scheduled_topic/json?since=all" >"$scheduled_output" &
subscriber_pid=$!
wait_for_open "$scheduled_output" "$subscriber_pid"
scheduled_id=$(publish_scheduled \
  "$node_a" "$scheduled_topic" "scheduled origin failover")
readonly scheduled_id
jq -n --arg scheduled "$scheduled_id" '[$scheduled]' \
  >"$scheduled_expected"
"${compose[@]}" kill notify-a
wait_for_exact_ids "$scheduled_output" "$subscriber_pid" \
  "$scheduled_expected" scheduled
wait_for_scheduled_release "$scheduled_id"
sleep 2
jq -se --slurpfile expected "$scheduled_expected" \
  '[.[] | select(.event == "message") | .id] == $expected[0]' \
  "$scheduled_output" >/dev/null
stop_background "$subscriber_pid"
subscriber_pid=""
"${compose[@]}" start notify-a
wait_for_ready "$node_a"
wait_for_cursor_at_head notify-a

# Commits must fail closed while PostgreSQL is unavailable and normal writes
# must recover without a phantom commit after the database returns.
readonly database_topic="cluster-database-outage-$run_suffix"
readonly failed_database_message="must not commit while postgres is down"
"${compose[@]}" stop postgres
expect_publish_failure "$node_a" "$database_topic" \
  "$failed_database_message" "$fault_directory/database-outage.json"
"${compose[@]}" start postgres
wait_for_ready "$node_a"
wait_for_ready "$node_b"
wait_for_ready "$node_c"
sleep 2
assert_message_absent "$node_b" "$database_topic" \
  "$failed_database_message" "$fault_directory/database-recovery-poll.ndjson"
wait_for_publish "$node_c" "$database_topic" \
  "postgres recovery publish" >/dev/null

# An unavailable shared object store must neither publish attachment metadata
# nor leave a visible object. Upload and cross-node download must recover.
readonly attachment_topic="cluster-object-outage-$run_suffix"
readonly attachment_source=$fault_directory/attachment-source.bin
readonly attachment_download=$fault_directory/attachment-download.bin
printf 'cluster object storage recovery payload %s\n' "$run_suffix" \
  >"$attachment_source"
"${compose[@]}" stop minio
expect_attachment_failure "$node_a" "$attachment_topic" \
  "$attachment_source" "$fault_directory/object-outage.json"
"${compose[@]}" start minio
wait_for_ready "$node_a"
wait_for_ready "$node_b"
wait_for_ready "$node_c"
assert_message_absent "$node_c" "$attachment_topic" \
  "object store unavailable attachment" \
  "$fault_directory/object-recovery-poll.ndjson"
curl --fail --silent --show-error \
  --user "$username:$password" \
  --header 'Filename: recovered-object-store.bin' \
  --header 'Message: object store recovered attachment' \
  --data-binary "@$attachment_source" \
  "$node_a/$attachment_topic" >"$fault_directory/attachment-publish.json"
attachment_path=$(jq -er \
  'select(.event == "message") | .attachment.url
   | select(type == "string") | sub("^https?://[^/]+"; "")' \
  "$fault_directory/attachment-publish.json")
curl --fail --silent --show-error \
  --user "$username:$password" \
  "$node_b$attachment_path" >"$attachment_download"
cmp "$attachment_source" "$attachment_download"

# A provider call held open by a killed lease owner must be reclaimed by a
# different node after expiry. The mock rejects any relay body or malformed
# poll ID, and delays the successful response long enough to observe ownership.
export NOTIFY_CLUSTER_RELAY_URL=http://relay-mock:9090
export NOTIFY_CLUSTER_RELAY_TOKEN=cluster-relay-token
"${compose[@]}" up --detach --no-build relay-mock
"${compose[@]}" up --detach --no-build --force-recreate \
  --wait --wait-timeout 180 notify-a notify-b notify-c
wait_for_ready "$node_a"
wait_for_ready "$node_b"
wait_for_ready "$node_c"

readonly relay_topic="cluster-relay-lease-$run_suffix"
relay_message_id=$(publish "$node_a" "$relay_topic" "relay lease failover")
readonly relay_message_id
readonly relay_job_id="relay_$relay_message_id"
first_relay_owner=$(wait_for_delivery_owner "$relay_job_id")
readonly first_relay_owner
wait_for_relay_request_count 1
case $first_relay_owner in
  notify-a-relay) relay_owner_service=notify-a ;;
  notify-b-relay) relay_owner_service=notify-b ;;
  notify-c-relay) relay_owner_service=notify-c ;;
  *)
    echo "unexpected relay lease owner: $first_relay_owner" >&2
    exit 1
    ;;
esac
readonly relay_owner_service
"${compose[@]}" kill "$relay_owner_service"
expired_owner=$(postgres_scalar \
  "UPDATE notify_delivery_outbox SET lease_until = extract(epoch from now())::bigint + 2 WHERE id = '$relay_job_id' AND state = 'leased' RETURNING lease_owner" \
  | tr -d '[:space:]')
if [[ $expired_owner != "$first_relay_owner" ]]; then
  echo "could not expire the killed relay owner's lease" >&2
  exit 1
fi
wait_for_relay_request_count 2
second_relay_owner=$(wait_for_delivery_owner \
  "$relay_job_id" "$first_relay_owner")
readonly second_relay_owner
if [[ $second_relay_owner == "$first_relay_owner" ]]; then
  echo "expired relay lease was reclaimed by its killed owner" >&2
  exit 1
fi
wait_for_delivery_removal "$relay_job_id"
sleep 2
relay_request_count=$("${compose[@]}" exec -T relay-mock \
  cat /tmp/relay-request-count | tr -d '[:space:]')
if [[ $relay_request_count != 2 ]]; then
  echo "reclaimed relay job produced $relay_request_count provider calls" >&2
  exit 1
fi
if ! "${compose[@]}" exec -T relay-mock \
  sh -c 'test ! -e /tmp/relay-invalid-request && test ! -e /tmp/relay-read-error'; then
  echo "relay mock received a body, malformed headers, or a read error" >&2
  exit 1
fi
"${compose[@]}" start "$relay_owner_service"
case $relay_owner_service in
  notify-a) wait_for_ready "$node_a" ;;
  notify-b) wait_for_ready "$node_b" ;;
  notify-c) wait_for_ready "$node_c" ;;
esac

echo "three-node listener recovery, duplicate wake, slow-subscriber isolation, simultaneous crash catch-up, scheduled failover, PostgreSQL/MinIO outage, and lease reclamation passed"
