#!/bin/zsh
# Archives the app for iOS and for the Mac (Mac Catalyst) and uploads both to TestFlight.
# With --mac-only, only the Mac build is made.
# With --external, also gives the build to the external group "Testers" and submits it
# for beta review (scripts/distribute.py), once App Store Connect has processed it.
# Needs the App Store Connect API key in ~/.appstoreconnect/private_keys and the
# "Frigate App Store" and "Frigate Mac App Store" provisioning profiles plus the Apple
# Distribution and Mac Installer Distribution certificates installed.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_ID=TDLK875PQH
ISSUER=69a6de8f-8c00-47e3-e053-5b8c7c11a4d1
AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
      -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER)
BUILD=$(date +%Y%m%d%H%M)
# Shown in Settings; "-dirty" when there are uncommitted changes.
COMMIT=$(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo -dirty)

if [[ "${1:-}" != "--mac-only" ]]; then
  rm -rf build/Frigate.xcarchive build/export
  xcodebuild -project Frigate.xcodeproj -scheme Frigate -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Frigate.xcarchive \
    -allowProvisioningUpdates "${AUTH[@]}" CURRENT_PROJECT_VERSION=$BUILD GIT_COMMIT=$COMMIT archive | grep -E "error|ARCHIVE"
  xcodebuild -exportArchive -archivePath build/Frigate.xcarchive \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export "${AUTH[@]}" | grep -E "error|Upload succeeded|EXPORT"
  echo "Uploaded iOS build $BUILD"
fi

# Mac: altool needs the app's Apple ID, as App Store Connect has no separate macOS record.
rm -rf build/FrigateMac.xcarchive build/export-mac
xcodebuild -project Frigate.xcodeproj -scheme Frigate -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath build/FrigateMac.xcarchive \
  -allowProvisioningUpdates "${AUTH[@]}" CURRENT_PROJECT_VERSION=$BUILD GIT_COMMIT=$COMMIT archive | grep -E "error|ARCHIVE"
xcodebuild -exportArchive -archivePath build/FrigateMac.xcarchive \
  -exportOptionsPlist scripts/ExportOptionsMac.plist -exportPath build/export-mac "${AUTH[@]}" | grep -E "error|EXPORT"
xcrun altool --upload-app -f build/export-mac/Frigate.pkg -t macos --apple-id 6833388470 \
  --apiKey $KEY_ID --apiIssuer $ISSUER 2>&1 | grep -E "ERROR|UPLOAD|error"
echo "Uploaded Mac build $BUILD"
if [[ "${1:-}" == "--external" ]]; then
  python3 scripts/distribute.py "$BUILD"
fi
