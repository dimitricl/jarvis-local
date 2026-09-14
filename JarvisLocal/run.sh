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

# Build in a temp location first, then copy to /Applications.
# Plus de `with administrator privileges` : si l'ancien bundle (installé jadis en
# admin, root-owned) ou le dossier résiste au simple cp, on replie sur
# ~/Applications — aucun sudo requis dans tous les cas.
if [ -w "/Applications" ] && rm -rf "/Applications/${APP_NAME}.app" 2>/dev/null; then
    APP_BUNDLE="/Applications/${APP_NAME}.app"
else
    APP_BUNDLE="$HOME/Applications/${APP_NAME}.app"
    mkdir -p "$HOME/Applications"
    echo "    /Applications non modifiable sans admin → ${APP_BUNDLE}"
fi
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

# Signature ad-hoc + hardened runtime (la signature Developer ID, elle, se fait en CI release).
codesign -s - --options runtime --entitlements JarvisLocal.entitlements "${TMP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || {
    echo "    (signature ad-hoc impossible, bundle non signé)"
}

rm -rf "${APP_BUNDLE}"
cp -R "${TMP_BUNDLE}" "${APP_BUNDLE}"

open "${APP_BUNDLE}"
