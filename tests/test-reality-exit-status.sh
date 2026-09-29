#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-exit-test.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT

check_exit() {
  local mode=$1 expected=$2 status file
  file=$tmpdir/$mode-$expected
  : > "$file"
  if bash -s -- "$repo_root/scripts/reality-overlay.sh" "$mode" "$expected" "$file" <<'CHILD'
source "$1"
mode=$2 expected=$3 file=$4
case "$mode" in
  empty) WORK_FILES=() ;;
  files) WORK_FILES=("$file") ;;
  trailing-empty) WORK_FILES=("$file" "") ;;
esac
# Exercise the real main/EXIT-trap path without accessing a live VPS.
verify_overlay() { return "$expected"; }
main verify
CHILD
  then
    status=0
  else
    status=$?
  fi
  if [[ $status != "$expected" ]]; then
    echo "$mode: expected exit $expected, got $status" >&2
    exit 1
  fi
  if [[ $mode != empty && -e $file ]]; then
    echo "$mode: temporary file was not cleaned" >&2
    exit 1
  fi
}

for mode in empty files trailing-empty; do
  check_exit "$mode" 0
  check_exit "$mode" 42
done

echo 'test-reality-exit-status: passed'
