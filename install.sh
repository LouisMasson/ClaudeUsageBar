#!/usr/bin/env bash
# ClaudeUsageBar — one-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/LouisMasson/ClaudeUsageBar/main/install.sh | bash
set -e

REPO="LouisMasson/ClaudeUsageBar"
APP_NAME="ClaudeUsageBar"
INSTALL_DIR="/Applications"

echo "→ Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')

if [ -z "$LATEST" ]; then
  echo "✗ Could not fetch latest version. Check your internet connection."
  exit 1
fi

echo "→ Downloading ${APP_NAME} ${LATEST}..."
DMG_URL="https://github.com/${REPO}/releases/download/${LATEST}/${APP_NAME}-${LATEST#v}.dmg"
TMP_DMG=$(mktemp /tmp/ClaudeUsageBar-XXXXXX.dmg)

curl -fsSL -o "$TMP_DMG" "$DMG_URL"

echo "→ Mounting disk image..."
MOUNT_POINT=$(hdiutil attach "$TMP_DMG" -nobrowse -quiet | tail -1 | awk '{print $NF}')

echo "→ Installing to ${INSTALL_DIR}..."
cp -R "${MOUNT_POINT}/${APP_NAME}.app" "${INSTALL_DIR}/"

echo "→ Removing quarantine flag..."
xattr -rd com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

echo "→ Unmounting..."
hdiutil detach "$MOUNT_POINT" -quiet
rm -f "$TMP_DMG"

echo ""
echo "✓ ${APP_NAME} ${LATEST} installed to ${INSTALL_DIR}/${APP_NAME}.app"
echo "  Open it from /Applications or Spotlight (Cmd+Space → ClaudeUsageBar)"
