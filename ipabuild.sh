#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
PROJECT_NAME="Luna"
APPLICATION_NAME="Eclipse"

PLATFORM=${1:-ios}

if [ "$PLATFORM" != "ios" ] && [ "$PLATFORM" != "iOS" ]; then
    echo "Error: Invalid platform '$PLATFORM'"
    echo "Usage: $0 [ios]"
    echo "  ios - Build for iOS (default)"
    exit 1
fi

PLATFORM="ios"
SDK="iphoneos"
XCODE_DESTINATION="generic/platform=iOS"
OUTPUT_SUFFIX=""

if ! command -v pod >/dev/null 2>&1; then
    echo "Error: CocoaPods is required to install the pinned VLCKit 4.0 build."
    echo "Install it with: gem install cocoapods"
    exit 1
fi

pod install

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

if [ -d "DerivedData$PLATFORM" ]; then
    rm -rf "DerivedData$PLATFORM"
fi

# Build with CocoaPods workspace so the pinned VLCKit binary is linked.
XCODE_PROJECT="-workspace $WORKING_LOCATION/$PROJECT_NAME.xcworkspace"

# Create archive (required for proper IPA structure)
ARCHIVE_PATH="$WORKING_LOCATION/build/$APPLICATION_NAME$OUTPUT_SUFFIX.xcarchive"

xcodebuild archive \
    $XCODE_PROJECT \
    -scheme "$PROJECT_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "$XCODE_DESTINATION" \
    -sdk "$SDK" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
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

# Create Payload directory and copy app
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
