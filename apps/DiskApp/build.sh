#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/DiskApp.app"
INSTALL_DIR="${HOME}/Applications"

echo "==> Building DiskApp.app..."
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"
swiftc -O "${SCRIPT_DIR}/src/main.swift" -o "${APP_DIR}/Contents/MacOS/DiskApp"

echo "==> Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/DiskApp.app"
cp -R "${APP_DIR}" "${INSTALL_DIR}/"

echo "==> Done! DiskApp is built and installed at ${INSTALL_DIR}/DiskApp.app"
