#!/usr/bin/env bash
# Re-vendor civetweb at a pinned upstream commit and apply this package's
# patches on top. Run from the package root:
#
#     tools/vendor-civetweb.sh            # the commit pinned below
#     tools/vendor-civetweb.sh <sha>      # a different commit
#
# What it fetches:
#   src/civetweb.c, src/civetweb.h       the library
#   src/civetweb/*.inl                   the pieces civetweb.c #includes
#
# What it leaves alone:
#   src/server.c, src/init.c             this package's bridge
#   src/civetweb/external_*.inl          this package's hooks into civetweb
#   tools/patches/*.patch                applied after the fetch, in order
#
# The pinned commit is recorded in src/civetweb/COMMIT. Upstream has not
# tagged a release since 1.16 (2023), so master is what gets vendored.

set -euo pipefail

# civetweb master, 2026-04-19. The next upstream commit (588860e, "don't
# allow chunked encoding and content length") does not compile: it uses a
# variable it removed. Its intent is carried here as
# tools/patches/0002-reject-chunked-with-content-length.patch; move the
# pin past it once upstream has fixed it.
PINNED="3309a6cac05335aa4371a0c3750b42fbe05d3cb4"
COMMIT="${1:-$PINNED}"
BASE="https://raw.githubusercontent.com/civetweb/civetweb/${COMMIT}"

cd "$(dirname "$0")/.."

# Upstream keeps some files with CRLF endings (match.inl), which R CMD
# check flags in src/, so every fetched file is normalized to LF.
fetch() {
  local url="$1" dest="$2"
  curl -fsSL "$url" -o "$dest.tmp"
  tr -d '\r' < "$dest.tmp" > "$dest"
  rm -f "$dest.tmp"
}

mkdir -p src/civetweb

fetch "${BASE}/src/civetweb.c"       src/civetweb.c
fetch "${BASE}/include/civetweb.h"   src/civetweb.h
for f in handle_form match md5 response sha1 sort mod_mbedtls; do
  fetch "${BASE}/src/${f}.inl" "src/civetweb/${f}.inl"
done

printf '%s\n' "$COMMIT" > src/civetweb/COMMIT

for p in tools/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "applying $p"
  patch -p1 --no-backup-if-mismatch < "$p"
done

echo "civetweb vendored at ${COMMIT}"
