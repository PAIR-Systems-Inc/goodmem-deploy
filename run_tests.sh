#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "bats is required to run goodmem-deploy tests." >&2
  echo "Install it with your package manager or from https://github.com/bats-core/bats-core." >&2
  exit 1
fi

cd "$ROOT_DIR"
exec bats tests "$@"
