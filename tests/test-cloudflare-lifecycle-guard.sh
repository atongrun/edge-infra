#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-cf-guard.XXXXXX)
# shellcheck source=../scripts/reality-overlay.sh
source "$repo_root/scripts/reality-overlay.sh"
trap 'rm -rf -- "$tmpdir"' EXIT
CF_STATE_FILE=$tmpdir/state.env
ASSUME_YES=1
FORCE=1
require_root() { :; }
acquire_lock() { :; }
load_state() { touch "$tmpdir/mutating-path"; }
touch "$CF_STATE_FILE"
for operation in simplify_groups rollback_overlay; do
  if ("$operation") >"$tmpdir/out" 2>"$tmpdir/err"; then
    echo "$operation accepted an installed Cloudflare overlay" >&2
    exit 1
  fi
  grep -Fq 'Cloudflare overlay is installed' "$tmpdir/err"
  [[ ! -e $tmpdir/mutating-path ]]
done
echo 'test-cloudflare-lifecycle-guard: passed'
