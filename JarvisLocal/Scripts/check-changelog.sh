#!/bin/sh
# Vérifie localement (AVANT de tagger) ce que le workflow changelog-guard.yml
# vérifiera après le push : évite un tag cassé déjà publié.
# Usage : ./Scripts/check-changelog.sh vX.Y.Z   (depuis JarvisLocal/)
#     ou : sh JarvisLocal/Scripts/check-changelog.sh vX.Y.Z  (depuis la racine)
set -eu

TAG="${1:?usage: check-changelog.sh vX.Y.Z}"
VER="$(printf '%s' "$TAG" | sed 's/^v//')"

# Résout les deux chemins quel que soit le cwd d'appel (racine ou JarvisLocal/).
if [ -f "CHANGELOG.md" ] && [ -f "JarvisLocal/CHANGELOG.md" ]; then
  ROOT_CHANGELOG="CHANGELOG.md"
  SWIFT_CHANGELOG="JarvisLocal/CHANGELOG.md"
elif [ -f "../CHANGELOG.md" ] && [ -f "CHANGELOG.md" ]; then
  ROOT_CHANGELOG="../CHANGELOG.md"
  SWIFT_CHANGELOG="CHANGELOG.md"
else
  echo "check-changelog.sh : CHANGELOG.md introuvable (lance depuis la racine ou JarvisLocal/)"
  exit 1
fi

FAIL=0
if ! grep -qE "^## (\\[?v?)?${VER}(\\]?)?([[:space:]]|\\(|-|$)" "$ROOT_CHANGELOG"; then
  echo "Manquant dans $ROOT_CHANGELOG : $VER"
  FAIL=1
fi
if ! grep -qE "^## (\\[?v?)?${VER}(\\]?)?([[:space:]]|-|$)" "$SWIFT_CHANGELOG"; then
  echo "Manquant dans $SWIFT_CHANGELOG : $VER"
  FAIL=1
fi
if [ "$FAIL" = 1 ]; then exit 1; fi
echo "OK : $VER documenté aux deux endroits."
