#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/MacDash.app"
INSTALL_DIR="${HOME}/Applications"

echo "==> Building MacDash.app..."
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"
swiftc -O "${SCRIPT_DIR}/src/main.swift" -o "${APP_DIR}/Contents/MacOS/MacDash"

echo "==> Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/MacDash.app"
cp -R "${APP_DIR}" "${INSTALL_DIR}/"

echo "==> Registering login item (startup)..."
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${INSTALL_DIR}/MacDash.app\", hidden:false, name:\"MacDash\"}" 2>&1 || true

echo "==> Launching..."
killall MacDash 2>/dev/null || true
open -a "${INSTALL_DIR}/MacDash.app"

echo "==> Done! MacDash is running in your menu bar."
