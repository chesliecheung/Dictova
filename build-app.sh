#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
cd "$ROOT_DIR"

swift build -c release --arch arm64 --arch x86_64

APP="$ROOT_DIR/dist/Dictova.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Dictova" "$APP/Contents/MacOS/Dictova"
cp -R ".build/release/Dictova_Dictova.bundle" "$APP/Contents/Resources/"

ICONSET="$ROOT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16     "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT_DIR/Assets/AppIcon-master.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>Dictova</string>
    <key>CFBundleExecutable</key><string>Dictova</string>
    <key>CFBundleIdentifier</key><string>local.dictova.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Dictova</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.6.2</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>MDict Dictionary</string>
        <key>CFBundleTypeExtensions</key><array><string>mdx</string><string>mdd</string><string>css</string></array>
        <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict></array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "$APP"
