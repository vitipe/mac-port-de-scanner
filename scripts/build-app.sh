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
codesign --force --sign - "$APP"
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Scanner.app
    cp -R "$APP" ~/Applications/
    echo "Instalado en ~/Applications/Scanner.app"
fi
