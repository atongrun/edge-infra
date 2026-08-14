#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in "$repo_root"/tests/test-*.sh; do
  printf '==> %s\n' "${test_file##*/}"
  "$test_file"
done
