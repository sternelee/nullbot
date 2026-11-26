#!/bin/sh
# Builds NullClaw.app and NullClaw-macos-arm64.dmg in zig-out/package.
#
#   sh macos/package.sh
#   VERSION=0.2.0 sh macos/package.sh
#
# Signs with $CODESIGN_IDENTITY (a "Developer ID Application" identity in the
# keychain) when it is set, else ad hoc. Notarizes and staples the app and the
# disk image when it is set and either NOTARY_PROFILE (a profile saved with
# `xcrun notarytool store-credentials`) or NOTARY_KEY_PATH, NOTARY_KEY_ID and
# NOTARY_ISSUER_ID (an App Store Connect API key) are set.
#
# The window links the runtime, so there is nothing else in the bundle: one
# binary, its icon, and the plist that names them.
set -eu
cd "$(dirname "$0")/.."

app=NullClaw
exe=nullclaw-gui
version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
out=zig-out/package
bundle="$out/$app.app"
dmg="$out/$app-macos-arm64.dmg"

# For macOS 13 and Apple silicon from the M1 on: a native build would need the
# macOS and the CPU it was built on, and this is what the release ships.
min_macos=13.0
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos.$min_macos -Dcpu=apple_m1 \
  -Dversion="$version" ${ZIG_FLAGS:-}

# The build can succeed and still produce a binary for the wrong system
# (a cached artifact, a target that was ignored); the plist would then claim a
# version the binary does not have.
if ! vtool -show-build "zig-out/bin/$exe" | grep -q "minos $min_macos\$"; then
  echo "zig-out/bin/$exe is not built for macOS $min_macos:" >&2
  vtool -show-build "zig-out/bin/$exe" >&2
  exit 1
fi

# The icon, when the source picture is newer than the .icns beside this script
# or the .icns is missing: a committed icon that no longer matches the mark is
# worse than one built on the way past.
if [ ! -f macos/AppIcon.icns ] || [ ../nullclaw.png -nt macos/AppIcon.icns ]; then
  sh macos/make-icon.sh
fi

rm -rf "$out"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "zig-out/bin/$exe" "$bundle/Contents/MacOS/$exe"
cp macos/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>$app</string>
  <key>CFBundleIdentifier</key><string>io.nullclaw.gui</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleGetInfoString</key><string>A desktop window for the nullclaw runtime</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>$min_macos</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

sign() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

notarizing() {
  [ -n "${CODESIGN_IDENTITY:-}" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY_PATH:-}" ]; }
}

notarize() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" --wait
  fi
}

sign "$bundle"
if notarizing; then
  # The app itself must be notarized before it is put in the image: a stapled
  # app inside an unstapled image still trips Gatekeeper on a machine that is
  # offline when it is first opened.
  ditto -c -k --keepParent "$bundle" "$out/$app.zip"
  notarize "$out/$app.zip"
  xcrun stapler staple "$bundle"
  rm "$out/$app.zip"
fi

# The disk image: the app, and Applications to drag it to.
stage="$out/dmg"
mkdir -p "$stage"
cp -R "$bundle" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$app" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
sign "$dmg"
if notarizing; then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
fi
shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "built $dmg"
