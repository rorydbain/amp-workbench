#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product AmpWorkbench
build_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Amp Workbench.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_dir/AmpWorkbench" "$app/Contents/MacOS/AmpWorkbench"
rm -rf "$app/AmpWorkbench_AmpCore.bundle" "$app/Contents/Resources/AmpWorkbench_AmpCore.bundle"
cp -R "$build_dir/AmpWorkbench_AmpCore.bundle" "$app/Contents/Resources/AmpWorkbench_AmpCore.bundle"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.amp-workbench</string>
<key>CFBundleName</key><string>Amp Workbench</string>
<key>CFBundleDisplayName</key><string>Amp Workbench</string>
<key>CFBundleExecutable</key><string>AmpWorkbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to your Yamaha THR amplifier for wireless preset control.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep "$app"
echo "$app"
