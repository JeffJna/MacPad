#!/bin/sh
# Regenerates resources/AppIcon.icns (macOS) and the iOS app icon from tools/make-icon.swift.
# The .icns file is checked in, so this only needs to run when the artwork changes.
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift tools/make-icon.swift "$work/icon-1024.png"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	double=$((size * 2))
	sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
	sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p resources
iconutil -c icns "$iconset" -o resources/AppIcon.icns
cp "$work/icon-1024.png" resources/AppIcon.png
echo "Wrote resources/AppIcon.icns"

ios_icon=ios/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ios_icon"
swift tools/make-icon.swift "$ios_icon/AppIcon.png" --ios
echo "Wrote $ios_icon/AppIcon.png"
