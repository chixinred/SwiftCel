#!/bin/bash
# Builds SwiftCel for the Mac and opens it.
#   SwiftCel.app   is made next to this script.
# Everything printed here is also saved to build-mac.log, so a failed build can be
# read afterwards. Needs Apple's command line tools (xcode-select --install) or Xcode.
cd "$(dirname "$0")" || exit 1
{
    echo "Building SwiftCel for Mac  ($(date))"
    sw_vers 2>/dev/null
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        echo "RESULT: NO COMPILER. Install Apple's command line tools with: xcode-select --install"
        exit 1
    fi
    xcrun swiftc --version 2>&1
    APP="SwiftCel.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    if xcrun swiftc -O -wmo -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
        -o "$APP/Contents/MacOS/SwiftCel" Shared/*.swift Mac/Sources/*.swift 2>&1; then
        cp Mac/Resources/Info.plist "$APP/Contents/Info.plist"
        cp Mac/Resources/AppIcon.icns Mac/Resources/Document.icns "$APP/Contents/Resources/" 2>/dev/null
        cp Mac/Resources/Splash.png Mac/Resources/Credits.txt "$APP/Contents/Resources/" 2>/dev/null
        codesign --force --sign - "$APP" 2>&1
        # Tell Finder about the .swcel document type and its icon.
        LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        [ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>&1
        touch "$APP"
        echo "RESULT: OK"
        open "$APP"
    else
        rm -rf "$APP"
        echo "RESULT: BUILD FAILED"
        exit 1
    fi
} 2>&1 | tee build-mac.log
