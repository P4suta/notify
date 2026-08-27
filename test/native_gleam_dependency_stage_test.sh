#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
stager="$root/packaging/native/stage_runtime_gleam_dependencies.sh"

if [ ! -x "$stager" ]; then
  echo "runtime Gleam dependency stager is missing or not executable: $stager" >&2
  exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/notify-gleam-stage-test.XXXXXX")
cleanup() {
  if [ -d "$test_root" ]; then
    find "$test_root" -depth -delete
  fi
}
trap cleanup EXIT HUP INT TERM

stage="$test_root/source"
http3="$stage/deps/http3"
gleam_quic="$http3/packages/gleam_quic"
mkdir -p \
  "$http3/src" \
  "$http3/test/fixtures" \
  "$gleam_quic/src" \
  "$gleam_quic/test/fixtures" \
  "$stage/deps/unrelated/test"

for descriptor in \
  "$stage/mix.exs" \
  "$http3/mix.exs" \
  "$http3/gleam.toml" \
  "$gleam_quic/mix.exs" \
  "$gleam_quic/gleam.toml"
do
  : >"$descriptor"
done
: >"$stage/.notify-native-runtime-stage"
: >"$http3/src/http3.gleam"
: >"$http3/test/http3_test.gleam"
: >"$http3/test/fixtures/certificate.pem"
: >"$gleam_quic/src/gleam_quic.gleam"
: >"$gleam_quic/test/gleam_quic_test.gleam"
: >"$gleam_quic/test/fixtures/key.pem"
: >"$stage/deps/unrelated/test/keep.gleam"

"$stager" "$stage"

for removed in "$http3/test" "$gleam_quic/test"; do
  if [ -e "$removed" ]; then
    echo "dependency test tree was not removed: $removed" >&2
    exit 1
  fi
done
for preserved in \
  "$http3/src/http3.gleam" \
  "$http3/mix.exs" \
  "$gleam_quic/src/gleam_quic.gleam" \
  "$gleam_quic/mix.exs" \
  "$stage/deps/unrelated/test/keep.gleam"
do
  if [ ! -f "$preserved" ]; then
    echo "runtime stager removed an out-of-scope file: $preserved" >&2
    exit 1
  fi
done

# A repeated pass is safe, which keeps retries deterministic.
"$stager" "$stage"

find "$gleam_quic/mix.exs" -delete
if "$stager" "$stage" >"$test_root/missing.log" 2>&1; then
  echo "runtime stager accepted incomplete gleam_quic metadata" >&2
  exit 1
fi
grep -F "required runtime dependency metadata is missing" \
  "$test_root/missing.log" >/dev/null

: >"$gleam_quic/mix.exs"
find "$stage/.notify-native-runtime-stage" -delete
if "$stager" "$stage" >"$test_root/marker.log" 2>&1; then
  echo "runtime stager accepted an unmarked directory" >&2
  exit 1
fi
grep -F "refusing to modify an unmarked native stage" \
  "$test_root/marker.log" >/dev/null

echo "native Gleam dependency staging contracts passed"
