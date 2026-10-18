#!/usr/bin/env bash
set -Eeuo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bin/edge-infra
EDGE_INFRA_SOURCE_ONLY=1 source "$repo_root/bin/edge-infra"
tmpdir=$(mktemp -d /tmp/edge-infra-health-test.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT
verify_optional_reality "$tmpdir/absent-state" "$tmpdir/missing-cli"
touch "$tmpdir/state"
if (verify_optional_reality "$tmpdir/state" "$tmpdir/missing-cli") >/dev/null 2>&1; then
  echo 'missing overlay verifier accepted' >&2; exit 1
fi
cat > "$tmpdir/cli" <<'EOF'
#!/usr/bin/env bash
[[ $1 == verify ]] || exit 2
exit 19
EOF
chmod +x "$tmpdir/cli"
if (verify_optional_reality "$tmpdir/state" "$tmpdir/cli") >/dev/null 2>&1; then
  echo 'failed overlay verification accepted' >&2; exit 1
fi
sed -i.bak 's/exit 19/exit 0/' "$tmpdir/cli"
verify_optional_reality "$tmpdir/state" "$tmpdir/cli"
echo 'test-health-overlay: passed'
