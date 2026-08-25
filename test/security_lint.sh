#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

for required_command in docker git yamllint; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

readonly actionlint_image="rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667"
readonly hadolint_image="ghcr.io/hadolint/hadolint:v2.15.1-alpine@sha256:a1d49ae1a4e83c1dbad26b8c1ad7588c8bd1e04f4866b34ad3cac50335198552"
readonly shellcheck_image="koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d"
readonly zizmor_image="ghcr.io/zizmorcore/zizmor:1.29.0@sha256:863026d54f91271b10b60b67ad8054cb37120167e162482597db102b3026a284"
readonly gitleaks_image="ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"

readonly -a container_options=(
  --rm
  --network none
  --cap-drop ALL
  --security-opt no-new-privileges
  --read-only
  --tmpfs "/tmp:rw,noexec,nosuid,size=16m"
  --volume "$root:/repo:ro"
  --workdir /repo
)

docker run "${container_options[@]}" "$actionlint_image"
docker run "${container_options[@]}" "$hadolint_image" /bin/hadolint \
  Dockerfile packaging/native/linux-nif-builder.Dockerfile

mapfile -d '' -t shell_files \
  < <(git ls-files --cached --others --exclude-standard -z -- '*.sh' '*.bash')
if ((${#shell_files[@]} > 0)); then
  docker run "${container_options[@]}" "$shellcheck_image" -- "${shell_files[@]}"
fi

docker run "${container_options[@]}" "$zizmor_image" --offline .
docker run "${container_options[@]}" "$gitleaks_image" \
  dir --no-banner --redact .

mapfile -d '' -t yaml_files \
  < <(git ls-files --cached --others --exclude-standard -z -- '*.yml' '*.yaml')
if ((${#yaml_files[@]} > 0)); then
  yamllint -- "${yaml_files[@]}"
fi
