#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

baseline_url="${NTFY_BASELINE_URL:-http://127.0.0.1:18080}"
notify_url="${NOTIFY_URL:-http://127.0.0.1:18081}"
corpus="${NOTIFY_COMPAT_CORPUS:-$(cd "$(dirname "$0")" && pwd)/cases.ndjson}"
fixture_dir="${NOTIFY_COMPAT_OUTPUT:-$(mktemp -d)}"
topic="compat$(date +%s)${RANDOM}"

for dependency in curl jq diff; do
  command -v "$dependency" >/dev/null || {
    echo "missing required command: $dependency" >&2
    exit 2
  }
done

wait_for_health() {
  local base="$1"
  local attempts=0
  until curl --fail --silent --show-error "$base/v1/health" >/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 60 ]]; then
      echo "server did not become healthy: $base" >&2
      return 1
    fi
    sleep 1
  done
}

normalise_body() {
  local kind="$1"
  local source="$2"
  local destination="$3"
  case "$kind" in
    message)
      jq --sort-keys 'del(.id, .time, .expires, .attachment.expires)' \
        "$source" >"$destination"
      ;;
    ndjson)
      jq --slurp --sort-keys \
        'map(del(.id, .time, .expires, .attachment.expires))' \
        "$source" >"$destination"
      ;;
    error)
      jq --sort-keys . "$source" >"$destination"
      ;;
    *)
      cp "$source" "$destination"
      ;;
  esac
}

run_case() {
  local base="$1"
  local side="$2"
  local encoded_case="$3"
  local case_json
  case_json="$(printf '%s' "$encoded_case" | base64 --decode)"
  local name method path body content_type normalizer
  name="$(jq -r .name <<<"$case_json")"
  method="$(jq -r .method <<<"$case_json")"
  path="$(jq -r .path <<<"$case_json" | sed "s/__TOPIC__/$topic/g")"
  body="$(jq -r .body <<<"$case_json" | sed "s/__TOPIC__/$topic/g")"
  content_type="$(jq -r .content_type <<<"$case_json")"
  normalizer="$(jq -r .normalizer <<<"$case_json")"
  local raw_body="$fixture_dir/$side-$name.raw"
  local raw_headers="$fixture_dir/$side-$name.headers"
  local result="$fixture_dir/$side-$name.json"
  local -a arguments=(--silent --show-error --request "$method" --dump-header "$raw_headers" --output "$raw_body")
  if [[ -n "$content_type" ]]; then
    arguments+=(--header "Content-Type: $content_type")
  fi
  while IFS=$'\t' read -r header value; do
    [[ -n "$header" ]] && arguments+=(--header "$header: $value")
  done < <(jq -r '(.headers // {}) | to_entries[] | [.key, .value] | @tsv' <<<"$case_json")
  if [[ "$method" != "GET" && "$method" != "HEAD" ]]; then
    arguments+=(--data-binary "$body")
  fi
  local status
  status="$(curl "${arguments[@]}" --write-out '%{http_code}' "$base$path")"
  local media_type
  media_type="$(awk 'tolower($1) == "content-type:" {gsub(/\r/, ""); split($2, type, ";"); print type[1]}' "$raw_headers" | tail -1)"
  local normalised="$fixture_dir/$side-$name.body"
  normalise_body "$normalizer" "$raw_body" "$normalised"
  jq --null-input --sort-keys \
    --arg name "$name" \
    --argjson status "$status" \
    --arg media_type "$media_type" \
    --slurpfile body "$normalised" \
    '{name: $name, status: $status, media_type: $media_type, body: $body[0]}' \
    >"$result"
}

wait_for_health "$baseline_url"
wait_for_health "$notify_url"
mkdir -p "$fixture_dir"

while IFS= read -r encoded_case; do
  run_case "$baseline_url" baseline "$encoded_case"
  run_case "$notify_url" notify "$encoded_case"
done < <(jq -Rrc '@base64' "$corpus")

jq --slurp --sort-keys . "$fixture_dir"/baseline-*.json >"$fixture_dir/baseline.json"
jq --slurp --sort-keys . "$fixture_dir"/notify-*.json >"$fixture_dir/notify.json"

if diff --unified "$fixture_dir/baseline.json" "$fixture_dir/notify.json"; then
  echo "ntfy v2.27.0 compatibility corpus passed"
  echo "normalised fixtures: $fixture_dir"
else
  echo "compatibility drift detected; fixtures retained at $fixture_dir" >&2
  exit 1
fi
