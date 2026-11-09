#!/bin/sh
# Builds shim-web for the browser: the wasm crate (release), its JS bindings (wasm-bindgen,
# --target web) and the pairing module (core/pair via `zig build web-pair`), all into pkg/.
#   shim-web/build.sh            needs rustup (toolchain from rust-toolchain.toml + wasm32),
#                                wasm-bindgen-cli matching Cargo.lock's wasm-bindgen, and zig
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
want=$(awk '/^name = "wasm-bindgen"$/{getline; gsub(/[^0-9.]/,""); print}' Cargo.lock)
have=$(wasm-bindgen --version 2>/dev/null | awk '{print $2}')
if [ "$want" != "$have" ]; then
  echo "need wasm-bindgen-cli $want (have ${have:-none}): cargo install wasm-bindgen-cli@$want --locked" >&2
  exit 1
fi
cargo build --release --locked --target wasm32-unknown-unknown
wasm-bindgen --target web --out-dir pkg target/wasm32-unknown-unknown/release/iroh_web.wasm
(cd .. && zig build web-pair)
cp ../zig-out/web/moonsec-pair.wasm pkg/
ls -l pkg/*.wasm
printf 'gzip: '; gzip -9c pkg/iroh_web_bg.wasm | wc -c
