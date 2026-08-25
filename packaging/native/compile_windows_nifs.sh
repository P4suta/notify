#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu

readonly source_root="${1:-/source}"
native_root=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
readonly native_root
compatibility_root="$native_root/windows_compat"
readonly compatibility_root
readonly erts_include="$source_root/.native-erts-include"

if [ ! -d "$source_root/deps" ] || [ ! -d "$source_root/_build/prod/lib" ]; then
  echo "staged Mix source is incomplete: $source_root" >&2
  exit 2
fi
if [ ! -f "$erts_include/erl_nif.h" ]; then
  echo "staged Erlang NIF headers are missing: $erts_include" >&2
  exit 2
fi
"$native_root/configure_windows_nif_headers.sh" "$erts_include"

readonly abi_check_object="$source_root/.windows-nif-abi-check.o"
zig cc \
  -target x86_64-windows-gnu \
  -std=c11 \
  -c \
  -I "$erts_include" \
  "$compatibility_root/nif_abi_check.c" \
  -o "$abi_check_object"
rm -f -- "$abi_check_object"

for dependency in bcrypt esqlite jargon; do
  if [ ! -d "$source_root/deps/$dependency" ]; then
    echo "native dependency source is missing: $dependency" >&2
    exit 2
  fi
  mkdir -p "$source_root/_build/prod/lib/$dependency/priv"
done

readonly esqlite_output="$source_root/_build/prod/lib/esqlite/priv/esqlite3_nif.dll"
readonly bcrypt_output="$source_root/_build/prod/lib/bcrypt/priv/bcrypt_nif.dll"
readonly jargon_output="$source_root/_build/prod/lib/jargon/priv/jargon.dll"

zig cc \
  -target x86_64-windows-gnu \
  -Os \
  -std=c11 \
  -shared \
  -DSQLITE_DQS=0 \
  -DSQLITE_THREADSAFE=1 \
  -DSQLITE_DEFAULT_MEMSTATUS=0 \
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS \
  -DSQLITE_MAX_EXPR_DEPTH=0 \
  -DSQLITE_OMIT_DEPRECATED \
  -DSQLITE_OMIT_PROGRESS_CALLBACK \
  -DSQLITE_USE_ALLOCA \
  -DSQLITE_OMIT_AUTOINIT \
  -DSQLITE_USE_URI \
  -DSQLITE_ENABLE_FTS3 \
  -DSQLITE_ENABLE_FTS3_PARENTHESIS \
  -DSQLITE_ENABLE_FTS4 \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_ENABLE_MATH_FUNCTIONS \
  -DSQLITE_ENABLE_JSON1 \
  -DSQLITE_ENABLE_RTREE \
  -DSQLITE_ENABLE_GEOPOLY \
  -I "$erts_include" \
  -I "$source_root/deps/esqlite/c_src/sqlite3" \
  "$source_root/deps/esqlite/c_src/esqlite3_nif.c" \
  "$source_root/deps/esqlite/c_src/sqlite3/sqlite3.c" \
  -o "$esqlite_output" \
  -lm

zig cc \
  -target x86_64-windows-gnu \
  -O2 \
  -std=c99 \
  -shared \
  -I "$erts_include" \
  -I "$source_root/deps/jargon/argon2/include" \
  "$source_root/deps/jargon/c_src/jargon.c" \
  "$source_root/deps/jargon/argon2/src/argon2.c" \
  "$source_root/deps/jargon/argon2/src/core.c" \
  "$source_root/deps/jargon/argon2/src/blake2/blake2b.c" \
  "$source_root/deps/jargon/argon2/src/thread.c" \
  "$source_root/deps/jargon/argon2/src/encoding.c" \
  "$source_root/deps/jargon/argon2/src/ref.c" \
  -o "$jargon_output"

zig cc \
  -target x86_64-windows-gnu \
  -O2 \
  -std=c99 \
  -shared \
  -include "$compatibility_root/bcrypt_compat.h" \
  -I "$compatibility_root/include" \
  -I "$erts_include" \
  -I "$source_root/deps/bcrypt/c_src" \
  "$compatibility_root/bcrypt_async_queue.c" \
  "$source_root/deps/bcrypt/c_src/bcrypt.c" \
  "$source_root/deps/bcrypt/c_src/blowfish.c" \
  "$source_root/deps/bcrypt/c_src/bcrypt_nif.c" \
  -o "$bcrypt_output"

for artifact in "$esqlite_output" "$bcrypt_output" "$jargon_output"; do
  if [ ! -s "$artifact" ]; then
    echo "Windows NIF was not produced: $artifact" >&2
    exit 1
  fi
  if ! file -b "$artifact" | grep -Eq 'PE32\+.*DLL.*x86-64'; then
    echo "Windows NIF is not an x86-64 PE DLL: $artifact" >&2
    exit 1
  fi
done

echo "cross-compiled bcrypt, esqlite, and jargon NIFs for Windows"
