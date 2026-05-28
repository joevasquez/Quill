#!/usr/bin/env bash
#
# Build, sign, notarize, and package a Developer ID-signed DMG for
# distribution via GitHub Releases.
#
# Usage:
#   bash tools/scripts/release.sh [VERSION]
#
# If VERSION is omitted, the version is read from Hex/Info.plist.
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate in the login keychain.
#      Verify with:  security find-identity -p codesigning -v
#   2. Notarization credentials stored under profile name QUILL_NOTARY:
#        xcrun notarytool store-credentials QUILL_NOTARY \
#          --apple-id "you@example.com" \
#          --team-id  ND4KZ9EE2W \
#          --password "APP_SPECIFIC_PASSWORD"
#      Generate the app-specific password at appleid.apple.com →
#      Sign-In and Security → App-Specific Passwords.
#
# Output:
#   build/release/Hex-latest.dmg        — signed, notarized, stapled DMG
#   build/release/release-notes.md      — extracted notes for this version

set -euo pipefail

# Use the full Xcode, not Command Line Tools. Some dev machines have
# xcode-select pointed at /Library/Developer/CommandLineTools, which
# can't run xcodebuild. Override for the duration of this script so
# it works regardless of the user's xcode-select setting.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/release"
TEAM_ID="ND4KZ9EE2W"
NOTARY_PROFILE="${NOTARY_PROFILE:-QUILL_NOTARY}"
SCHEME="Quill"
DMG_NAME="Hex-latest.dmg"   # Keep this stable so the
                            # /releases/latest/download/Hex-latest.dmg
                            # link on the marketing site never changes.

cd "$REPO_ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Hex/Info.plist)}"

echo "→ Releasing Quill v$VERSION"
echo "   team:           $TEAM_ID"
echo "   notary profile: $NOTARY_PROFILE"

# Sanity check: Developer ID cert present.
if ! security find-identity -p codesigning -v | grep -q "Developer ID Application.*$TEAM_ID"; then
  echo "❌ No Developer ID Application cert for team $TEAM_ID found in keychain."
  echo "   Create one in Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application."
  exit 1
fi

# Sanity check: notarytool profile exists.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
  echo "❌ notarytool profile '$NOTARY_PROFILE' not found or invalid."
  echo "   Store it with:"
  echo "     xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "       --apple-id you@example.com --team-id $TEAM_ID \\"
  echo "       --password APP_SPECIFIC_PASSWORD"
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 1. Archive
echo "→ Archiving Release build..."
xcodebuild -scheme "$SCHEME" -configuration Release \
  -archivePath "$BUILD_DIR/Quill.xcarchive" \
  archive | grep -E "(error:|warning:|\*\* [A-Z]+ [A-Z]+ \*\*)" || true

# 2. Export with Developer ID
echo "→ Exporting Developer ID signed .app..."
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>        <string>developer-id</string>
  <key>teamID</key>        <string>$TEAM_ID</string>
  <key>signingStyle</key>  <string>automatic</string>
  <key>destination</key>   <string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/Quill.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  | grep -E "(error:|\*\* [A-Z]+ [A-Z]+ \*\*)" || true

APP_PATH="$BUILD_DIR/export/Quill.app"
[ -d "$APP_PATH" ] || { echo "❌ Expected $APP_PATH, not found"; exit 1; }

# 3. Notarize the .app
echo "→ Zipping .app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/Quill.zip"

echo "→ Submitting .app to Apple notary (may take a few minutes)..."
xcrun notarytool submit "$BUILD_DIR/Quill.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "→ Stapling ticket to .app..."
xcrun stapler staple "$APP_PATH"

# 4. Build DMG
echo "→ Building DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_PATH="$BUILD_DIR/$DMG_NAME"
hdiutil create \
  -volname "Quill" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" | tail -1

# 5. Notarize + staple the DMG
echo "→ Submitting DMG to Apple notary..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "→ Stapling ticket to DMG..."
xcrun stapler staple "$DMG_PATH"

# 6. Verify the stapled ticket is valid. (spctl with the wrong flag family
# — e.g. context:primary-signature — reports "no usable signature" on
# DMGs even when they're correctly notarized, because that flag checks
# code-signed executables, not disk images. `stapler validate` is the
# right check for a DMG.)
echo "→ Verifying stapled notarization ticket..."
xcrun stapler validate "$DMG_PATH"

