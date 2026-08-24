#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
compose=(docker compose --project-name notify-browser-e2e -f "$root/compose.e2e.yml")

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

for dependency in curl docker npm; do
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
"${compose[@]}" up --build --detach notify

setup_url=""
for _ in $(seq 1 90); do
  logs=$("${compose[@]}" logs --no-color notify 2>/dev/null || true)
  setup_url=$(printf '%s\n' "$logs" \
    | sed -n 's|.*\(http://localhost:18082/setup?token=[-_A-Za-z0-9]*\).*|\1|p' \
    | tail -1)
  if [ -n "$setup_url" ] && curl --fail --silent http://localhost:18082/healthz >/dev/null; then
    break
  fi
  sleep 1
done

if [ -z "$setup_url" ]; then
  "${compose[@]}" logs --no-color notify >&2
  echo "Notify did not emit a setup URL" >&2
  exit 1
fi

NOTIFY_E2E_BASE_URL=http://localhost:18082 \
NOTIFY_E2E_SETUP_URL="$setup_url" \
npm --prefix "$root/test/e2e" test
