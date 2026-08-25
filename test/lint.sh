#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)

cd "$root"
gleam run -m glinter
gleam run -m glinter -- --project packages/notify_core
gleam run -m glinter -- --project web
