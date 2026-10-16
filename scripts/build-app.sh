#!/bin/bash
# Compila Scanner en release y arma build/Scanner.app.
# Uso: scripts/build-app.sh [--install]   (--install lo copia a ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Scanner.app

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# Ícono: solo se regenera si cambió el script que lo dibuja.
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
    mkdir -p build
    swiftc -O scripts/make-icon.swift -o build/make-icon
    build/make-icon build/icon-1024.png
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Scanner" "$APP/Contents/MacOS/Scanner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Firma: con el certificado local si existe (ver scripts/setup-signing.sh), así
# macOS recuerda los permisos entre compilaciones; si no, ad-hoc.
SIGNING_DIR="$HOME/Library/Application Support/com.vhpenas.scanner.signing"
if [[ -f "$SIGNING_DIR/signing.keychain-db" ]]; then
    security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$SIGNING_DIR/signing.keychain-db"
    codesign --force --timestamp=none --sign "Scanner Local Signing" \
        --keychain "$SIGNING_DIR/signing.keychain-db" "$APP"
else
    codesign --force --sign - "$APP"
    echo "Aviso: firma ad-hoc. Corré scripts/setup-signing.sh una vez para que macOS"
    echo "recuerde el permiso de Acceso total al disco entre compilaciones."
fi
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Scanner.app
    cp -R "$APP" ~/Applications/
    # Registra la app y su servicio "Analizar con Scanner" del menú de Finder.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f ~/Applications/Scanner.app
    /System/Library/CoreServices/pbs -update
    echo "Instalado en ~/Applications/Scanner.app"
fi
