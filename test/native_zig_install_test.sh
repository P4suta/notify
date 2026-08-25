#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
installer="$root/packaging/native/install_zig.sh"

if [ ! -x "$installer" ]; then
  echo "native Zig installer is missing or not executable: $installer" >&2
  exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/notify-zig-test.XXXXXX")
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_root/bin" "$test_root/runner"
github_path="$test_root/github-path"
curl_marker="$test_root/curl-called"
: >"$github_path"

# The generated fake downloader must expand these values only when it runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'output=' \
  'while (($# > 0)); do' \
  '  case "$1" in' \
  '    --output)' \
  '      shift' \
  '      output=${1:-}' \
  '      ;;' \
  '  esac' \
  '  shift' \
  'done' \
  ': "${output:?curl output was not provided}"' \
  ': "${FAKE_CURL_MARKER:?curl marker was not provided}"' \
  'printf tampered >"$output"' \
  'printf called >"$FAKE_CURL_MARKER"' \
  >"$test_root/bin/curl"
chmod +x "$test_root/bin/curl"

run_installer() {
  RUNNER_TEMP="$test_root/runner" \
    GITHUB_PATH="$github_path" \
    FAKE_CURL_MARKER="$curl_marker" \
    PATH="$test_root/bin:$PATH" \
    "$installer" "$@"
}

if run_installer 0.15.3 >"$test_root/unsupported.log" 2>&1; then
  echo "unsupported Zig version was accepted" >&2
  exit 1
fi
grep -F "unsupported Zig version: 0.15.3" "$test_root/unsupported.log" >/dev/null
if [ -e "$curl_marker" ]; then
  echo "unsupported Zig version reached the downloader" >&2
  exit 1
fi

if run_installer 0.15.2 >"$test_root/checksum.log" 2>&1; then
  echo "checksum-mismatched Zig archive was accepted" >&2
  exit 1
fi
grep -F "checksum mismatch for Zig 0.15.2" "$test_root/checksum.log" >/dev/null
if [ -s "$github_path" ]; then
  echo "checksum failure modified GITHUB_PATH" >&2
  exit 1
fi

echo "native Zig installer rejection contracts passed"
