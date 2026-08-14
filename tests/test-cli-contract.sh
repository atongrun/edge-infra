#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-cli-test.XXXXXX)
cleanup() {
  [[ -n ${tmpdir:-} && -d $tmpdir && ! -L $tmpdir ]] || return 0
  case "$tmpdir" in /tmp/*|/var/tmp/*) rm -rf -- "$tmpdir" ;; esac
}
trap cleanup EXIT

"$repo_root/bin/edge-infra" help | grep -q 'edge-infra preflight'

if "$repo_root/bin/edge-infra" preflight >/dev/null 2>"$tmpdir/error"; then
  echo 'preflight without config unexpectedly succeeded' >&2
  exit 1
fi
grep -q -- '--config is required' "$tmpdir/error"

if "$repo_root/bin/edge-infra" uninstall >/dev/null 2>"$tmpdir/error"; then
  echo 'uninstall without --yes unexpectedly succeeded' >&2
  exit 1
fi
grep -q -- 'rerun with --yes' "$tmpdir/error"

echo 'test-cli-contract: passed'
