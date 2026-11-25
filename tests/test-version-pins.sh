#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$root/versions.env"
# shellcheck disable=SC1091
source "$root/env/resilience-versions.env.example"

[[ $SING_BOX_VERSION == 1.14.4 ]]
[[ $UPGRADE_SING_BOX_VERSION == "$SING_BOX_VERSION" ]]
[[ $SING_BOX_AMD64_SHA256 == 699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ]]
[[ $UPGRADE_SING_BOX_AMD64_SHA256 == "$SING_BOX_AMD64_SHA256" ]]
[[ $SING_BOX_ARM64_SHA256 == 436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ]]
[[ $UPGRADE_SING_BOX_ARM64_SHA256 == "$SING_BOX_ARM64_SHA256" ]]
[[ $XRAY_VERSION == 26.11.9 ]]
[[ $XRAY_AMD64_SHA256 == b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82 ]]
[[ $XRAY_ARM64_SHA256 == 64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be ]]
[[ $MIHOMO_VERSION == 1.19.33 ]]

# shellcheck disable=SC2016
grep -q 'source "$PROJECT_ROOT/versions.env"' "$root/bin/edge-infra"
# shellcheck disable=SC2016
grep -q 'sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}.tar.gz' "$root/bin/edge-infra"
# shellcheck disable=SC2016
grep -q 'sing-box-$UPGRADE_SING_BOX_VERSION-linux-$ARCH.tar.gz' "$root/scripts/upgrade-sing-box.sh"
grep -q 'Xray-linux-64.zip' "$root/scripts/cloudflare-overlay.sh"
grep -q 'Xray-linux-arm64-v8a.zip' "$root/scripts/cloudflare-overlay.sh"
if grep -q 'glibc\|musl' "$root/scripts/upgrade-sing-box.sh" "$root/bin/edge-infra"; then
  echo 'installer must pin the default linux tarball, not a glibc or musl asset' >&2
  exit 1
fi
if grep -RInE '1\.15\.0-alpha|SING_BOX_VERSION=1\.13|XRAY_VERSION=26\.10' \
  "$root/versions.env" "$root/env/resilience-versions.env.example"; then
  echo 'stale or prerelease core pin remains' >&2
  exit 1
fi
echo 'test-version-pins: passed'
