#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

baseline_url="${NTFY_BASELINE_URL:-http://127.0.0.1:18080}"
notify_url="${NOTIFY_URL:-http://127.0.0.1:18081}"
corpus="${NOTIFY_COMPAT_CORPUS:-$(cd "$(dirname "$0")" && pwd)/cases.ndjson}"
fixture_dir="${NOTIFY_COMPAT_OUTPUT:-$(mktemp -d)}"
topic="compat$(date +%s)${RANDOM}"
capture_dir=""

umask 077

redact_tokens() {
  local source="$1"
  local destination="$source.redacted"
  sed -E 's/tk_[A-Za-z0-9]{29}/<redacted>/g' "$source" >"$destination"
  mv "$destination" "$source"
}

cleanup_sensitive_data() {
  local status=$?
  set +e
  if [[ -n "$capture_dir" && -d "$capture_dir" ]]; then
    find "$capture_dir" -type f -delete
    find "$capture_dir" -depth -type d -empty -delete
  fi
  if [[ -d "$fixture_dir" ]]; then
    while IFS= read -r -d '' fixture; do
      redact_tokens "$fixture" || true
    done < <(find "$fixture_dir" -maxdepth 1 -type f \
      \( -name 'baseline-*' -o -name 'notify-*' \) -print0)
  fi
  return "$status"
}
trap cleanup_sensitive_data EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for dependency in curl diff find grep jq sed; do
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
      jq --sort-keys \
        'def action: {id_contract: {length: ((.id // "") | length), alphanumeric: ((.id // "") | test("^[A-Za-z0-9]+$"))}, value: del(.id)}; {id_contract: {length: (.id | length), alphanumeric: (.id | test("^[A-Za-z0-9]+$"))}, value: (del(.id, .time, .expires, .attachment.expires) | if has("actions") then .actions |= map(action) else . end)}' \
        "$source" >"$destination"
      ;;
    ndjson)
      jq --slurp --sort-keys \
        'def action: {id_contract: {length: ((.id // "") | length), alphanumeric: ((.id // "") | test("^[A-Za-z0-9]+$"))}, value: del(.id)}; map({id_contract: {length: (.id | length), alphanumeric: (.id | test("^[A-Za-z0-9]+$"))}, value: (del(.id, .time, .expires, .attachment.expires) | if has("actions") then .actions |= map(action) else . end)})' \
        "$source" >"$destination"
      ;;
    sse)
      sed -n 's/^data: //p' "$source" \
        | jq --slurp --sort-keys \
          'def action: {id_contract: {length: ((.id // "") | length), alphanumeric: ((.id // "") | test("^[A-Za-z0-9]+$"))}, value: del(.id)}; map({id_contract: {length: (.id | length), alphanumeric: (.id | test("^[A-Za-z0-9]+$"))}, value: (del(.id, .time, .expires, .attachment.expires) | if has("actions") then .actions |= map(action) else . end)})' \
          >"$destination"
      ;;
    error)
      jq --sort-keys . "$source" >"$destination"
      ;;
    json)
      jq --sort-keys . "$source" >"$destination"
      ;;
    login)
      jq --sort-keys \
        '{username, token_contract: {prefix: (.token[0:3]), length: (.token | length), valid: (.token | test("^tk_[A-Za-z0-9]{29}$"))}}' \
        "$source" >"$destination"
      ;;
    issued_token)
      jq --sort-keys \
        '{label: (.label // ""), expires_contract: {present: has("expires"), positive: ((.expires // 0) > 0)}, token_contract: {prefix: (.token[0:3]), length: (.token | length), valid: (.token | test("^tk_[A-Za-z0-9]{29}$"))}}' \
        "$source" >"$destination"
      ;;
    account)
      jq --sort-keys '
        def token_contract:
          {token_contract: {prefix: (.token[0:3]), valid: (.token | test("^tk_[A-Za-z0-9]+$"))}, label: (.label // ""), expires_present: has("expires"), last_access_present: has("last_access")};
        {
          username,
          role,
          sync_topic_contract: (if has("sync_topic") then {length: (.sync_topic | length), valid: (.sync_topic | test("^st_[-_A-Za-z0-9]{13}$"))} else null end),
          tokens: ((.tokens // []) | map(token_contract) | sort_by(.label)),
          limits: {
            keys: (.limits | keys),
            basis: .limits.basis,
            messages_expiry_duration: .limits.messages_expiry_duration,
            attachment_total_size: .limits.attachment_total_size,
            attachment_file_size: .limits.attachment_file_size,
            attachment_expiry_duration: .limits.attachment_expiry_duration
          },
          stats: {
            keys: (.stats | keys),
            messages: .stats.messages,
            emails: .stats.emails,
            calls: .stats.calls,
            reservations: .stats.reservations,
            attachment_total_size: .stats.attachment_total_size
          }
        }' "$source" >"$destination"
      ;;
    raw)
      jq --raw-input --slurp . "$source" >"$destination"
      ;;
    empty)
      printf 'null\n' >"$destination"
      ;;
    *)
      cp "$source" "$destination"
      ;;
  esac
}

