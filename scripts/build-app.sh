#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release
APP="dist/Processes.app"
mkdir -p "$APP/Contents/MacOS"
BIN_DIR=$(swift build --build-system native -c release --show-bin-path)
cp "$BIN_DIR/ProcessesMenu" "$APP/Contents/MacOS/ProcessesMenu"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ProcessesMenu</string>
  <key>CFBundleIdentifier</key><string>local.processes.menubar</string>
  <key>CFBundleName</key><string>Processes</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Processes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Done: $PWD/$APP"
