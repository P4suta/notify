#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

for required_command in bash git node; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "required command not found: $required_command" >&2
    exit 127
  fi
done

mapfile -d '' -t tracked_files \
  < <(git ls-files --cached --others --exclude-standard -z)

for tracked_file in "${tracked_files[@]}"; do
  case "$tracked_file" in
    src/* | test/* | packages/* | packaging/* | web/*)
      case "$tracked_file" in
        *.sh | *.bash) bash -n "$tracked_file" ;;
      esac
      ;;
  esac

  case "$tracked_file" in
    src/* | web/src/* | test/*)
      case "$tracked_file" in
        *.mjs | *.js) node --check "$tracked_file" ;;
      esac
      ;;
  esac
done