substitute_value() {
  local side="$1"
  local value="${2//__TOPIC__/$topic}"
  local capture_file capture_name capture_value placeholder
  for capture_file in "$capture_dir/$side/"*; do
    [[ -f "$capture_file" ]] || continue
    capture_name="${capture_file##*/}"
    capture_value="$(<"$capture_file")"
    placeholder="__CAPTURE_${capture_name}__"
    value="${value//${placeholder}/${capture_value}}"
  done
  printf '%s' "$value"
}

run_case() {
  local base="$1"
  local side="$2"
  local encoded_case="$3"
  local case_json
  case_json="$(printf '%s' "$encoded_case" | base64 --decode)"
  local name method path body content_type normalizer body_repeat capture_name
  name="$(jq -r .name <<<"$case_json")"
  method="$(jq -r .method <<<"$case_json")"
  path="$(substitute_value "$side" "$(jq -r .path <<<"$case_json")")"
  body="$(substitute_value "$side" "$(jq -r .body <<<"$case_json")")"
  content_type="$(jq -r .content_type <<<"$case_json")"
  normalizer="$(jq -r .normalizer <<<"$case_json")"
  body_repeat="$(jq -r '.body_repeat // 0' <<<"$case_json")"
  capture_name="$(jq -r '.capture // ""' <<<"$case_json")"
  if [[ "$body_repeat" -gt 0 ]]; then
    body="$(printf '%*s' "$body_repeat" '' | tr ' ' x)"
  fi
  local raw_body="$fixture_dir/$side-$name.raw"
  local raw_headers="$fixture_dir/$side-$name.headers"
  local result="$fixture_dir/$side-$name.json"
  local -a arguments=(--silent --show-error --request "$method" --dump-header "$raw_headers" --output "$raw_body")
  if [[ -n "$content_type" ]]; then
    arguments+=(--header "Content-Type: $content_type")
  fi
  while IFS=$'\t' read -r header value; do
    if [[ -n "$header" ]]; then
      value="$(substitute_value "$side" "$value")"
      arguments+=(--header "$header: $value")
    fi
  done < <(jq -r '(.headers // {}) | to_entries[] | [.key, .value] | @tsv' <<<"$case_json")
  if [[ "$method" != "GET" && "$method" != "HEAD" ]]; then
    arguments+=(--data-binary "$body")
  fi
  local status
  status="$(curl "${arguments[@]}" --write-out '%{http_code}' "$base$path")"
  if [[ -n "$capture_name" ]]; then
    if [[ ! "$capture_name" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
      echo "invalid capture name in case $name" >&2
      return 1
    fi
    local capture_value
    capture_value="$(jq --exit-status --raw-output '.token | strings | select(length > 0)' "$raw_body")"
    if [[ ! "$capture_value" =~ ^tk_[A-Za-z0-9]{29}$ ]]; then
      echo "invalid captured token contract in case $name" >&2
      return 1
    fi
    printf '%s' "$capture_value" >"$capture_dir/$side/$capture_name"
  fi
  local media_type
  media_type="$(awk 'tolower($1) == "content-type:" {gsub(/\r/, ""); split($2, type, ";"); print type[1]}' "$raw_headers" | tail -1)"
  local normalised="$fixture_dir/$side-$name.body"
  normalise_body "$normalizer" "$raw_body" "$normalised"
  local response_headers='{}'
  while IFS= read -r header; do
    local value
    value="$(awk -v target="$header" \
      'tolower($1) == tolower(target ":") {gsub(/\r/, ""); $1=""; sub(/^ /, ""); print}' \
      "$raw_headers" | tail -1)"
    response_headers="$(jq --compact-output \
      --arg key "${header,,}" --arg value "$value" \
      '. + {($key): $value}' <<<"$response_headers")"
  done < <(jq -r '.response_headers // [] | .[]' <<<"$case_json")
  jq --null-input --sort-keys \
    --arg name "$name" \
    --argjson status "$status" \
    --arg media_type "$media_type" \
    --argjson response_headers "$response_headers" \
    --slurpfile body "$normalised" \
    '{name: $name, status: $status, media_type: $media_type, response_headers: $response_headers, body: $body[0]}' \
    >"$result"
  redact_tokens "$raw_body"
  redact_tokens "$raw_headers"
}

wait_for_health "$baseline_url"
wait_for_health "$notify_url"
mkdir -p "$fixture_dir"
capture_dir="$(mktemp -d "$fixture_dir/.captures.XXXXXX")"
mkdir -p "$capture_dir/baseline" "$capture_dir/notify"

while IFS= read -r encoded_case; do
  run_case "$baseline_url" baseline "$encoded_case"
  run_case "$notify_url" notify "$encoded_case"
done < <(jq -Rrc '@base64' "$corpus")

jq --slurp --sort-keys . "$fixture_dir"/baseline-*.json >"$fixture_dir/baseline.json"
jq --slurp --sort-keys . "$fixture_dir"/notify-*.json >"$fixture_dir/notify.json"

if grep -Eq 'tk_[A-Za-z0-9]{29}' \
  "$fixture_dir"/baseline-* "$fixture_dir"/notify-*; then
  echo "raw token leaked into retained compatibility fixtures" >&2
  exit 1
fi

if diff --unified "$fixture_dir/baseline.json" "$fixture_dir/notify.json"; then
  echo "ntfy v2.27.0 compatibility corpus passed"
  echo "normalised fixtures: $fixture_dir"
else
  echo "compatibility drift detected; fixtures retained at $fixture_dir" >&2
  exit 1
fi
