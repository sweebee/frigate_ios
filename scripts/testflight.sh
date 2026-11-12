#!/bin/zsh
# Archives the app and uploads it to TestFlight.
# With --external, also gives the build to the external group "Testers" and submits it
# for beta review (scripts/distribute.py), once App Store Connect has processed it.
# Needs the App Store Connect API key in ~/.appstoreconnect/private_keys and the
# "Frigate App Store" provisioning profile plus Apple Distribution certificate installed.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_ID=TDLK875PQH
ISSUER=69a6de8f-8c00-47e3-e053-5b8c7c11a4d1
AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
      -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER)
BUILD=$(date +%Y%m%d%H%M)
# Shown in Settings; "-dirty" when there are uncommitted changes.
COMMIT=$(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo -dirty)

rm -rf build/Frigate.xcarchive build/export
xcodebuild -project Frigate.xcodeproj -scheme Frigate -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Frigate.xcarchive \
  -allowProvisioningUpdates "${AUTH[@]}" CURRENT_PROJECT_VERSION=$BUILD GIT_COMMIT=$COMMIT archive | grep -E "error|ARCHIVE"
xcodebuild -exportArchive -archivePath build/Frigate.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export "${AUTH[@]}" | grep -E "error|Upload succeeded|EXPORT"
echo "Uploaded build $BUILD"
if [[ "${1:-}" == "--external" ]]; then
  python3 scripts/distribute.py "$BUILD"
fi
