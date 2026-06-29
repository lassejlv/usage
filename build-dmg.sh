#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="Usage"
APP_DISPLAY_NAME="Usage"
BUNDLE_IDENTIFIER="com.local.usage"
VERSION="0.1.0"
MIN_MACOS_VERSION="13.0"

BUILD_DIR=".build"
APP_BUNDLE="${BUILD_DIR}/${APP_DISPLAY_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
DMG_ROOT="${BUILD_DIR}/dmg-root"
DMG_PATH="${BUILD_DIR}/${APP_DISPLAY_NAME}.dmg"
VOLUME_NAME="${APP_DISPLAY_NAME}"

if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_BLUE=""; C_CYAN=""
fi

log_step()  { printf "%b=>%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$1"; }
log_ok()    { printf "%b✓%b %s\n"  "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1"; }
log_error() { printf "%b✗%b %s\n"  "${C_RED}${C_BOLD}"  "${C_RESET}" "$1" >&2; }

require_command() {
    if ! command -v "$1" > /dev/null 2>&1; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

require_command swift
require_command codesign
require_command hdiutil

printf "%b=== Building %s DMG ===%b\n" "${C_BOLD}${C_BLUE}" "${APP_DISPLAY_NAME}" "${C_RESET}"

log_step "Building ${APP_DISPLAY_NAME} in release mode..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    log_error "Built binary not found at ${BIN_PATH}"
    exit 1
fi

log_step "Assembling ${APP_DISPLAY_NAME}.app..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_DISPLAY_NAME}"

# Copy SwiftPM resource bundles into Resources/ so Bundle.module resolves at runtime.
BIN_DIR="$(dirname "${BIN_PATH}")"
for bundle in "${BIN_DIR}"/*.bundle; do
    [ -e "${bundle}" ] || continue
    rm -rf "${RESOURCES_DIR}/$(basename "${bundle}")"
    cp -R "${bundle}" "${RESOURCES_DIR}/"
done

# App icon (the Dock/Finder icon, distinct from the menu bar tray glyph).
if [ -f "${SCRIPT_DIR}/icon/Usage.icns" ]; then
    cp "${SCRIPT_DIR}/icon/Usage.icns" "${RESOURCES_DIR}/Usage.icns"
fi

log_step "Writing Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>Usage</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

log_step "Signing app bundle with ad-hoc identity..."
codesign --force --deep --sign - "${APP_BUNDLE}"

log_step "Preparing DMG contents..."
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_BUNDLE}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"

log_step "Creating ${DMG_PATH}..."
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

log_ok "DMG created at ${DMG_PATH}"
