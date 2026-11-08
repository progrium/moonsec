#!/usr/bin/env bash
# Writes THIRD_PARTY_NOTICES.md for one moonsec package.
#
#   packaging/notices/gen.sh --package linux|windows|macos --out FILE [--bin FILE]...
#       [--shim-notices FILE] [--extra NAME=LICENSE_FILE]...
#
# Combines, in this order:
#   - the iroh shim's Rust crates: cargo-about output (shim/about.toml), from
#     --shim-notices or generated here when cargo-about is installed;
#   - libopus (the build.zig.zon dependency, from zig-pkg/ or Zig's global cache);
#   - Zig's standard library and compiler-rt, compiled into every binary;
#   - vendored SDK headers under third_party/ (NVENC, AMF, oneVPL, ...): each directory's
#     LICENSE* file, else the licence comment at the top of each header;
#   - --extra entries (ViGEmBus, anything else a package ships);
#   - Linux: the shared libraries each --bin needs (not shipped; listed so the package
#     says what it loads), and a hard stop if one is a GPL build of FFmpeg.
# Fails when a required piece is missing, so a release never ships partial notices.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg="" out="" shim_notices="" bins=() extras=()
while [ $# -gt 0 ]; do
  case "$1" in
    --package) pkg="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --bin) bins+=("$2"); shift 2 ;;
    --shim-notices) shim_notices="$2"; shift 2 ;;
    --extra) extras+=("$2"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$pkg" in linux|windows|macos) ;; *) echo "--package linux|windows|macos" >&2; exit 2 ;; esac
[ -n "$out" ] || { echo "--out FILE" >&2; exit 2; }

# shellcheck source=../version.sh
. "$root/packaging/version.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- iroh shim crates -------------------------------------------------------------
if [ -z "$shim_notices" ]; then
  command -v cargo-about >/dev/null || { echo "need --shim-notices or cargo-about (cargo install cargo-about --locked)" >&2; exit 1; }
  (cd "$root/shim" && cargo about generate --locked --fail -c about.toml -o "$tmp/shim.md" about.hbs)
  shim_notices="$tmp/shim.md"
fi
[ -s "$shim_notices" ] || { echo "empty shim notices: $shim_notices" >&2; exit 1; }

# --- libopus ----------------------------------------------------------------------
opus_hash="$(grep -A3 '\.opus = \.{' "$root/build.zig.zon" | sed -n 's/.*\.hash = "\(.*\)".*/\1/p')"
opus_dir=""
for d in "$root/zig-pkg/$opus_hash" "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p/$opus_hash"; do
  [ -f "$d/COPYING" ] && { opus_dir="$d"; break; }
done
if [ -z "$opus_dir" ] && [ -f "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p/$opus_hash.tar.gz" ]; then
  tar -xzf "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p/$opus_hash.tar.gz" -C "$tmp" "$opus_hash/COPYING"
  opus_dir="$tmp/$opus_hash"
fi
[ -n "$opus_dir" ] || { echo "libopus source ($opus_hash) not fetched; run a zig build first" >&2; exit 1; }

# --- Zig --------------------------------------------------------------------------
zig_lic=""
if command -v zig >/dev/null; then
  zl="$(zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\(.*\)".*/\1/p; s/.*"lib_dir": *"\(.*\)".*/\1/p' | head -1)"
  for f in "$zl/../LICENSE" "$(dirname "$(readlink -f "$(command -v zig)")")/LICENSE"; do
    [ -f "$f" ] && { zig_lic="$f"; break; }
  done
fi

section() { printf '\n---\n\n## %s\n\n' "$1"; }
verbatim() { printf '```text\n'; cat "$1"; printf '\n```\n'; }
# The leading /* ... */ or // block of a C header.
header_licence() {
  awk 'NR==1 && !/^[[:space:]]*(\/\*|\/\/)/ {exit}
       {print} /\*\// {exit} /^[[:space:]]*$/ && seen {exit} {seen=1}' "$1"
}

{
  echo "# Third-party notices: moonsec $MOONSEC_VERSION ($pkg)"
  echo
  echo "moonsec is licensed under: $MOONSEC_LICENSE."
  echo "This package includes or links the components below, each under its own licence."
  echo "Components marked *not shipped* are system libraries the package loads but does not include."

  section "libopus 1.5.2 (BSD-3-Clause), statically linked"
  echo "Source: https://github.com/xiph/opus (tag v1.5.2)"
  echo
  verbatim "$opus_dir/COPYING"

  section "Zig standard library and compiler-rt (MIT), compiled in"
  if [ -n "$zig_lic" ]; then verbatim "$zig_lic"; else
    echo "Copyright (c) Zig contributors. MIT licence: https://github.com/ziglang/zig/blob/master/LICENSE"
  fi

  if [ -d "$root/third_party" ]; then
    for d in "$root"/third_party/*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      section "$name SDK headers (vendored under third_party/$name)"
      lic="$(find "$d" -maxdepth 1 -iname 'LICENSE*' -o -maxdepth 1 -iname 'COPYING*' | head -1)"
      if [ -n "$lic" ]; then verbatim "$lic"; else
        for h in "$d"*.h; do
          [ -f "$h" ] || continue
          echo "From \`$(basename "$h")\`:"; echo
          printf '```text\n'; header_licence "$h"; printf '```\n\n'
        done
      fi
    done
  fi

  for e in ${extras[@]+"${extras[@]}"}; do
    name="${e%%=*}"; file="${e#*=}"
    [ -f "$file" ] || { echo "missing licence for $name: $file" >&2; exit 1; }
    section "$name"
    verbatim "$file"
  done

  if [ "$pkg" = linux ] && [ ${#bins[@]} -gt 0 ]; then
    section "System libraries (not shipped)"
    echo "Loaded from the system at run time; their licences come with the distribution's packages."
    echo
    for b in "${bins[@]}"; do
      objdump -p "$b" | awk '/NEEDED/{print $2}'
    done | sort -u | while read -r lib; do echo "- \`$lib\`"; done
  fi

  section "iroh shim: Rust crates (cargo-about)"
  # Drop the cargo-about page's own top-level heading; the rest is its overview and texts.
  sed '1{/^# /d}' "$shim_notices"
} > "$tmp/out.md"

# FFmpeg: link only an LGPL build, and never ship a GPL one. A distro's libavcodec built
# with --enable-gpl (Debian and Ubuntu do this) makes the binary that links it GPL.
if [ "$pkg" = linux ]; then
  for b in ${bins[@]+"${bins[@]}"}; do
    for lib in $(objdump -p "$b" | awk '/NEEDED/ && /libav(codec|util|format)|libsw(scale|resample)/{print $2}'); do
      path="$(ldconfig -p | awk -v l="$lib" '$1==l{print $NF; exit}')"
      [ -n "$path" ] || { echo "$b needs $lib, which isn't installed here; can't check its licence" >&2; exit 1; }
      if strings -a "$path" | grep -q -- '--enable-gpl'; then
        echo "$b links $lib, and $path is a GPL build of FFmpeg (--enable-gpl)." >&2
        echo "Ship against an LGPL FFmpeg build, or decode without libavcodec. See packaging/README.md." >&2
        [ "${MOONSEC_ALLOW_GPL_FFMPEG:-}" = 1 ] || exit 1
        echo "MOONSEC_ALLOW_GPL_FFMPEG=1: continuing" >&2
      fi
    done
  done
fi

mkdir -p "$(dirname "$out")"
cp "$tmp/out.md" "$out"
echo "wrote $out ($(wc -l < "$out") lines)" >&2
