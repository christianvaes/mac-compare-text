#!/bin/zsh
# Builds CompareText.app: universal binary (Apple Silicon + Intel),
# sandboxed, hardened runtime, plus a distribution zip in dist/.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CompareText.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile for both architectures and merge with lipo.
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o build/CompareText-arm64
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 \
    Sources/*.swift -o build/CompareText-x86_64
lipo -create build/CompareText-arm64 build/CompareText-x86_64 \
    -output "$APP/Contents/MacOS/CompareText"
rm build/CompareText-arm64 build/CompareText-x86_64

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

echo "Done: $APP  (universal: $(lipo -archs "$APP/Contents/MacOS/CompareText"))"
echo "Distribution: dist/CompareText.zip"
echo "Run with: open $APP"
