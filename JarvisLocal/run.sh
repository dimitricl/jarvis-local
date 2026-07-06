#!/bin/bash
set -e

MODE="${1:-debug}"
APP_NAME="JarvisLocal"
APP_BUNDLE="/Applications/${APP_NAME}.app"

if [ "$MODE" = "--release" ] || [ "$MODE" = "-r" ]; then
    BUILD_DIR=".build/release"
    SWIFT_FLAGS="-c release"
else
    BUILD_DIR=".build/debug"
    SWIFT_FLAGS=""
fi

EXECUTABLE="${BUILD_DIR}/${APP_NAME}"

# Version depuis le dernier tag git, fallback sur Info.plist
GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$GIT_TAG" ]; then
    VERSION="${GIT_TAG#v}"; VERSION="${VERSION#V}"
else
    VERSION=$(grep -A1 CFBundleShortVersionString JarvisLocal/Info.plist | grep string | sed 's/.*<string>//;s/<\/string>//')
fi

echo "==> Building ${APP_NAME} v${VERSION} (${MODE##--})..."
echo "    swift build ${SWIFT_FLAGS}"
swift build $SWIFT_FLAGS

# Kill existing instance if running
killall "${APP_NAME}" 2>/dev/null || true
sleep 0.5

# Build in a temp location first, then copy to /Applications with admin privileges
TMP_BUNDLE="/tmp/${APP_NAME}.app"
rm -rf "${TMP_BUNDLE}"
mkdir -p "${TMP_BUNDLE}/Contents/MacOS" "${TMP_BUNDLE}/Contents/Resources"

cp "${EXECUTABLE}" "${TMP_BUNDLE}/Contents/MacOS/${APP_NAME}"
# Copie les ressources (icône, etc.)
cp -R JarvisLocal/Resources/* "${TMP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
# Injecte la version dans Info.plist
cp JarvisLocal/Info.plist "${TMP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "${TMP_BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "${TMP_BUNDLE}/Contents/Info.plist"

# Install to /Applications with admin privileges (GUI password prompt)
osascript -e "
do shell script \"
  rm -rf '${APP_BUNDLE}'
  cp -R '${TMP_BUNDLE}' '${APP_BUNDLE}'
\" with administrator privileges
" 2>/dev/null

open "${APP_BUNDLE}"
