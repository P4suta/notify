#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

if (($# != 2)) || [[ ! $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]]; then
  echo "usage: test/generate_sbom.sh LOCAL_IMAGE_REFERENCE OUTPUT_DIRECTORY" >&2
  exit 2
fi
for required_command in docker python3; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

readonly image_reference=$1
output_directory=$2
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)

readonly syft_image="anchore/syft:v1.51.0@sha256:678bfa565b60f747aac0f8e964fe5588a24445b8d0a480e91f6efd70020dfbb0"
readonly cyclonedx_image="cyclonedx/cyclonedx-cli:0.32.0@sha256:9a858a15e7b0843606efc0ff19d5f7575011a5428d7f3d343b4f6cf09d8f0d4e"

sbom_tmp=$(mktemp -d "${TMPDIR:-/tmp}/notify-sbom.XXXXXX")
cleanup() {
  find "$sbom_tmp" -depth -delete
}
trap cleanup EXIT HUP INT TERM

python3 test/supply_chain_inventory.py \
  --root . \
  --cyclonedx-output "$output_directory/notify-source.cdx.json"

docker image inspect "$image_reference" >/dev/null
docker image save --output "$sbom_tmp/image.tar" "$image_reference"
docker run \
  --rm \
  --network none \
  --user "$(id -u):$(id -g)" \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs "/tmp:rw,noexec,nosuid,size=256m,mode=1777" \
  --env SYFT_CHECK_FOR_APP_UPDATE=false \
  --env XDG_CACHE_HOME=/tmp/cache \
  --volume "$sbom_tmp:/scan:ro" \
  --volume "$output_directory:/sbom:rw" \
  "$syft_image" \
  scan docker-archive:/scan/image.tar \
  --output cyclonedx-json=/sbom/notify-image.cdx.json

for sbom_name in notify-source.cdx.json notify-image.cdx.json; do
  docker run \
    --rm \
    --network none \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs "/tmp:rw,noexec,nosuid,size=32m" \
    --volume "$output_directory:/sbom:ro" \
    "$cyclonedx_image" \
    validate \
    --input-file "/sbom/$sbom_name" \
    --input-format json \
    --fail-on-errors
done

python3 test/check_licenses.py --root .
