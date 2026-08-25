#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
configurator="$root/packaging/native/configure_windows_nif_headers.sh"

if [ ! -x "$configurator" ]; then
  echo "Windows NIF header configurator is missing or not executable: $configurator" >&2
  exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/notify-windows-nif-headers.XXXXXX")
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

create_required_headers() {
  local include_directory=$1
  mkdir -p "$include_directory"
  for header in erl_drv_nif.h erl_nif.h erl_nif_api_funcs.h; do
    : >"$include_directory/$header"
  done
}

write_size_header() {
  local include_directory=$1
  local long_size=$2
  printf '%s\n' \
    '#define SIZEOF_CHAR 1' \
    '#define SIZEOF_SHORT 2' \
    '#define SIZEOF_INT 4' \
    "#define SIZEOF_LONG $long_size" \
    '#define SIZEOF_LONG_LONG 8' \
    '#define SIZEOF_VOID_P 8' \
    >"$include_directory/erl_int_sizes_config.h"
}

lp64_include="$test_root/lp64"
create_required_headers "$lp64_include"
write_size_header "$lp64_include" 8
"$configurator" "$lp64_include" >/dev/null

readonly expected_windows_contract='#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 4
#define SIZEOF_LONG_LONG 8
#define SIZEOF_VOID_P 8'
actual_windows_contract=$(cat "$lp64_include/erl_int_sizes_config.h")
if [ "$actual_windows_contract" != "$expected_windows_contract" ]; then
  echo "LP64 headers were not converted to the Windows amd64 contract" >&2
  exit 1
fi

cp "$lp64_include/erl_int_sizes_config.h" "$test_root/configured-header"
"$configurator" "$lp64_include" >/dev/null
if ! cmp -s \
  "$test_root/configured-header" \
  "$lp64_include/erl_int_sizes_config.h"
then
  echo "Windows NIF header configuration was not idempotent" >&2
  exit 1
fi

unsupported_include="$test_root/unsupported"
create_required_headers "$unsupported_include"
write_size_header "$unsupported_include" 16
if "$configurator" "$unsupported_include" >"$test_root/unsupported.log" 2>&1; then
  echo "unsupported Erlang integer sizes were accepted" >&2
  exit 1
fi
grep -F "unsupported integer-size contract" "$test_root/unsupported.log" >/dev/null

ambiguous_include="$test_root/ambiguous"
create_required_headers "$ambiguous_include"
write_size_header "$ambiguous_include" 8
printf '%s\n' '#define SIZEOF_LONG 8' \
  >>"$ambiguous_include/erl_int_sizes_config.h"
if "$configurator" "$ambiguous_include" >"$test_root/ambiguous.log" 2>&1; then
  echo "ambiguous Erlang integer sizes were accepted" >&2
  exit 1
fi
grep -F "incomplete or ambiguous" "$test_root/ambiguous.log" >/dev/null

missing_include="$test_root/missing"
create_required_headers "$missing_include"
write_size_header "$missing_include" 8
rm "$missing_include/erl_nif_api_funcs.h"
if "$configurator" "$missing_include" >"$test_root/missing.log" 2>&1; then
  echo "incomplete Erlang NIF headers were accepted" >&2
  exit 1
fi
grep -F "staged Erlang NIF header is missing" "$test_root/missing.log" >/dev/null

echo "Windows NIF header contracts passed"
