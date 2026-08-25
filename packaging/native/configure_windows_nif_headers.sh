#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ERTS_INCLUDE_DIRECTORY" >&2
  exit 64
fi

readonly include_directory="$1"
readonly sizes_header="$include_directory/erl_int_sizes_config.h"

for required_header in \
  erl_drv_nif.h \
  erl_int_sizes_config.h \
  erl_nif.h \
  erl_nif_api_funcs.h
do
  if [ ! -f "$include_directory/$required_header" ]; then
    echo "staged Erlang NIF header is missing: $include_directory/$required_header" >&2
    exit 66
  fi
done

size_contract() {
  awk '
    $1 == "#define" && $2 == "SIZEOF_CHAR" {
      char_count += 1
      char_size = $3
    }
    $1 == "#define" && $2 == "SIZEOF_SHORT" {
      short_count += 1
      short_size = $3
    }
    $1 == "#define" && $2 == "SIZEOF_INT" {
      int_count += 1
      int_size = $3
    }
    $1 == "#define" && $2 == "SIZEOF_LONG" {
      long_count += 1
      long_size = $3
    }
    $1 == "#define" && $2 == "SIZEOF_LONG_LONG" {
      long_long_count += 1
      long_long_size = $3
    }
    $1 == "#define" && $2 == "SIZEOF_VOID_P" {
      pointer_count += 1
      pointer_size = $3
    }
    END {
      if (char_count != 1 || short_count != 1 || int_count != 1 ||
          long_count != 1 || long_long_count != 1 || pointer_count != 1) {
        exit 1
      }
      printf "SIZEOF_CHAR=%s\n", char_size
      printf "SIZEOF_SHORT=%s\n", short_size
      printf "SIZEOF_INT=%s\n", int_size
      printf "SIZEOF_LONG=%s\n", long_size
      printf "SIZEOF_LONG_LONG=%s\n", long_long_size
      printf "SIZEOF_VOID_P=%s\n", pointer_size
    }
  ' "$sizes_header"
}

readonly lp64_contract='SIZEOF_CHAR=1
SIZEOF_SHORT=2
SIZEOF_INT=4
SIZEOF_LONG=8
SIZEOF_LONG_LONG=8
SIZEOF_VOID_P=8'
readonly windows_amd64_contract='SIZEOF_CHAR=1
SIZEOF_SHORT=2
SIZEOF_INT=4
SIZEOF_LONG=4
SIZEOF_LONG_LONG=8
SIZEOF_VOID_P=8'

if ! original_contract=$(size_contract); then
  echo "staged Erlang integer-size header is incomplete or ambiguous: $sizes_header" >&2
  exit 65
fi

case "$original_contract" in
  "$windows_amd64_contract")
    echo "Erlang NIF headers already describe Windows amd64 LLP64"
    exit 0
    ;;
  "$lp64_contract") ;;
  *)
    echo "staged Erlang NIF headers have an unsupported integer-size contract:" >&2
    printf '%s\n' "$original_contract" >&2
    exit 65
    ;;
esac

temporary_header=$(mktemp "$include_directory/.erl_int_sizes_config.h.XXXXXX")
cleanup() {
  if [ -n "${temporary_header:-}" ]; then
    rm -f -- "$temporary_header"
  fi
}
trap cleanup EXIT HUP INT TERM

awk '
  $1 == "#define" && $2 == "SIZEOF_LONG" && $3 == "8" {
    print "#define SIZEOF_LONG 4"
    replacements += 1
    next
  }
  { print }
  END {
    if (replacements != 1) {
      exit 1
    }
  }
' "$sizes_header" >"$temporary_header"
chmod 0644 "$temporary_header"
mv -f -- "$temporary_header" "$sizes_header"
temporary_header=

if ! configured_contract=$(size_contract); then
  echo "configured Erlang integer-size header is incomplete or ambiguous" >&2
  exit 65
fi
if [ "$configured_contract" != "$windows_amd64_contract" ]; then
  echo "failed to configure Erlang NIF headers for Windows amd64" >&2
  exit 65
fi

echo "configured staged Erlang NIF headers for Windows amd64 LLP64"
