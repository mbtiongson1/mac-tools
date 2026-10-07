#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/ToggleSleep.app"
INSTALL_DIR="${HOME}/Applications"

echo "==> Building ToggleSleep.app..."
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"
swiftc -O "${SCRIPT_DIR}/src/main.swift" -o "${APP_DIR}/Contents/MacOS/ToggleSleep"

echo "==> Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/ToggleSleep.app"
cp -R "${APP_DIR}" "${INSTALL_DIR}/"

echo "==> Registering login item (startup)..."
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${INSTALL_DIR}/ToggleSleep.app\", hidden:false, name:\"ToggleSleep\"}" 2>&1 || true

echo "==> Launching..."
killall ToggleSleep 2>/dev/null || true
open -a "${INSTALL_DIR}/ToggleSleep.app"

echo "==> Done! ToggleSleep is running and installed."
