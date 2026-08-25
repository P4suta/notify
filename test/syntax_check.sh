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

if command -v pwsh >/dev/null 2>&1 && \
  pwsh -NoLogo -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1; then
  mapfile -d '' -t powershell_files \
    < <(git ls-files --cached --others --exclude-standard -z -- '*.ps1')
  for powershell_file in "${powershell_files[@]}"; do
    # PowerShell expands these expressions; Bash must pass them literally.
    # shellcheck disable=SC2016
    pwsh -NoLogo -NoProfile -NonInteractive -Command \
      '$tokens = $null; $errors = $null; [Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }' \
      "$powershell_file"
  done
fi

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
