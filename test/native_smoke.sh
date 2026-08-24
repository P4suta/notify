#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

if (($# != 1)); then
  echo "usage: test/native_smoke.sh NATIVE_EXECUTABLE" >&2
  exit 2
fi
for required_command in curl jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

artifact_directory=$(CDPATH='' cd -- "$(dirname "$1")" && pwd)
artifact="$artifact_directory/$(basename "$1")"
if [[ ! -f $artifact || ! -x $artifact ]]; then
  echo "native executable is missing or not executable: $artifact" >&2
  exit 2
fi
readonly artifact

smoke_directory=$(mktemp -d "${TMPDIR:-/tmp}/notify-native-smoke.XXXXXX")
readonly smoke_directory
readonly response="$smoke_directory/response.json"
readonly poll_response="$smoke_directory/poll.ndjson"
readonly server_log="$smoke_directory/server.log"
readonly username=admin
readonly password='native smoke password'
readonly message='durable native smoke message'
timestamp=$(date +%s)
readonly timestamp
readonly topic="native-smoke-$timestamp-$$"
port=${NOTIFY_NATIVE_SMOKE_PORT:-$((18000 + ($$ % 10000)))}
if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1024 || port > 65535)); then
  echo "NOTIFY_NATIVE_SMOKE_PORT must be between 1024 and 65535" >&2
  exit 2
fi
readonly port
readonly base_url="http://127.0.0.1:$port"
server_running=false
server_pid=''

export NOTIFY_INSTALL_DIR="$smoke_directory/install"
export NOTIFY_DATABASE_BACKEND=sqlite
export NOTIFY_DATABASE_PATH="$smoke_directory/notify.db"
export NOTIFY_ATTACHMENT_BACKEND=filesystem
export NOTIFY_ATTACHMENT_DIRECTORY="$smoke_directory/attachments"
export NOTIFY_PASSWORD="$password"

cleanup() {
  if [[ $server_running == true ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -d $smoke_directory ]]; then
    find "$smoke_directory" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

run_native() {
  local output=$1
  shift
  if ! "$artifact" "$@" >"$output"; then
    sed -E 's/tk_[A-Za-z0-9]{29}/<redacted>/g' "$output" >&2
    echo "native command failed: $1" >&2
    return 1
  fi
}

run_native "$smoke_directory/help.log" help
grep -F 'Notify' "$smoke_directory/help.log" >/dev/null
grep -F 'Usage: notify <command> [options]' "$smoke_directory/help.log" >/dev/null

run_native "$smoke_directory/setup.log" setup \
  --username "$username" \
  --anonymous-access deny
grep -Fx "setup complete; administrator $username created" \
  "$smoke_directory/setup.log" >/dev/null

run_native "$smoke_directory/token.log" token create "$username" \
  --label native-smoke
raw_token=$(grep -E '^tk_[A-Za-z0-9]{29}$' "$smoke_directory/token.log" | tail -n 1 || true)
if [[ ! $raw_token =~ ^tk_[A-Za-z0-9]{29}$ ]]; then
  echo "native token command did not return the fixed 32-character contract" >&2
  exit 1
fi
readonly raw_token

start_server() {
  : >"$server_log"
  "$artifact" serve \
    --listen-host 127.0.0.1 \
    --port "$port" \
    --base-url "$base_url" \
    --log-format json >"$server_log" 2>&1 &
  server_pid=$!
  server_running=true

  local attempt
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    if curl --fail --silent --show-error "$base_url/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      sed -E 's/tk_[A-Za-z0-9]{29}/<redacted>/g' "$server_log" >&2
      return 1
    fi
    sleep 1
  done
  sed -E 's/tk_[A-Za-z0-9]{29}/<redacted>/g' "$server_log" >&2
  echo "native server did not become healthy within 30 seconds" >&2
  return 1
}

stop_server() {
  kill -TERM "$server_pid"
  local exit_code=0
  wait "$server_pid" || exit_code=$?
  server_running=false
  if ((exit_code != 0)); then
    sed -E 's/tk_[A-Za-z0-9]{29}/<redacted>/g' "$server_log" >&2
    echo "native server exited with status $exit_code" >&2
    return 1
  fi
  grep -F 'shutdown signal received; draining connections' "$server_log" >/dev/null
  grep -F 'shutdown complete' "$server_log" >/dev/null
}

start_server
run_native "$response" publish "$topic" "$message" \
  --server "$base_url" \
  --token "$raw_token"
message_id=$(jq -er \
  --arg topic "$topic" \
  --arg message "$message" \
  'select(.event == "message" and .topic == $topic and .message == $message)
   | .id | select(type == "string" and length == 12)' \
  "$response")
run_native "$poll_response" subscribe "$topic" \
  --server "$base_url" \
  --token "$raw_token" \
  --since all
jq -se --arg id "$message_id" \
  '[.[] | select(.event == "message" and .id == $id)] | length == 1' \
  "$poll_response" >/dev/null
stop_server

start_server
run_native "$poll_response" subscribe "$topic" \
  --server "$base_url" \
  --token "$raw_token" \
  --since all
jq -se --arg id "$message_id" \
  '[.[] | select(.event == "message" and .id == $id)] | length == 1' \
  "$poll_response" >/dev/null
stop_server

echo "native setup, publish/poll, restart, and graceful shutdown smoke passed"
