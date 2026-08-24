#!/bin/sh
set -eu

os=$(uname -s)
arch=$(uname -m)

case "$os:$arch" in
  Linux:x86_64) target=linux_amd64 ;;
  Linux:aarch64|Linux:arm64) target=linux_arm64 ;;
  Darwin:x86_64) target=macos_amd64 ;;
  Darwin:arm64) target=macos_arm64 ;;
  *) echo "unsupported native build host: $os $arch" >&2; exit 1 ;;
esac

export BURRITO_TARGET="$target"
export MIX_ENV=prod
mix do deps.get, release
