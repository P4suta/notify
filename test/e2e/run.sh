#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
browser=${NOTIFY_E2E_BROWSER:-chromium}
device=${NOTIFY_E2E_DEVICE:-desktop}
case "$browser" in
  chromium|firefox|webkit) ;;
  *) echo "unsupported NOTIFY_E2E_BROWSER: $browser" >&2; exit 2 ;;
esac
case "$device" in
  desktop|mobile) ;;
  *) echo "unsupported NOTIFY_E2E_DEVICE: $device" >&2; exit 2 ;;
esac
project_name=${NOTIFY_E2E_PROJECT_NAME:-"notify-browser-e2e-$browser-$device"}
compose=(docker compose --project-name "$project_name" -f "$root/compose.e2e.yml")
base_url=https://localhost:18443
tls_directory=""
tls_pid=""

cleanup() {
  if [ -n "$tls_pid" ] && kill -0 "$tls_pid" 2>/dev/null; then
    kill "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ "$tls_directory" == /tmp/notify-e2e-tls.* ]] && [ -d "$tls_directory" ]; then
    find "$tls_directory" -type f -delete
    rmdir "$tls_directory"
  fi
}
trap cleanup EXIT HUP INT TERM

for dependency in curl docker node npm openssl; do
  command -v "$dependency" >/dev/null || {
    echo "missing required command: $dependency" >&2
    exit 2
  }
done

test -x "$root/test/e2e/node_modules/.bin/playwright" || {
  echo "install browser-test dependencies with: npm ci --prefix test/e2e" >&2
  exit 2
}

cleanup
tls_directory=$(mktemp -d /tmp/notify-e2e-tls.XXXXXX)
tls_certificate="$tls_directory/certificate.pem"
tls_key="$tls_directory/key.pem"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$tls_key" -out "$tls_certificate" >/dev/null 2>&1
node "$root/test/e2e/tls_proxy.mjs" "$tls_certificate" "$tls_key" &
tls_pid=$!

"${compose[@]}" up --build --detach notify

setup_url=""
for _ in $(seq 1 90); do
  logs=$("${compose[@]}" logs --no-color notify 2>/dev/null || true)
  setup_url=$(printf '%s\n' "$logs" \
    | sed -n 's|.*\(https://localhost:18443/setup?token=[-_A-Za-z0-9]*\).*|\1|p' \
    | tail -1)
  if [ -n "$setup_url" ] \
    && curl --cacert "$tls_certificate" --fail --silent "$base_url/healthz" >/dev/null; then
    break
  fi
  sleep 1
done

if [ -z "$setup_url" ]; then
  "${compose[@]}" logs --no-color notify >&2
  echo "Notify did not emit a setup URL" >&2
  exit 1
fi

NOTIFY_E2E_BASE_URL="$base_url" \
NOTIFY_E2E_SETUP_URL="$setup_url" \
NOTIFY_E2E_BROWSER="$browser" \
NOTIFY_E2E_DEVICE="$device" \
npm --prefix "$root/test/e2e" test
