#!/bin/zsh
# Builds build.noindex/Nook.app (".noindex" keeps Spotlight from listing a second Nook) (ad-hoc signed). No Xcode project, no dependencies.
set -euo pipefail
cd "${0:A:h}"
# SwiftUI's @State macro plugin ships with Xcode, not the Command Line Tools.
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
app=build.noindex/Nook.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Nook</string>
	<key>CFBundleIdentifier</key><string>dev.lorik.nook</string>
	<key>CFBundleName</key><string>Nook</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>CFBundleDisplayName</key><string>Nook</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSAppleEventsUsageDescription</key><string>Nook reads your browser's tabs to show the website and thumbnail of the video you're playing, and brings up the terminal tab an agent runs in.</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

xcrun clang -O2 -dynamiclib -fobjc-arc -framework Foundation Helper/NookMedia.m -o "$app/Contents/Resources/NookMedia.dylib"
cp Helper/stream.pl Resources/AppIcon.icns "$app/Contents/Resources/"
xcrun swiftc -O -wmo -target arm64-apple-macos14.0 -swift-version 5 Sources/*.swift -o "$app/Contents/MacOS/Nook"
codesign -s - --force --deep "$app" >/dev/null
echo "Built $app"
