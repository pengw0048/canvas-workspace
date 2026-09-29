#!/bin/zsh
# Builds dist/CanvasWorkspace.app from the release product.
set -euo pipefail
cd "$(dirname $0)/.."
swift build -c release
app=dist/CanvasWorkspace.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/CanvasWorkspace "$app/Contents/MacOS/CanvasWorkspace"
cp docs/USER-GUIDE.md "$app/Contents/Resources/USER-GUIDE.md" 2>/dev/null || true
iconset=$(mktemp -d)/AppIcon.iconset
.build/release/CanvasWorkspace --write-iconset "$iconset" && iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.pengw0048.canvasworkspace</string>
  <key>CFBundleName</key><string>Canvas Workspace</string>
  <key>CFBundleExecutable</key><string>CanvasWorkspace</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Canvas Workspace connects to collaborators on your local network.</string>
  <key>NSBonjourServices</key><array><string>_canvasws._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier io.github.pengw0048.canvasworkspace "$app"
echo "Built $app"
