#!/bin/sh
set -eu
cd "$(dirname "$0")"
./scanners/agent-2-5-hybrid/build.sh
mkdir -p dist/FastTree.app/Contents/MacOS dist/FastTree.app/Contents/Resources
clang -target arm64-apple-macos13.0 -O2 -std=c11 -I FastTreeCore/include -c FastTreeCore/src/FastTreeCore.c -o /tmp/fasttree-core-app.o
swiftc -target arm64-apple-macos13.0 -O -I FastTreeCore/include FastTreeAppKit/main.swift /tmp/fasttree-core-app.o -o dist/FastTree.app/Contents/MacOS/FastTree
cp scanners/agent-2-5-hybrid/fasttree-scan.bin dist/FastTree.app/Contents/Resources/fasttree-scan
cp Resources/FastTree.icns dist/FastTree.app/Contents/Resources/FastTree.icns
cat > dist/FastTree.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.fasttree.FastTree</string>
<key>CFBundleName</key><string>FastTree</string>
<key>CFBundleDisplayName</key><string>FastTree</string>
<key>CFBundleExecutable</key><string>FastTree</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>FastTree</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$(pwd)/dist/FastTree.app"
