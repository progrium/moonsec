#!/usr/bin/env bash
# Builds the macOS packages (on macOS; the release workflow runs it on macos-15):
#
#   packaging/macos/build.sh --bin-arm64 F --bin-x86_64 F --notices FILE [--out dist]
#
#   moonsec Host.app   the host (menu-bar-less agent, LSUIElement), started at login by
#                      /Library/LaunchAgents/com.github.progrium.moonsec.host.plist
#   moonsec.app        the client
#   moonsec-<version>-macos-universal.pkg   both apps into /Applications, plus the agent
#   moonsec-<version>-macos-universal.dmg   both apps, for drag-install (no agent)
#
# Both bundles hold the universal `moonsec` binary for now: on main it is host and client
# at once. PRs #27 and #29 (macOS host and client) replace each bundle's executable.
#
# Signing, when the secrets are present (otherwise ad-hoc signed and not notarized):
#   MACOS_CERT_P12, MACOS_CERT_PASSWORD   base64 .p12 with the Developer ID Application
#                                         and Developer ID Installer certificates
#   MACOS_NOTARY_KEY, MACOS_NOTARY_KEY_ID, MACOS_NOTARY_ISSUER
#                                         App Store Connect API key (base64 .p8) for notarytool
# --require-signing fails instead of falling back.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
. "$root/packaging/version.sh"

arm="" x86="" notices="" out="$root/dist" require=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin-arm64) arm="$2"; shift 2 ;;
    --bin-x86_64) x86="$2"; shift 2 ;;
    --notices) notices="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --require-signing) require=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$arm" ] && [ -f "$x86" ] && [ -f "$notices" ] || { echo "need --bin-arm64, --bin-x86_64 and --notices" >&2; exit 2; }
mkdir -p "$out"; out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
keychain=""
cleanup() {
  [ -n "$keychain" ] && security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# --- signing identities -------------------------------------------------------------
app_id="-" installer_id=""
if [ -n "${MACOS_CERT_P12:-}" ]; then
  keychain="$work/signing.keychain-db"
  kc_pass="$(uuidgen)"
  security create-keychain -p "$kc_pass" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$kc_pass" "$keychain"
  echo "$MACOS_CERT_P12" | base64 --decode > "$work/cert.p12"
  security import "$work/cert.p12" -k "$keychain" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/productsign -T /usr/bin/pkgbuild -T /usr/bin/productbuild
  rm -f "$work/cert.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  app_id="$(security find-identity -v -p codesigning "$keychain" | awk -F'"' '/Developer ID Application/{print $2; exit}')"
  installer_id="$(security find-identity -v "$keychain" | awk -F'"' '/Developer ID Installer/{print $2; exit}')"
  [ -n "$app_id" ] || { echo "no Developer ID Application identity in MACOS_CERT_P12" >&2; exit 1; }
  echo "signing with: $app_id${installer_id:+ / $installer_id}"
elif [ $require = 1 ]; then
  echo "signing required, but MACOS_CERT_P12 is not set" >&2; exit 1
else
  echo "::warning::no Developer ID secrets: ad-hoc signing, no notarization"
fi

sign() { # sign PATH ENTITLEMENTS
  if [ "$app_id" = "-" ]; then
    codesign --force --sign - --entitlements "$2" "$1"
  else
    codesign --force --options runtime --timestamp --entitlements "$2" --sign "$app_id" "$1"
  fi
}

# --- bundles --------------------------------------------------------------------------
lipo -create "$arm" "$x86" -output "$work/moonsec"
lipo -info "$work/moonsec"
mkbundle() { # mkbundle NAME BUNDLE_ID UI_ELEMENT ENTITLEMENTS
  local app="$work/apps/$1.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  install -m755 "$work/moonsec" "$app/Contents/MacOS/moonsec"
  install -m644 "$notices" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  sed -e "s|@BUNDLE_ID@|$2|" -e "s|@NAME@|$1|" -e "s|@VERSION_NUM@|$MOONSEC_VERSION_NUM|" \
      -e "s|@UI_ELEMENT@|$3|" "$here/Info.plist.in" > "$app/Contents/Info.plist"
  plutil -lint "$app/Contents/Info.plist"
  sign "$app" "$4"
  codesign --verify --strict --verbose=2 "$app"
}
mkbundle "moonsec Host" com.github.progrium.moonsec.host true "$here/host.entitlements"
mkbundle "moonsec" com.github.progrium.moonsec.client false "$here/client.entitlements"

# --- pkg ------------------------------------------------------------------------------
base="moonsec-$MOONSEC_VERSION-macos-universal"
pkgroot="$work/pkgroot"
mkdir -p "$pkgroot/Applications" "$pkgroot/Library/LaunchAgents"
cp -R "$work/apps/"*.app "$pkgroot/Applications/"
install -m644 "$here/host-launchagent.plist" "$pkgroot/Library/LaunchAgents/com.github.progrium.moonsec.host.plist"
# Install the bundles where the package says, even if a copy exists elsewhere.
pkgbuild --analyze --root "$pkgroot" "$work/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist" 2>/dev/null || true
plutil -replace 1.BundleIsRelocatable -bool NO "$work/components.plist" 2>/dev/null || true
pkgbuild --root "$pkgroot" --component-plist "$work/components.plist" --scripts "$here/scripts" \
  --identifier com.github.progrium.moonsec --version "$MOONSEC_VERSION_NUM" --install-location / "$work/moonsec-component.pkg"
productbuild_args=(--package "$work/moonsec-component.pkg")
[ -n "$installer_id" ] && productbuild_args+=(--sign "$installer_id" --timestamp)
productbuild "${productbuild_args[@]}" "$out/$base.pkg"

# --- dmg ------------------------------------------------------------------------------
dmgroot="$work/dmgroot"
mkdir -p "$dmgroot"
cp -R "$work/apps/"*.app "$dmgroot/"
ln -s /Applications "$dmgroot/Applications"
hdiutil create -volname "moonsec $MOONSEC_VERSION" -srcfolder "$dmgroot" -fs HFS+ -format UDZO -ov "$out/$base.dmg"
[ "$app_id" != "-" ] && codesign --force --timestamp --sign "$app_id" "$out/$base.dmg"

# --- notarize -------------------------------------------------------------------------
if [ "$app_id" != "-" ] && [ -n "${MACOS_NOTARY_KEY:-}" ]; then
  echo "$MACOS_NOTARY_KEY" | base64 --decode > "$work/notary.p8"
  for f in "$out/$base.pkg" "$out/$base.dmg"; do
    xcrun notarytool submit "$f" --key "$work/notary.p8" --key-id "$MACOS_NOTARY_KEY_ID" \
      --issuer "$MACOS_NOTARY_ISSUER" --wait --timeout 30m
    xcrun stapler staple "$f"
    xcrun stapler validate "$f"
  done
  spctl --assess --type install --verbose=2 "$out/$base.pkg"
elif [ $require = 1 ]; then
  echo "notarization required, but MACOS_NOTARY_KEY is not set" >&2; exit 1
fi
ls -l "$out/$base".*
