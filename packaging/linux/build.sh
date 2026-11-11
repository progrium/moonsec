#!/usr/bin/env bash
# Builds the Linux packages from an installed moonsec build:
#
#   packaging/linux/build.sh --bin zig-out/bin/moonsec [--arch x86_64|aarch64]
#       [--notices FILE] [--out dist] [--formats "tar deb rpm"]
#
# Writes to --out (default dist/):
#   moonsec-<version>-linux-<arch>.tar.gz   the same tree under /usr, for any distro
#   moonsec_<version>_<debarch>.deb         dpkg-deb (Depends from the binary's libraries)
#   moonsec-<version>.<arch>.rpm            rpmbuild (Requires found by rpm from the ELF)
#
# Contents: /usr/bin/moonsec, the host launcher /usr/lib/moonsec/moonsec-host, the systemd
# user unit moonsec-host.service, the /dev/uinput udev rule and modules-load entry, and the
# notices. Unsigned: distro repositories sign their metadata, not the package files; the
# release workflow publishes SHA256SUMS next to them.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$root/packaging/version.sh"

bin="" arch="$(uname -m)" notices="" out="$root/dist" formats="tar deb rpm"
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) bin="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    --notices) notices="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --formats) formats="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -x "$bin" ] || { echo "--bin PATH to the moonsec binary" >&2; exit 2; }
bin="$(readlink -f "$bin")"
case "$arch" in x86_64) debarch=amd64 ;; aarch64) debarch=arm64 ;; *) echo "arch: x86_64 or aarch64" >&2; exit 2 ;; esac
mkdir -p "$out"; out="$(cd "$out" && pwd)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stage="$work/root"

# --- the tree -----------------------------------------------------------------------
install -Dm755 "$bin" "$stage/usr/bin/moonsec"
install -Dm755 "$here/moonsec-host" "$stage/usr/lib/moonsec/moonsec-host"
install -Dm644 "$here/moonsec-host.service" "$stage/usr/lib/systemd/user/moonsec-host.service"
install -Dm644 "$here/60-moonsec-uinput.rules" "$stage/usr/lib/udev/rules.d/60-moonsec-uinput.rules"
install -Dm644 "$here/moonsec-uinput.conf" "$stage/usr/lib/modules-load.d/moonsec-uinput.conf"
if [ -z "$notices" ]; then
  notices="$work/THIRD_PARTY_NOTICES.md"
  "$root/packaging/notices/gen.sh" --package linux --bin "$bin" --out "$notices"
fi
install -Dm644 "$notices" "$stage/usr/share/doc/moonsec/THIRD_PARTY_NOTICES.md"
install -Dm644 "$root/README.md" "$stage/usr/share/doc/moonsec/README.md"
# Strip only a copy; the workflow keeps the unstripped binary as a debug artifact.
strip --strip-unneeded "$stage/usr/bin/moonsec" 2>/dev/null || true

summary="Low-latency desktop streaming host and client"
description="moonsec streams a desktop over iroh (QUIC, peer to peer) at low latency.
This package has the moonsec tool, the per-user host service (systemctl --user
enable --now moonsec-host) and the udev rule that lets the host's virtual input
devices use /dev/uinput."

# --- tarball --------------------------------------------------------------------------
if [[ " $formats " == *" tar "* ]]; then
  name="moonsec-$MOONSEC_VERSION-linux-$arch"
  cp -a "$stage" "$work/$name"
  tar --owner=0 --group=0 --sort=name -C "$work" -czf "$out/$name.tar.gz" "$name"
  echo "built $out/$name.tar.gz"
fi

# --- deb ------------------------------------------------------------------------------
if [[ " $formats " == *" deb "* ]]; then
  deb="$work/deb"
  cp -a "$stage" "$deb"
  mkdir -p "$deb/DEBIAN"
  # Depends: dpkg-shlibdeps reads the binary's library and symbol versions (libc6 (>= 2.34)
  # rather than whatever this machine has). Without dpkg-dev, the owning packages at any version.
  depends=""
  if command -v dpkg-shlibdeps >/dev/null; then
    mkdir -p "$work/shlibs/debian"
    printf 'Source: moonsec\n\nPackage: moonsec\nArchitecture: any\n' > "$work/shlibs/debian/control"
    depends="$(cd "$work/shlibs" && dpkg-shlibdeps -O -e"$(readlink -f "$bin")" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
  elif command -v dpkg-query >/dev/null; then
    for lib in $(objdump -p "$bin" | awk '/NEEDED/{print $2}'); do
      path="$(ldconfig -p | awk -v l="$lib" '$1==l{print $NF; exit}')"
      [ -n "$path" ] || continue
      p="$(dpkg-query -S "$(readlink -f "$path")" 2>/dev/null || dpkg-query -S "$path" 2>/dev/null || true)"
      [ -n "${p%%:*}" ] && depends="$depends, ${p%%:*}"
    done
  fi
  depends="$(echo "${depends#, }" | tr ',' '\n' | sed 's/^ //' | sort -u | paste -sd, - | sed 's/,/, /g')"
  {
    echo "Package: moonsec"
    echo "Version: $MOONSEC_VERSION"
    echo "Architecture: $debarch"
    echo "Maintainer: moonsec <noreply@github.com>"
    echo "Installed-Size: $(du -sk "$stage" | cut -f1)"
    [ -n "$depends" ] && echo "Depends: $depends"
    echo "Recommends: pipewire, xdg-desktop-portal, systemd"
    echo "Section: net"
    echo "Priority: optional"
    echo "Homepage: https://github.com/progrium/moonsec"
    echo "Description: $summary"
    echo "$description" | sed 's/^/ /'
  } > "$deb/DEBIAN/control"
  install -m755 "$here/postinst" "$deb/DEBIAN/postinst"
  install -m755 "$here/postrm" "$deb/DEBIAN/postrm"
  mkdir -p "$deb/usr/share/doc/moonsec"
  {
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: moonsec"
    echo "Source: https://github.com/progrium/moonsec"
    echo
    echo "Files: *"
    echo "License: $MOONSEC_LICENSE"
    echo "Comment: third-party components are listed in THIRD_PARTY_NOTICES.md"
  } > "$deb/usr/share/doc/moonsec/copyright"
  f="$out/moonsec_${MOONSEC_VERSION}_${debarch}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$deb" "$f" >/dev/null
  echo "built $f"
fi

# --- rpm ------------------------------------------------------------------------------
if [[ " $formats " == *" rpm "* ]]; then
  command -v rpmbuild >/dev/null || { echo "rpmbuild not installed (apt-get install rpm)" >&2; exit 1; }
  top="$work/rpm"
  mkdir -p "$top"/{BUILD,RPMS,SPECS,SOURCES,BUILDROOT}
  sed -e "s|@VERSION@|$MOONSEC_VERSION_RPM|" -e "s|@LICENSE@|$MOONSEC_LICENSE|" \
      -e "s|@SUMMARY@|$summary|" "$here/moonsec.spec.in" > "$top/SPECS/moonsec.spec"
  printf '%s\n' "$description" > "$top/SOURCES/description"
  rpmbuild --quiet -bb --target "$arch" \
    --define "_topdir $top" --define "stage $stage" --define "_build_id_links none" \
    "$top/SPECS/moonsec.spec"
  f="$(find "$top/RPMS" -name '*.rpm' | head -1)"
  cp "$f" "$out/"
  echo "built $out/$(basename "$f")"
fi
