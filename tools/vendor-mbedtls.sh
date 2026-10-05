#!/usr/bin/env bash
# Vendor Mbed TLS (library sources and public headers) under src/mbedtls/.
# Run from the package root:
#
#     tools/vendor-mbedtls.sh            # the version pinned below
#     tools/vendor-mbedtls.sh 3.6.8      # a different release
#
# Downloads the release tarball and its published sha256 from the GitHub
# release, verifies the checksum, and copies
#
#   library/*.c library/*.h   -> src/mbedtls/library/
#   include/                  -> src/mbedtls/include/
#   LICENSE                   -> src/mbedtls/LICENSE
#
# The version is recorded in src/mbedtls/VERSION. Nothing else from the
# release (tests, programs, framework, 3rdparty) is needed: the default
# configuration enables no 3rdparty code, and civetwebR's adjustments
# to that configuration are in src/civetweb/civetwebr_mbedtls_config.h,
# which this script leaves alone.
#
# 3.6 is the long-term-support series; 4.x splits the crypto into a
# separate project and would need a different layout.

set -euo pipefail

PINNED="3.6.7"
VERSION="${1:-$PINNED}"
TAG="mbedtls-${VERSION}"
BASE="https://github.com/Mbed-TLS/mbedtls/releases/download/${TAG}"

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${BASE}/${TAG}.tar.bz2" -o "$tmp/src.tar.bz2"
curl -fsSL "${BASE}/${TAG}-sha256sum.txt" -o "$tmp/sum.txt"

want="$(grep "${TAG}.tar.bz2" "$tmp/sum.txt" | awk '{print $1}')"
have="$(sha256sum "$tmp/src.tar.bz2" | awk '{print $1}')"
if [ -z "$want" ] || [ "$want" != "$have" ]; then
  echo "sha256 mismatch for ${TAG}.tar.bz2: want ${want:-?} have ${have}" >&2
  exit 1
fi

tar xjf "$tmp/src.tar.bz2" -C "$tmp"
src="$tmp/$TAG"

rm -rf src/mbedtls
mkdir -p src/mbedtls/library
cp "$src"/library/*.c "$src"/library/*.h src/mbedtls/library/
cp -R "$src"/include src/mbedtls/include
cp "$src"/LICENSE src/mbedtls/LICENSE
printf '%s\n' "$VERSION" > src/mbedtls/VERSION

echo "mbedtls vendored at ${VERSION} (sha256 ${have})"
