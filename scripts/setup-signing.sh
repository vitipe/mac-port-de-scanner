#!/bin/bash
# Crea, una sola vez, un certificado local para firmar Scanner.
#
# Con firma ad-hoc, macOS identifica la app por el hash de cada compilación y
# olvida el permiso "Acceso total al disco" al recompilar. Firmada con un
# certificado propio, la identifica por el certificado y lo recuerda.
#
# El certificado vive en un llavero aparte (no toca el llavero de inicio de
# sesión) cuya contraseña se guarda junto a él, así compilar no pide nada.
set -euo pipefail

DIR="$HOME/Library/Application Support/com.vhpenas.scanner.signing"
KEYCHAIN="$DIR/signing.keychain-db"
IDENTITY="Scanner Local Signing"

if [[ -f "$KEYCHAIN" ]]; then
    echo "El certificado ya existe en $KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
PASSWORD=$(/usr/bin/openssl rand -hex 24)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# /usr/bin/openssl (LibreSSL) genera un .p12 que `security` importa sin problemas.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
    -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
# Sin esto, codesign mostraría un diálogo pidiendo acceso a la clave.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

printf '%s' "$PASSWORD" > "$DIR/password"
chmod 600 "$DIR/password"
echo "Listo: certificado “${IDENTITY}” en ${KEYCHAIN}"
echo "Desde ahora scripts/build-app.sh firma con él."
