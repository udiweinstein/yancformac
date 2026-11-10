#!/bin/sh
# Builds a release binary and wraps it in "YANC for Mac.app"
set -e
cd "$(dirname "$0")"
swift build -c release --product YANCMac
APP="YANC for Mac.app"
VERSION=$(tr -d ' \n' < VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YANCMac "$APP/Contents/MacOS/YANCMac"

# App icon: Icon/AppIcon.png (1024x1024) -> AppIcon.icns  (sips and iconutil come with macOS)
if [ -f Icon/AppIcon.png ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>YANC for Mac</string>
  <key>CFBundleIdentifier</key><string>com.udiweinstein.yancmac</string>
  <key>CFBundleExecutable</key><string>YANCMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # make Finder pick up the new icon
echo "Built: $APP (version $VERSION)"
