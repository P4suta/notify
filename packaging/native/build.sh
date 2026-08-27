#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"

if [ "$#" -gt 1 ]; then
  echo "usage: packaging/native/build.sh [target]" >&2
  exit 2
fi

os=$(uname -s)
arch=$(uname -m)
case "$os:$arch" in
  Linux:x86_64) host_target=linux_amd64 ;;
  Linux:aarch64|Linux:arm64) host_target=linux_arm64 ;;
  Darwin:x86_64) host_target=macos_amd64 ;;
  Darwin:arm64) host_target=macos_arm64 ;;
  *) echo "unsupported native build host: $os $arch" >&2; exit 1 ;;
esac

if [ "$#" -eq 1 ]; then
  target=$1
else
  target=$host_target
fi

case "$target" in
  linux_amd64|linux_arm64|macos_amd64|macos_arm64|windows_amd64) ;;
  *) echo "unsupported native target: $target" >&2; exit 2 ;;
esac
if [ "$target" != windows_amd64 ] && [ "$target" != "$host_target" ]; then
  echo "native target $target requires its matching build host; detected $host_target" >&2
  exit 1
fi

for required_command in elixir erl gleam mix xz zig; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required native build command not found: $required_command" >&2
    exit 127
  fi
done
if [ "$target" = windows_amd64 ]; then
  for required_command in 7z file; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "required Windows target build command not found: $required_command" >&2
      exit 127
    fi
  done
fi
case "$target" in
  linux_*)
    if ! command -v docker >/dev/null 2>&1; then
      echo "required Linux NIF build command not found: docker" >&2
      exit 127
    fi
    ;;
esac
if [ "$(zig version)" != 0.15.2 ]; then
  echo "native builds require Zig 0.15.2" >&2
  exit 1
fi

build_directory=$(mktemp -d "${TMPDIR:-/tmp}/notify-native-build.XXXXXX")
stage="$build_directory/source"
promotion=''
nif_builder_image=''

cleanup() {
  if [ -n "$promotion" ] && [ -f "$promotion" ]; then
    find "$promotion" -type f -delete
  fi
  if [ -d "$build_directory" ]; then
    find "$build_directory" -depth -delete
  fi
  if [ -n "$nif_builder_image" ]; then
    docker image rm "$nif_builder_image" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

mkdir -p "$stage/packages/notify_core"
: >"$stage/.notify-native-runtime-stage"
for file in gleam.toml mix.exs mix.lock; do
  cp "$file" "$stage/$file"
done
for directory in config lib priv src; do
  if [ -d "$directory" ]; then
    cp -R "$directory" "$stage/$directory"
  fi
done
for file in gleam.toml mix.exs; do
  cp "packages/notify_core/$file" "$stage/packages/notify_core/$file"
done
cp -R packages/notify_core/src "$stage/packages/notify_core/src"

export BURRITO_TARGET="$target"
export MIX_ENV=prod
cd "$stage"
mix archive.check
mix deps.get --only prod --check-locked
"$root/packaging/native/stage_runtime_gleam_dependencies.sh" "$stage"
elixir "$root/packaging/native/patch_burrito_launcher.exs" \
  deps/burrito/src/erlang_launcher.zig
mix deps.compile
case "$target" in
  linux_*|windows_amd64)
    nif_erts_include=$(erl -noshell \
      -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
    if [ ! -f "$nif_erts_include/erl_nif.h" ]; then
      echo "Erlang NIF headers are missing: $nif_erts_include" >&2
      exit 1
    fi
    cp -R "$nif_erts_include" "$stage/.native-erts-include"
    ;;
esac
case "$target" in
  linux_*)
    nif_builder_image="notify-native-nif-builder:${target}-$$"
    docker build \
      --file "$root/packaging/native/linux-nif-builder.Dockerfile" \
      --tag "$nif_builder_image" \
      "$root"
    docker run \
      --rm \
      --network none \
      --cap-drop ALL \
      --security-opt no-new-privileges \
      --read-only \
      --tmpfs /tmp:rw,noexec,nosuid,size=512m \
      --user "$(id -u):$(id -g)" \
      --volume "$stage:/source" \
      "$nif_builder_image" \
      /source
    ;;
  windows_amd64)
    "$root/packaging/native/compile_windows_nifs.sh" "$stage"
    ;;
esac
hpack_application="_build/prod/lib/hpack_erl/ebin/hpack.app"
mist_application="_build/prod/lib/mist/ebin/mist.app"
if [ ! -f "$hpack_application" ]; then
  echo "hpack_erl did not publish the expected hpack OTP application" >&2
  exit 1
fi
if [ ! -f "$mist_application" ]; then
  echo "mist did not publish the expected OTP application metadata" >&2
  exit 1
fi
elixir "$root/packaging/native/normalize_hpack_app.exs" "$mist_application"
otp_library="$build_directory/otp_lib"
mkdir -p "$otp_library"
cp -R "_build/prod/lib/hpack_erl" "$otp_library/hpack-0.3.0"
if [ -n "${ERL_LIBS:-}" ]; then
  ERL_LIBS="$otp_library:$ERL_LIBS"
else
  ERL_LIBS="$otp_library"
fi
export ERL_LIBS
mix compile --no-deps-check
mix release --overwrite --no-compile

case "$target" in
  windows_amd64) artifact="burrito_out/notify_${target}.exe" ;;
  *) artifact="burrito_out/notify_${target}" ;;
esac
if [ ! -f "$artifact" ]; then
  echo "Burrito did not create expected artifact: $artifact" >&2
  exit 1
fi

destination="$root/$artifact"
mkdir -p "$(dirname "$destination")"
promotion="$destination.tmp.$$"
cp "$artifact" "$promotion"
if [ "$target" != windows_amd64 ]; then
  chmod +x "$promotion"
fi
mv -f "$promotion" "$destination"
promotion=''
cd "$root"
echo "$artifact"
