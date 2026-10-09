#!/bin/bash
# Builds SwiftCel for iPad, next to this script:
#   SwiftCel-iPad.ipa        the app for a real iPad, ready for a sideloading tool to sign
#   build-ipad/Simulator/    the same app for Xcode's iPad Simulator, which is then opened
# Everything printed here is also saved to build-ipad.log.
cd "$(dirname "$0")" || exit 1
{
    echo "Building SwiftCel for iPad  ($(date))"
    sw_vers 2>/dev/null

    # Use the full Xcode even if the command line tools are the selected developer folder.
    if [ -z "$DEVELOPER_DIR" ]; then
        for X in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
            if [ -d "$X/Contents/Developer" ]; then
                export DEVELOPER_DIR="$X/Contents/Developer"
                break
            fi
        done
    fi
    echo "Developer folder: ${DEVELOPER_DIR:-(default)}"
    if [ -z "$DEVELOPER_DIR" ]; then
        echo "RESULT: NO XCODE. Install Xcode from the App Store, open it once, then run this again."
        exit 1
    fi
    if ! xcodebuild -license check >/dev/null 2>&1; then
        echo "NOTE: Xcode may not be set up yet. If the build fails below, open Xcode once, agree to the licence,"
        echo "      let it finish installing, then run this again."
    fi
    DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"
    if [ -z "$DEVICE_SDK" ] || [ ! -d "$DEVICE_SDK" ]; then
        echo "RESULT: NO IPAD SDK. In Xcode, open Settings > Components (or Platforms) and install iOS, then run this again."
        exit 1
    fi
    xcrun swiftc --version 2>&1

    OUT="build-ipad"
    rm -rf "$OUT" SwiftCel-iPad.ipa
    mkdir -p "$OUT"

    # make_app <sdk name> <target triple> <app folder> <platform name>
    make_app() {
        local SDK
        SDK="$(xcrun --sdk "$1" --show-sdk-path 2>/dev/null)"
        [ -d "$SDK" ] || return 2
        mkdir -p "$3"
        xcrun --sdk "$1" swiftc -O -wmo -swift-version 5 -parse-as-library -module-name SwiftCel \
            -sdk "$SDK" -target "$2" -o "$3/SwiftCel" Shared/*.swift iPad/Sources/*.swift 2>&1 || return 1
        cp iPad/Resources/Info.plist "$3/Info.plist"
        cp iPad/Resources/Icons/*.png "$3/" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" \
            -c "Add :CFBundleSupportedPlatforms:0 string $4" \
            -c "Add :DTPlatformName string $(echo "$4" | tr '[:upper:]' '[:lower:]')" "$3/Info.plist" >/dev/null 2>&1
        printf 'APPL????' > "$3/PkgInfo"
        codesign --force --sign - "$3" 2>&1
        return 0
    }

    echo
    echo "--- iPad build ---"
    DEVICE_APP="$OUT/Payload/SwiftCel.app"
    if ! make_app iphoneos arm64-apple-ios16.0 "$DEVICE_APP" iPhoneOS; then
        echo "RESULT: BUILD FAILED"
        exit 1
    fi
    ( cd "$OUT" && zip -qry ../SwiftCel-iPad.ipa Payload )
    if [ ! -f SwiftCel-iPad.ipa ]; then
        echo "RESULT: BUILD FAILED (could not package the .ipa)"
        exit 1
    fi
    echo "Made SwiftCel-iPad.ipa ($(du -h SwiftCel-iPad.ipa | cut -f1 | tr -d ' '))"

    echo
    echo "--- Simulator build ---"
    SIM_APP="$OUT/Simulator/SwiftCel.app"
    SIM_NOTE=""
    make_app iphonesimulator "$(uname -m)-apple-ios16.0-simulator" "$SIM_APP" iPhoneSimulator
    case $? in
        0)
            LIST="$(xcrun simctl list devices available 2>/dev/null)"
            UDID="$(echo "$LIST" | grep 'iPad Pro' | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)"
            [ -z "$UDID" ] && UDID="$(echo "$LIST" | grep 'iPad' | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)"
            if [ -z "$UDID" ]; then
                SIM_NOTE="no iPad simulator is installed (Xcode > Settings > Components > iOS adds one)"
            else
                echo "Simulator device: $(echo "$LIST" | grep "$UDID" | sed 's/^ *//')"
                xcrun simctl boot "$UDID" >/dev/null 2>&1
                open -a Simulator 2>&1
                xcrun simctl bootstatus "$UDID" >/dev/null 2>&1
                if xcrun simctl install "$UDID" "$SIM_APP" 2>&1 && xcrun simctl launch "$UDID" local.swiftcel.ipad 2>&1; then
                    SIM_NOTE="running in the Simulator"
                else
                    SIM_NOTE="built, but could not be started in the Simulator"
                fi
            fi
            ;;
        2) SIM_NOTE="the iPad Simulator is not installed (Xcode > Settings > Components > iOS adds it)" ;;
        *) SIM_NOTE="the Simulator build failed (see above)" ;;
    esac
    echo
    echo "Simulator: $SIM_NOTE"
    echo "RESULT: OK"
} 2>&1 | tee build-ipad.log
