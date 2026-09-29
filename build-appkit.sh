#!/bin/sh
set -eu
cd "$(dirname "$0")"
./scanners/agent-2-5-hybrid/build.sh
mkdir -p dist/FastTree.app/Contents/MacOS dist/FastTree.app/Contents/Resources
clang -O2 -std=c11 -I FastTreeCore/include -c FastTreeCore/src/FastTreeCore.c -o /tmp/fasttree-core-app.o
swiftc -O -I FastTreeCore/include FastTreeAppKit/main.swift /tmp/fasttree-core-app.o -o dist/FastTree.app/Contents/MacOS/FastTree
cp scanners/agent-2-5-hybrid/fasttree-scan.bin dist/FastTree.app/Contents/Resources/fasttree-scan
cat > dist/FastTree.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.fasttree.FastTree</string>
<key>CFBundleName</key><string>FastTree</string>
<key>CFBundleDisplayName</key><string>FastTree</string>
<key>CFBundleExecutable</key><string>FastTree</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$(pwd)/dist/FastTree.app"
