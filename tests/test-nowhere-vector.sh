#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
launcher="$repo_root/scripts/nowhere-vector.sh"
tmpdir=$(mktemp -d /tmp/edge-infra-nowhere-vector-test.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT

[[ -x $launcher ]] || { echo 'nowhere vector launcher is not executable' >&2; exit 1; }

mock="$tmpdir/nowhere"
cat >"$mock" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == --version ]]; then
  printf '%s\n' 'Nowhere v3.0.1'
  exit 0
fi
case ${1:-} in
  vector://11111111111111111111111111111111@203.0.113.7/tcp:10443?in=127.0.0.1:1089\&sni=portal.example.com\&morph=1|vector://11111111111111111111111111111111@203.0.113.7/udp:10443?in=127.0.0.1:1089\&sni=portal.example.com\&morph=1)
    printf '%s\n' 'mock vector received expected argument shape'
    ;;
  *)
    echo 'mock vector received unexpected argument shape' >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$mock"

write_base_config() {
  local path=$1 binary=${2:-$mock} key=${3:-11111111111111111111111111111111}
  printf '%s\n' \
    "NOWHERE_BINARY=$binary" \
    'PORTAL_IPV4=203.0.113.7' \
    'PORTAL_SNI=portal.example.com' \
    'PORTAL_PORT=10443' \
    "SHARED_KEY=$key" >"$path"
  chmod 0600 "$path"
}

good="$tmpdir/good.env"
write_base_config "$good"

tcp_output=$("$launcher" --config "$good" tcp 2>&1)
[[ $tcp_output == *'127.0.0.1:1089 (tcp)'* ]]
[[ $tcp_output == *'mock vector received expected argument shape'* ]]
[[ $tcp_output != *'11111111111111111111111111111111'* ]]

quic_output=$("$launcher" --config "$good" quic 2>&1)
[[ $quic_output == *'127.0.0.1:1089 (quic)'* ]]
[[ $quic_output == *'mock vector received expected argument shape'* ]]

bad_mode="$tmpdir/bad-mode.env"
write_base_config "$bad_mode"
chmod 0644 "$bad_mode"
if "$launcher" --config "$bad_mode" >"$tmpdir/bad-mode.out" 2>&1; then
  echo 'world-readable config unexpectedly ran' >&2
  exit 1
fi
grep -Fxq 'config permissions must be 0600' "$tmpdir/bad-mode.out"

bad_field="$tmpdir/bad-field.env"
write_base_config "$bad_field"
marker="$tmpdir/source-ran"
printf 'UNSAFE_SHELL=$%s\n' "(touch $marker)" >>"$bad_field"
if "$launcher" --config "$bad_field" >"$tmpdir/bad-field.out" 2>&1; then
  echo 'unknown shell-like field unexpectedly ran' >&2
  exit 1
fi
grep -Fxq 'invalid config field on line 6' "$tmpdir/bad-field.out"
[[ ! -e $marker ]] || { echo 'config text was executed' >&2; exit 1; }

uppercase_key="$tmpdir/uppercase-key.env"
write_base_config "$uppercase_key" "$mock" 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
if "$launcher" --config "$uppercase_key" >"$tmpdir/uppercase-key.out" 2>&1; then
  echo 'uppercase shared key unexpectedly ran' >&2
  exit 1
fi
grep -Fxq 'SHARED_KEY must be exactly 32 lowercase hexadecimal characters' "$tmpdir/uppercase-key.out"

alpha_mock="$tmpdir/nowhere-alpha"
cat >"$alpha_mock" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
  printf '%s\n' 'Nowhere v3.0.1-alpha'
  exit 0
fi
exit 1
EOF
chmod 0755 "$alpha_mock"
alpha_config="$tmpdir/alpha-version.env"
write_base_config "$alpha_config" "$alpha_mock"
if "$launcher" --config "$alpha_config" >"$tmpdir/alpha-version.out" 2>&1; then
  echo 'pre-release version unexpectedly ran' >&2
  exit 1
fi
grep -Fxq 'NOWHERE_BINARY is not Nowhere v3.0.1' "$tmpdir/alpha-version.out"

echo 'test-nowhere-vector: passed'
