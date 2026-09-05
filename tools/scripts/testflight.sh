#!/usr/bin/env bash
#
# Build, sign, and upload the iOS app to App Store Connect / TestFlight.
#
# Usage:
#   bash tools/scripts/testflight.sh
#
# The script auto-bumps CFBundleVersion (App Store Connect requires a
# strictly-higher build number for every upload) and writes the new
# value back to the app and widget Info.plists. If the upload fails, revert with:
#   git checkout "Quill iOS/Info.plist" QuillWidget/Info.plist
#
# Prerequisites (one-time):
#   1. Apple Distribution cert in the login keychain, OR Xcode signed
#      into your Apple ID so `-allowProvisioningUpdates` can create one
#      on demand. Verify with:
#        security find-identity -p codesigning -v | grep "Apple Distribution"
#   2. App Store Connect API key .p8 file installed at one of:
#        ./private_keys
#        ~/private_keys
#        ~/.private_keys
#        ~/.appstoreconnect/private_keys   (recommended)
#      File name must be AuthKey_<KEY_ID>.p8.
#   3. App Store Connect app record with bundle ID com.joevasquez.Quill.iOS.
#
# Env overrides:
#   QUILL_ASC_KEY_ID        default: 3QDATSKTNN
#   QUILL_ASC_ISSUER_ID     default: 69a6de80-182b-47e3-e053-5b8c7c11a4d1
#
# Output:
#   build/testflight/Quill-iOS-<build>.ipa  — the signed .ipa we uploaded

set -euo pipefail

# --- Pinned Xcode (see release.sh — same CommandLineTools rationale) -----
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/testflight"
TEAM_ID="ND4KZ9EE2W"
SCHEME="Quill iOS"
INFO_PLIST="$REPO_ROOT/Quill iOS/Info.plist"
WIDGET_INFO_PLIST="$REPO_ROOT/QuillWidget/Info.plist"
BUNDLE_ID="com.joevasquez.Quill.iOS"

API_KEY_ID="${QUILL_ASC_KEY_ID:-3QDATSKTNN}"
API_ISSUER_ID="${QUILL_ASC_ISSUER_ID:-69a6de80-182b-47e3-e053-5b8c7c11a4d1}"

cd "$REPO_ROOT"

# --- Locate the API key file --------------------------------------------
API_KEY_PATH=""
for dir in \
  "$REPO_ROOT/private_keys" \
  "$HOME/private_keys" \
  "$HOME/.private_keys" \
  "$HOME/.appstoreconnect/private_keys"; do
  if [ -f "$dir/AuthKey_${API_KEY_ID}.p8" ]; then
    API_KEY_PATH="$dir/AuthKey_${API_KEY_ID}.p8"
    break
  fi
done
if [ -z "$API_KEY_PATH" ]; then
  echo "❌ App Store Connect API key not found: AuthKey_${API_KEY_ID}.p8"
  echo "   Download it from appstoreconnect.apple.com → Users and Access → Integrations → Keys"
  echo "   and place it in ~/.appstoreconnect/private_keys/"
  exit 1
fi

echo "→ iOS TestFlight upload"
echo "   bundle id:   $BUNDLE_ID"
echo "   team:        $TEAM_ID"
echo "   api key:     $API_KEY_PATH"

# --- Bump CFBundleVersion (iOS uses Info.plist directly, since the
# target sets GENERATE_INFOPLIST_FILE = NO) ------------------------------
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
echo "→ Bumping build number: $CURRENT_BUILD → $NEW_BUILD  (version $SHORT_VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$WIDGET_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$WIDGET_INFO_PLIST"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Archive ------------------------------------------------------------
echo "→ Archiving (this takes a couple of minutes)..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_DIR/QuillIOS.xcarchive" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  archive | grep -E "(error:|\*\* [A-Z]+ [A-Z]+ \*\*)" || true

if [ ! -d "$BUILD_DIR/QuillIOS.xcarchive" ]; then
  echo "❌ Archive not produced. Re-run without the error filter to see the full xcodebuild output:"
  echo "   xcodebuild -scheme '$SCHEME' -configuration Release -destination 'generic/platform=iOS' -archivePath '$BUILD_DIR/QuillIOS.xcarchive' -allowProvisioningUpdates archive"
  exit 1
fi

# --- Export App Store-signed .ipa --------------------------------------
echo "→ Exporting App Store signed .ipa..."
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>              <string>app-store-connect</string>
  <key>teamID</key>              <string>$TEAM_ID</string>
  <key>signingStyle</key>        <string>automatic</string>
  <key>uploadSymbols</key>       <true/>
  <key>destination</key>         <string>export</string>
  <key>stripSwiftSymbols</key>   <true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/QuillIOS.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  | grep -E "(error:|\*\* [A-Z]+ [A-Z]+ \*\*)" || true

# Export writes a .ipa named after the scheme (replacing space + TARGET_NAME
# substitutions). Find whatever landed in the export dir.
IPA_PATH=$(find "$BUILD_DIR/export" -maxdepth 1 -name '*.ipa' | head -1)
if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
  echo "❌ No .ipa in $BUILD_DIR/export — check the export step output above."
  exit 1
fi

# Stable name for this upload so multiple runs don't clobber each other.
FINAL_IPA="$BUILD_DIR/Quill-iOS-${SHORT_VERSION}-build${NEW_BUILD}.ipa"
mv "$IPA_PATH" "$FINAL_IPA"
echo "   $FINAL_IPA ($(du -m "$FINAL_IPA" | cut -f1) MB)"

# --- Upload to App Store Connect ---------------------------------------
echo "→ Uploading to App Store Connect..."
# altool is deprecated in newer Xcode but still the cleanest scriptable
# path with API key auth. Replacement is the Transporter app / iTMSTransporter.
xcrun altool --upload-app \
  --type ios \
  --file "$FINAL_IPA" \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID"

echo ""
echo "✅ Uploaded Quill iOS $SHORT_VERSION (build $NEW_BUILD) to App Store Connect."
echo ""
echo "Next steps:"
echo "  1. Wait ~5–15 min for Apple to process the build."
echo "  2. Check status at: https://appstoreconnect.apple.com/apps"
echo "  3. Once processed, go to the app → TestFlight tab → select the build."
echo "  4. First upload only: Apple will ask you to fill in export compliance"
echo "     info (you're using standard HTTPS + on-device Whisper, so choose"
echo "     \"Yes — standard encryption\") and app info for beta testers."
echo "  5. Add yourself (and anyone else) as Internal Testers for instant access,"
echo "     or create a public link under External Testers (needs Beta App Review,"
echo "     usually approved within 24 hours)."
echo ""
echo "Commit the build bump:"
echo "  git add 'Quill iOS/Info.plist' && git commit -m 'iOS: TestFlight build $NEW_BUILD'"