# 7. Extract release notes for this version from CHANGELOG.md
echo "→ Extracting release notes for v$VERSION..."
NOTES_PATH="$BUILD_DIR/release-notes.md"
awk -v ver="$VERSION" '
  BEGIN { inblock = 0 }
  /^## / {
    if (inblock) exit
    if ($0 ~ "^## " ver "( .*)?$") { inblock = 1; next }
  }
  inblock { print }
' CHANGELOG.md > "$NOTES_PATH"

if [ ! -s "$NOTES_PATH" ]; then
  echo "⚠️  No release notes found for v$VERSION in CHANGELOG.md. Add a '## $VERSION' section."
fi

# 8. Sign the DMG for Sparkle and update the appcast
SIGN_UPDATE="$REPO_ROOT/bin/sign_update"
GENERATE_APPCAST="$REPO_ROOT/bin/generate_appcast"
APPCAST_PATH="$REPO_ROOT/appcast.xml"
DOWNLOAD_URL="https://github.com/joevasquez/Hex/releases/download/v${VERSION}/$DMG_NAME"

if [ -x "$SIGN_UPDATE" ]; then
  echo "→ Signing DMG for Sparkle..."
  SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1 | grep 'sparkle:edSignature=' | head -1)
  if [ -n "$SIGNATURE" ]; then
    ED_SIGNATURE=$(echo "$SIGNATURE" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
    LENGTH=$(echo "$SIGNATURE" | sed 's/.*length="\([^"]*\)".*/\1/')
    echo "   edSignature: ${ED_SIGNATURE:0:20}..."
    echo "   length:      $LENGTH"
  else
    # sign_update may print just the signature on a single line
    ED_SIGNATURE=$("$SIGN_UPDATE" "$DMG_PATH" 2>&1 | tail -1)
    LENGTH=$(stat -f%z "$DMG_PATH")
    echo "   edSignature: ${ED_SIGNATURE:0:20}..."
    echo "   length:      $LENGTH"
  fi
else
  echo "⚠️  bin/sign_update not found — skipping Sparkle signing."
  echo "   Copy it from DerivedData:"
  echo "     cp \$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin/sign_update' | head -1) bin/"
  ED_SIGNATURE=""
  LENGTH=$(stat -f%z "$DMG_PATH")
fi

if [ -x "$GENERATE_APPCAST" ]; then
  echo "→ Generating appcast.xml..."
  # generate_appcast errors on duplicate versions if it finds both the
  # .zip (used for notarization) and the .dmg. Remove the zip first.
  rm -f "$BUILD_DIR/Quill.zip"
  "$GENERATE_APPCAST" --download-url-prefix "https://github.com/joevasquez/Hex/releases/download/v${VERSION}/" \
    "$BUILD_DIR" 2>&1 | tail -5 || true

  # generate_appcast writes appcast.xml inside the scanned directory
  if [ -f "$BUILD_DIR/appcast.xml" ]; then
    cp "$BUILD_DIR/appcast.xml" "$APPCAST_PATH"
    echo "   Updated $APPCAST_PATH"
  else
    echo "⚠️  generate_appcast did not produce appcast.xml — you may need to create it manually."
  fi
else
  echo "⚠️  bin/generate_appcast not found — skipping appcast generation."
fi

DMG_SIZE_MB=$(du -m "$DMG_PATH" | cut -f1)
echo ""
echo "✅ Done — $DMG_PATH (${DMG_SIZE_MB} MB)"
echo ""
echo "Next steps:"
echo ""
echo "  1. Commit the updated appcast.xml:"
echo "     git add appcast.xml"
echo "     git commit -m 'Update appcast for v$VERSION'"
echo ""
echo "  2. Tag and push:"
echo "     git tag v$VERSION"
echo "     git push fork main v$VERSION"
echo ""
echo "  3. Create the GitHub Release:"
echo "     gh release create v$VERSION --repo joevasquez/Hex \\"
echo "       --title 'Quill v$VERSION' \\"
echo "       --notes-file '$NOTES_PATH' \\"
echo "       '$DMG_PATH'"
echo ""
echo "The download URL on your site stays stable:"
echo "  https://github.com/joevasquez/Hex/releases/latest/download/$DMG_NAME"
echo ""
echo "Sparkle will check for updates at:"
echo "  https://raw.githubusercontent.com/joevasquez/Hex/main/appcast.xml"
