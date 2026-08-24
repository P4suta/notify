#!/bin/sh
set -eu

base_url=${NOTIFY_SMOKE_URL:-http://127.0.0.1:18081}
username=${NOTIFY_SMOKE_USERNAME:-admin}
password=${NOTIFY_SMOKE_PASSWORD:-compat-only-password}
smoke_dir=$(mktemp -d /tmp/notify-admin-smoke.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT HUP INT TERM

cookie_jar="$smoke_dir/cookies"
response="$smoke_dir/response.json"
request="$smoke_dir/request.json"
test_username="pwa$(date +%s)$$"

status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --cookie-jar "$cookie_jar" \
  --header 'content-type: application/json' \
  --data "{\"username\":\"$username\",\"password\":\"$password\"}" \
  "$base_url/api/v1/session")
test "$status" = 201
csrf=$(jq -er '.csrf_token' "$response")

jq -n \
  --arg username "$test_username" \
  --arg password 'temporary browser smoke password' \
  '{username:$username,password:$password,role:"user"}' >"$request"
status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  --header 'content-type: application/json' \
  --data-binary "@$request" \
  "$base_url/api/v1/users")
test "$status" = 201

jq -n \
  --arg username "$test_username" \
  '{username:$username,label:"browser-smoke"}' >"$request"
status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  --header 'content-type: application/json' \
  --data-binary "@$request" \
  "$base_url/api/v1/tokens")
test "$status" = 201
token_id=$(jq -er '.id' "$response")
raw_token=$(jq -er '.token | select(startswith("tk_"))' "$response")

curl --fail --silent --show-error \
  --cookie "$cookie_jar" \
  "$base_url/api/v1/tokens?username=$test_username" >"$response"
jq -e --arg id "$token_id" '.items | any(.id == $id)' "$response" >/dev/null
if ! jq -e --arg raw "$raw_token" 'tostring | contains($raw) | not' "$response" >/dev/null; then
  echo 'raw token leaked through token listing' >&2
  exit 1
fi

jq -n \
  --arg username "$test_username" \
  '{username:$username,topic_pattern:"browser-*",permission:"read-write"}' >"$request"
status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --request PUT \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  --header 'content-type: application/json' \
  --data-binary "@$request" \
  "$base_url/api/v1/acl")
test "$status" = 200

curl --fail --silent --show-error --cookie "$cookie_jar" \
  "$base_url/api/v1/delivery-jobs" >/dev/null
curl --fail --silent --show-error --cookie "$cookie_jar" \
  "$base_url/api/v1/attachments" >/dev/null

status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --request DELETE \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  --header 'content-type: application/json' \
  --data-binary "@$request" \
  "$base_url/api/v1/acl")
test "$status" = 204

status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --request DELETE \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  "$base_url/api/v1/tokens/$token_id")
test "$status" = 204

status=$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
  --request DELETE \
  --cookie "$cookie_jar" \
  --header "x-csrf-token: $csrf" \
  "$base_url/api/v1/users/$test_username")
test "$status" = 204

echo 'admin session smoke passed'
