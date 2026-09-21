#!/bin/sh
# Monta el DMG de distribución: VerticalRecord.app + enlace a /Applications.
#
#   ./release.sh 0.1.0            -> dist/VerticalRecord-0.1.0.dmg
#
# Si hay un certificado «Developer ID Application» y un perfil de notarytool
# en NOTARY_PROFILE, además notariza y grapa el DMG; si no, el DMG funciona
# igual pero macOS pedirá «Abrir de todos modos» la primera vez (Gatekeeper).
set -eu
cd "$(dirname "$0")"

VERSION="${1:?uso: ./release.sh <versión>}"
export VERSION
./build.sh

DIST=dist
STAGE="$DIST/stage"
DMG="$DIST/VerticalRecord-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R VerticalRecord.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "VerticalRecord" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ] && codesign -dv VerticalRecord.app 2>&1 | grep -q "Developer ID"; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "notarizado"
else
    echo "sin notarizar: los usuarios tendrán que permitir la app en Ajustes > Privacidad y seguridad"
fi

shasum -a 256 "$DMG"
echo "listo: $DMG"
