#!/bin/sh
# Builds Freeband (Release, development signing) and installs it straight onto a paired iPhone,
# over the copy that is there: the app's data and the band's key stay.
#
#   ~/bin/signing-run sh tools/device-install.sh <device name>     (from ios/)
#
# The device name is as `xcrun devicectl list devices` shows it; without one, the script lists
# the iPhones and stops. The build number is the commit count, as in tools/testflight.sh.
# Needs the App Store Connect API key (AuthKey_<id>.p8) for automatic provisioning.
#
# A copy from TestFlight is replaced by this one; if TestFlight then offers an "update", it is
# the older build.
set -e
IOS=$(cd "$(dirname "$0")/.." && pwd)
TEAM=6U58AKY6F8
ASC_KEY_ID=${ASC_KEY_ID:-LS38TKZZ5U}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-93179d25-e1b9-4256-941e-27126dcc7ea6}
KEYCHAIN=${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/cobanov-signing.keychain-db}
P8=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
[ -f "$P8" ] || P8=$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8
BUILD=${BUILD_DIR:-/tmp/freeband-device}

DEVICE=$(sh "$(dirname "$0")/device-find.sh" "$1")

cd "$IOS"
xcodegen generate --quiet
xcodebuild -quiet -project Freeband.xcodeproj -scheme Freeband -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates -authenticationKeyPath "$P8" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  CURRENT_PROJECT_VERSION="$(git -C "$IOS" rev-list --count HEAD)" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" build
# The build rewrites the string catalogs (AGENTS.md, "Committing").
git -C "$IOS" checkout -- Freeband/Resources/Localizable.xcstrings Freeband/Resources/AppShortcuts.xcstrings 2>/dev/null || true
xcrun devicectl device install app --device "$DEVICE" "$BUILD/Build/Products/Release-iphoneos/Freeband.app" >/dev/null
xcrun devicectl device info apps --device "$DEVICE" --bundle-id dev.cobanov.freeband 2>/dev/null | grep Freeband
