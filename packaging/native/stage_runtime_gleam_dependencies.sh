#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: packaging/native/stage_runtime_gleam_dependencies.sh STAGE" >&2
  exit 2
fi

if [ ! -d "$1" ]; then
  echo "native stage directory does not exist: $1" >&2
  exit 1
fi
stage=$(CDPATH='' cd -- "$1" && pwd -P)
if [ "$stage" = / ] || [ ! -f "$stage/.notify-native-runtime-stage" ]; then
  echo "refusing to modify an unmarked native stage: $stage" >&2
  exit 1
fi
if [ ! -f "$stage/mix.exs" ]; then
  echo "staged Notify Mix project is missing: $stage/mix.exs" >&2
  exit 1
fi

http3="$stage/deps/http3"
gleam_quic="$http3/packages/gleam_quic"
for metadata in \
  "$http3/gleam.toml" \
  "$http3/mix.exs" \
  "$gleam_quic/gleam.toml" \
  "$gleam_quic/mix.exs"
do
  if [ ! -f "$metadata" ]; then
    echo "required runtime dependency metadata is missing: $metadata" >&2
    exit 1
  fi
done
for source_tree in "$http3/src" "$gleam_quic/src"; do
  if [ ! -d "$source_tree" ]; then
    echo "required runtime dependency source is missing: $source_tree" >&2
    exit 1
  fi
done

# MixGleam compiles a dependency's test tree when it is present. These two
# exact, immutable dependency paths are the only trees excluded from the
# runtime stage; source, metadata, and every unrelated dependency stay intact.
for test_tree in "$http3/test" "$gleam_quic/test"; do
  if [ -e "$test_tree" ] || [ -L "$test_tree" ]; then
    find "$test_tree" -depth -delete
  fi
  if [ -e "$test_tree" ] || [ -L "$test_tree" ]; then
    echo "could not remove dependency test tree: $test_tree" >&2
    exit 1
  fi
done
