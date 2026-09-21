#!/bin/sh
# Compila con SwiftPM, monta VerticalRecord.app y lo firma.
#
#   ./build.sh          compila (release) y monta el bundle
#   ./build.sh run      además lo abre
#
# Firma con el certificado «Apple Development» si lo hay; si no, ad hoc. Con
# certificado, los permisos de cámara/micro/pantalla sobreviven a recompilar;
# con ad hoc, macOS los vuelve a pedir en cada build.
set -eu
cd "$(dirname "$0")"

APP=VerticalRecord.app
BIN=.build/release/VerticalRecord
ID=com.elrincondeisma.verticalrecord

swift build -c release 2>&1 | grep -vE "^\[|^Compiling|^Build complete|^Emitting|^Linking|^Write" || true
[ -x "$BIN" ] || { echo "no se ha compilado $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VerticalRecord"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VerticalRecord</string>
    <key>CFBundleDisplayName</key><string>VerticalRecord</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleExecutable</key><string>VerticalRecord</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-1.1.1}</string>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHumanReadableCopyright</key><string>© Ismael Catalá · MIT</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>Para grabar tu cámara en el Short.</string>
    <key>NSMicrophoneUsageDescription</key><string>Para grabar tu voz en el Short.</string>
</dict>
</plist>
PLIST

# Developer ID (distribución) > Apple Development (esta máquina) > ad hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "firmado con: $IDENTITY"
else
    codesign --force --deep --sign - "$APP"
    echo "firmado ad hoc (los permisos se pedirán en cada build)"
fi

echo "listo: $PWD/$APP"
[ "${1:-}" = "run" ] && open "$APP"
exit 0
