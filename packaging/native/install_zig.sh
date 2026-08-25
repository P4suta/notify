#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 VERSION" >&2
  exit 64
fi

readonly version=$1
if [ "$version" != 0.15.2 ]; then
  echo "unsupported Zig version: $version" >&2
  exit 64
fi

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

for required_command in curl tar uname; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    readonly platform=x86_64-linux
    readonly expected_checksum=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239
    ;;
  Linux:aarch64 | Linux:arm64)
    readonly platform=aarch64-linux
    readonly expected_checksum=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f
    ;;
  Darwin:x86_64)
    readonly platform=x86_64-macos
    readonly expected_checksum=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f
    ;;
  Darwin:arm64 | Darwin:aarch64)
    readonly platform=aarch64-macos
    readonly expected_checksum=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b
    ;;
  *)
    echo "unsupported Zig host: $(uname -s) $(uname -m)" >&2
    exit 64
    ;;
esac

readonly download_url="https://ziglang.org/download/$version/zig-$platform-$version.tar.xz"
archive=$(mktemp "$RUNNER_TEMP/notify-zig-$platform.XXXXXX")
install_root=
install_complete=false

cleanup() {
  rm -f -- "$archive"
  if [ "$install_complete" != true ] && [ -n "$install_root" ]; then
    rm -rf -- "$install_root"
  fi
}
trap cleanup EXIT HUP INT TERM

curl \
  --fail \
  --location \
  --proto '=https' \
  --retry 3 \
  --show-error \
  --silent \
  --tlsv1.2 \
  --output "$archive" \
  "$download_url"

if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum=$(sha256sum "$archive")
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum=$(shasum -a 256 "$archive")
else
  echo "required SHA-256 command not found: sha256sum or shasum" >&2
  exit 127
fi
actual_checksum=${actual_checksum%% *}

if [ "$actual_checksum" != "$expected_checksum" ]; then
  echo "checksum mismatch for Zig $version ($platform)" >&2
  exit 1
fi

install_root=$(mktemp -d "$RUNNER_TEMP/notify-zig-$version-$platform.XXXXXX")
tar -xJf "$archive" -C "$install_root" --strip-components=1

if [ ! -x "$install_root/zig" ]; then
  echo "Zig archive did not contain an executable" >&2
  exit 1
fi
if [ "$("$install_root/zig" version)" != "$version" ]; then
  echo "installed Zig version does not match $version" >&2
  exit 1
fi

printf '%s\n' "$install_root" >>"$GITHUB_PATH"
install_complete=true
echo "installed Zig $version for $platform"
