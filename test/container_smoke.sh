#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

if (($# != 1)) || [[ ! $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]]; then
  echo "usage: test/container_smoke.sh LOCAL_IMAGE_REFERENCE" >&2
  exit 2
fi
for required_command in curl docker jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

readonly image_reference=$1
readonly username=admin
readonly password='container smoke password'
readonly message='durable container smoke message'
timestamp=$(date +%s)
readonly timestamp
readonly topic="container-smoke-$timestamp-$$"
readonly run_suffix="$timestamp-$$"
readonly volume_name="notify-smoke-$run_suffix"
readonly container_name="notify-smoke-$run_suffix"
smoke_directory=$(mktemp -d "${TMPDIR:-/tmp}/notify-container-smoke.XXXXXX")
readonly smoke_directory
readonly response="$smoke_directory/response.json"
readonly poll_response="$smoke_directory/poll.ndjson"
readonly attachment_source="$smoke_directory/attachment-source.bin"
readonly attachment_download="$smoke_directory/attachment-download.bin"
readonly attachment_range="$smoke_directory/attachment-range.bin"
readonly attachment_expected_range="$smoke_directory/attachment-expected-range.bin"
container_exists=false
base_url=''

cleanup() {
  if [[ $container_exists == true ]]; then
    docker container rm --force "$container_name" >/dev/null 2>&1 || true
  fi
  docker volume rm --force "$volume_name" >/dev/null 2>&1 || true
  if [[ -d $smoke_directory ]]; then
    find "$smoke_directory" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

docker image inspect "$image_reference" >/dev/null
docker volume create "$volume_name" >/dev/null
docker run \
  --rm \
  --network none \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs "/tmp:rw,noexec,nosuid,size=64m,mode=1777" \
  --volume "$volume_name:/data" \
  --env "NOTIFY_PASSWORD=$password" \
  "$image_reference" \
  run setup \
  --username "$username" \
  --anonymous-access deny >"$smoke_directory/setup.log"
grep -Fx "setup complete; administrator $username created" \
  "$smoke_directory/setup.log" >/dev/null

start_server() {
  docker run \
    --detach \
    --name "$container_name" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs "/tmp:rw,noexec,nosuid,size=64m,mode=1777" \
    --publish 127.0.0.1::8080 \
    --volume "$volume_name:/data" \
    "$image_reference" \
    run serve \
    --listen-host 0.0.0.0 \
    --base-url http://127.0.0.1:8080 \
    --log-format json >/dev/null
  container_exists=true

  local published_address host_port attempt
  published_address=$(docker port "$container_name" 8080/tcp)
  host_port=${published_address##*:}
  if [[ ! $host_port =~ ^[0-9]+$ ]]; then
    echo "cannot determine published container port: $published_address" >&2
    return 1
  fi
  base_url="http://127.0.0.1:$host_port"
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    if curl --fail --silent --show-error "$base_url/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$container_name") != true ]]; then
      docker logs "$container_name" >&2
      return 1
    fi
    sleep 1
  done
  docker logs "$container_name" >&2
  echo "container did not become healthy within 30 seconds" >&2
  return 1
}

stop_server() {
  docker stop --time 35 "$container_name" >/dev/null
  local exit_code
  exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container_name")
  if [[ $exit_code != 0 ]]; then
    docker logs "$container_name" >&2
    echo "container exited with status $exit_code" >&2
    return 1
  fi
  docker logs "$container_name" >"$smoke_directory/server.log"
  grep -F 'shutdown signal received; draining connections' \
    "$smoke_directory/server.log" >/dev/null
  grep -F 'shutdown complete' "$smoke_directory/server.log" >/dev/null
  docker container rm "$container_name" >/dev/null
  container_exists=false
}

start_server
curl --fail --silent --show-error \
  --user "$username:$password" \
  --data-binary "$message" \
  "$base_url/$topic" >"$response"
message_id=$(jq -er \
  --arg topic "$topic" \
  --arg message "$message" \
  'select(.event == "message" and .topic == $topic and .message == $message)
   | .id | select(type == "string" and length == 12)' \
  "$response")

curl --fail --silent --show-error \
  --user "$username:$password" \
  "$base_url/$topic/json?poll=1&since=all" >"$poll_response"
jq -se --arg id "$message_id" \
  '[.[] | select(.event == "message" and .id == $id)] | length == 1' \
  "$poll_response" >/dev/null

dd if=/dev/urandom of="$attachment_source" bs=1048576 count=2 status=none
printf 'streaming-tail' >>"$attachment_source"
curl --http1.1 --fail --silent --show-error \
  --user "$username:$password" \
  --header 'Transfer-Encoding: chunked' \
  --header 'Filename: streamed-container.bin' \
  --header 'Content-Type: application/octet-stream' \
  --data-binary "@$attachment_source" \
  "$base_url/$topic" >"$response"
attachment_path=$(jq -er \
  'select(.event == "message") | .attachment.url
   | select(type == "string") | sub("^https?://[^/]+"; "")' \
  "$response")
curl --fail --silent --show-error \
  --user "$username:$password" \
  "$base_url$attachment_path" >"$attachment_download"
cmp "$attachment_source" "$attachment_download"
curl --fail --silent --show-error \
  --user "$username:$password" \
  --header 'Range: bytes=1048570-1048590' \
  "$base_url$attachment_path" >"$attachment_range"
dd if="$attachment_source" of="$attachment_expected_range" \
  bs=1 skip=1048570 count=21 status=none
cmp "$attachment_expected_range" "$attachment_range"
stop_server

start_server
curl --fail --silent --show-error \
  --user "$username:$password" \
  "$base_url/$topic/json?poll=1&since=all" >"$poll_response"
jq -se --arg id "$message_id" \
  '[.[] | select(.event == "message" and .id == $id)] | length == 1' \
  "$poll_response" >/dev/null
stop_server

echo "container setup, publish/poll, chunked attachment, sendfile range, restart, and graceful shutdown smoke passed"
