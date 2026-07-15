#!/bin/bash
set -e

APP_NAME="ClaudeUsageBar"
BUNDLE_ID="com.louismasson.ClaudeUsageBar"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app/Contents"

echo "==> Building $APP_NAME $VERSION..."
swift build --disable-sandbox -c release

echo "==> Creating .app bundle..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/MacOS/$APP_NAME"

cat > "$APP_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_NAME.app"

echo "==> Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_NAME.app" \
  -ov -format UDZO "${APP_NAME}-${VERSION}.dmg"

echo "==> Done → ${APP_NAME}-${VERSION}.dmg"
