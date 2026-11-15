#!/bin/sh
# Builds an unsigned Release .ipa for sideloading with SideStore or AltStore, which sign the app
# with the installer's own Apple ID. No certificate, profile or team needed: Freeband has no
# entitlements of its own.
#
#   sh tools/build-ipa.sh        # from ios/; writes build/Freeband.ipa
#
# The build number is the repository's commit count, as in testflight.sh. Building rewrites the
# string catalogs (strings marked stale, translations flipped to needs_review); they are put back
# as they were before the build, uncommitted edits included.
set -e

IOS=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD_DIR:-$IOS/build}
BUILD_NUMBER=$(git -C "$IOS" rev-list --count HEAD)
CATALOGS="$IOS/Freeband/Resources/Localizable.xcstrings $IOS/Freeband/Resources/AppShortcuts.xcstrings"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

SAVED=$(mktemp -d)
cp $CATALOGS "$SAVED/"
restore_catalogs() { cp "$SAVED"/*.xcstrings "$IOS/Freeband/Resources/"; rm -rf "$SAVED"; }
trap restore_catalogs EXIT INT TERM

cd "$IOS"
xcodegen generate --quiet
xcodebuild build -quiet \
  -project Freeband.xcodeproj -scheme Freeband -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/DerivedData" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO

# An .ipa is a zip of Payload/Freeband.app.
rm -rf "$BUILD/Payload" "$BUILD/Freeband.ipa"
mkdir -p "$BUILD/Payload"
cp -R "$BUILD/DerivedData/Build/Products/Release-iphoneos/Freeband.app" "$BUILD/Payload/"
(cd "$BUILD" && zip -qry Freeband.ipa Payload)
rm -rf "$BUILD/Payload"
echo "$BUILD/Freeband.ipa (build $BUILD_NUMBER)"
