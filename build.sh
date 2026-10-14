#!/bin/zsh
# Builds "Compare Text.app": universal binary (Apple Silicon + Intel),
# sandboxed, hardened runtime, plus a distribution zip in dist/.
# With --install, the new build also replaces /Applications/Compare Text.app.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "Usage: ./build.sh [--install]" >&2; exit 2 ;;
    esac
done

# The .noindex suffix keeps Spotlight, and with it the Apps menu, from
# listing the build output as a second copy of the app.
BUILD="build.noindex"
APP="$BUILD/Compare Text.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$BUILD" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile for both architectures and merge with lipo.
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$BUILD/CompareText-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 \
    Sources/*.swift -o "$BUILD/CompareText-x86_64"
lipo -create "$BUILD/CompareText-arm64" "$BUILD/CompareText-x86_64" \
    -output "$APP/Contents/MacOS/CompareText"
rm "$BUILD/CompareText-arm64" "$BUILD/CompareText-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Stamp build date and build number into the bundle (shown in the About
# window). The version number (CFBundleShortVersionString) is managed
# manually in Info.plist.
/usr/libexec/PlistBuddy -c "Add :BuildDate string $(date '+%d-%m-%Y %H:%M')" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date '+%Y%m%d.%H%M')" "$APP/Contents/Info.plist"

# Ad-hoc signing with App Sandbox + hardened runtime. codesign occasionally
# fails once on extended attributes ("detritus"); strip and retry.
signed=0
for attempt in 1 2 3; do
    xattr -cr "$APP" 2>/dev/null || true
    find "$APP" -name "._*" -delete 2>/dev/null || true
    if codesign --force --options runtime \
        --entitlements CompareText.entitlements \
        --sign - "$APP"; then
        signed=1
        break
    fi
    echo "codesign attempt $attempt failed; retrying…" >&2
    sleep 1
done
if [ "$signed" -ne 1 ]; then
    echo "ERROR: codesign keeps failing" >&2
    exit 1
fi

# Verify that the sandbox entitlement really made it into the signature; a
# silently failed codesign would otherwise leave an unsandboxed app behind.
if ! codesign -d --entitlements - "$APP" 2>&1 | grep -q "app-sandbox"; then
    echo "ERROR: sandbox entitlement missing after signing" >&2
    exit 1
fi

# Distribution: a single zip that can be unpacked and launched on any Mac.
mkdir -p dist
ditto -c -k --keepParent "$APP" dist/CompareText.zip

# Launching a bundle registers it with macOS; forget the build output so
# only an installed copy is offered.
"$LSREGISTER" -u "$APP" 2>/dev/null || true

echo "Done: $APP  (universal: $(lipo -archs "$APP/Contents/MacOS/CompareText"))"
echo "Distribution: dist/CompareText.zip"

if [ "$INSTALL" -eq 1 ]; then
    TARGET="/Applications/Compare Text.app"
    # Earlier versions were installed under this name.
    rm -rf "/Applications/CompareText.app"
    # A running copy keeps working on its old code until it is reopened.
    RUNNING=0
    pgrep -f "$TARGET/Contents/MacOS/CompareText" >/dev/null && RUNNING=1
    rm -rf "$TARGET"
    ditto "$APP" "$TARGET"
    # macOS adds Finder metadata to the bundle, which a strict signature
    # check rejects; it is not part of the signature, so strip it.
    xattr -cr "$TARGET" 2>/dev/null || true
    codesign --verify --strict "$TARGET"
    echo "Installed: $TARGET ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist"))"
    [ "$RUNNING" -eq 1 ] && echo "Note: the installed app is open; quit and reopen it to use the new version."
else
    echo "Run with: open \"$APP\""
fi
