#!/bin/zsh
# Builds BatteryAnalysis.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="BatteryAnalysis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BatteryAnalysis "$APP/Contents/MacOS/BatteryAnalysis"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Battery Analysis</string>
<key>CFBundleDisplayName</key><string>Battery Analysis</string>
<key>CFBundleIdentifier</key><string>local.batteryanalysis</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>BatteryAnalysis</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
  echo "Installed to /Applications/$APP"
fi
