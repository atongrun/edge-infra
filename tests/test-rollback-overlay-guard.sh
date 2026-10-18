#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-rollback-overlay-test.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT

printf 'INSTALL_PHASE=complete\n' > "$tmpdir/state.env"
EDGE_INFRA_SOURCE_ONLY=1 source "$repo_root/bin/edge-infra"
STATE_FILE="$tmpdir/state.env"
REALITY_STATE_FILE="$tmpdir/reality-state.env"
REALITY_CLI_PATH=/usr/local/sbin/edge-infra-reality
systemctl() { touch "$tmpdir/systemctl-called"; }
safe_remove_tree() { touch "$tmpdir/tree-removal-called"; }

touch "$REALITY_STATE_FILE"
if (rollback_internal 0) >"$tmpdir/out" 2>"$tmpdir/err"; then
  echo 'base rollback accepted an installed Reality overlay' >&2
  exit 1
fi
grep -Fq 'edge-infra-reality rollback --yes' "$tmpdir/err"
[[ ! -e $tmpdir/systemctl-called && ! -e $tmpdir/tree-removal-called ]]

# --force bypasses only the manifest check; it must not bypass the overlay guard.
FORCE=1
if (rollback_internal 0) >"$tmpdir/force-out" 2>"$tmpdir/force-err"; then
  echo 'forced base rollback accepted an installed Reality overlay' >&2
  exit 1
fi
grep -Fq 'edge-infra-reality rollback --yes' "$tmpdir/force-err"
[[ ! -e $tmpdir/systemctl-called && ! -e $tmpdir/tree-removal-called ]]

# Without an overlay, retain the pre-existing manifest-drift refusal path.
rm -f "$REALITY_STATE_FILE"
printf 'original\n' > "$tmpdir/subscription.yaml"
checksum=$(sha256sum "$tmpdir/subscription.yaml" | awk '{print $1}')
printf '%s  %s\n' "$checksum" "$tmpdir/subscription.yaml" > "$tmpdir/manifest.sha256"
printf 'changed\n' > "$tmpdir/subscription.yaml"
MANIFEST_FILE="$tmpdir/manifest.sha256"
FORCE=0
if (rollback_internal 0) >"$tmpdir/manifest-out" 2>"$tmpdir/manifest-err"; then
  echo 'base rollback accepted manifest drift without an overlay' >&2
  exit 1
fi
grep -Fq 'managed files changed since install' "$tmpdir/manifest-err"
[[ ! -e $tmpdir/systemctl-called && ! -e $tmpdir/tree-removal-called ]]

echo 'test-rollback-overlay-guard: passed'
