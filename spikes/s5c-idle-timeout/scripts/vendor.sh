#!/usr/bin/env bash
# Copies iroh 1.4.1 from the cargo registry into vendor/ and applies iroh-repunch.patch.
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
cd "$D"
cargo fetch -q
SRC=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/iroh-1.4.1 | head -1)
rm -rf vendor/iroh-1.4.1 && mkdir -p vendor && cp -r "$SRC" vendor/
patch -d vendor/iroh-1.4.1 -p1 < iroh-repunch.patch
