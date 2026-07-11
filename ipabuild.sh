#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
PROJECT_NAME="Eclipse"
APPLICATION_NAME="Eclipse"

PLATFORM=${1:-ios}

case "$PLATFORM" in
    ios|iOS)
        PLATFORM="ios"
        SCHEME="$PROJECT_NAME"
        SDK="iphoneos"
        XCODE_DESTINATION="generic/platform=iOS"
        OUTPUT_SUFFIX=""
        ;;
    tvos|tvOS)
        PLATFORM="tvos"
        SCHEME="$PROJECT_NAME-tvOS"
        SDK="appletvos"
        XCODE_DESTINATION="generic/platform=tvOS"
        OUTPUT_SUFFIX="-tvOS"
        ;;
    *)
        echo "Error: Invalid platform '$PLATFORM'"
        echo "Usage: $0 [ios|tvos]"
        echo "  ios  - Build for iOS (default)"
        echo "  tvos - Build for tvOS"
        exit 1
        ;;
esac

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

if [ -d "DerivedData$PLATFORM" ]; then
    rm -rf "DerivedData$PLATFORM"
fi

# Build with Xcode project and Swift Package Manager dependencies.
XCODE_PROJECT="-project $WORKING_LOCATION/$PROJECT_NAME.xcodeproj"

# Create archive (required for proper IPA structure)
ARCHIVE_PATH="$WORKING_LOCATION/build/$APPLICATION_NAME$OUTPUT_SUFFIX.xcarchive"
rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
    $XCODE_PROJECT \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "$XCODE_DESTINATION" \
    -sdk "$SDK" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ECLIPSE_UNSIGNED_BUILD' \
    ENABLE_USER_SCRIPT_SANDBOXING=NO

# Verify archive was created
if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "Error: Archive failed to create at $ARCHIVE_PATH"
    exit 1
fi

# Extract app from archive (correct path: Products/Applications)
APP_PATH="$ARCHIVE_PATH/Products/Applications/$PROJECT_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name "*.app" 2>/dev/null | head -n 1)"
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
        echo "Error: App not found at $ARCHIVE_PATH/Products/Applications"
        echo "Contents of archive:"
        find "$ARCHIVE_PATH" -type d -name "*.app" 2>/dev/null || echo "No app bundles found"
        exit 1
    fi
fi

if [ "$PLATFORM" = "ios" ]; then
    "$WORKING_LOCATION/scripts/validate-ios-privacy-manifest.sh" "$APP_PATH"
else
    # tvOS deliberately omits the disk-space/file-timestamp required-reason
    # declarations the iOS validator enforces, so it gets a lighter check.
    MANIFEST_PATH="$APP_PATH/PrivacyInfo.xcprivacy"
    if [ ! -f "$MANIFEST_PATH" ]; then
        echo "Error: PrivacyInfo.xcprivacy is missing from the tvOS app bundle."
        exit 1
    fi
    plutil -lint "$MANIFEST_PATH" >/dev/null
    echo "tvOS privacy manifest validation passed"
fi

# Create Payload directory and copy app
rm -rf Payload
rm -f "$APPLICATION_NAME$OUTPUT_SUFFIX.ipa"
mkdir Payload
cp -r "$APP_PATH" "Payload/$APPLICATION_NAME.app"

# Strip binary to reduce size
if [ -f "Payload/$APPLICATION_NAME.app/$PROJECT_NAME" ]; then
    strip "Payload/$APPLICATION_NAME.app/$PROJECT_NAME" 2>/dev/null || true
elif [ -f "Payload/$APPLICATION_NAME.app/$APPLICATION_NAME" ]; then
    strip "Payload/$APPLICATION_NAME.app/$APPLICATION_NAME" 2>/dev/null || true
fi

# Remove code signature
rm -rf "Payload/$APPLICATION_NAME.app/_CodeSignature" 2>/dev/null || true
rm -f "Payload/$APPLICATION_NAME.app/embedded.mobileprovision" 2>/dev/null || true

# Create IPA (preserve symlinks with -y, recursive with -r)
zip -qry "$APPLICATION_NAME$OUTPUT_SUFFIX.ipa" Payload

# Cleanup
rm -rf Payload
rm -rf "$ARCHIVE_PATH"
