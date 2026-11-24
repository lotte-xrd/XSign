#!/usr/bin/env bash
# Gera os arquivos de teste do leitor de certificados (Tests/CertSmoke).
# Uso: make_fixtures.sh <pasta de saída>
# OPENSSL: OpenSSL 3 (formato novo, AES-256). LEGACY_OPENSSL: opcional, outro
# gerador (no macOS, o LibreSSL de /usr/bin/openssl) para .p12 no formato antigo.
set -euo pipefail
OUT="$1"
OPENSSL="${OPENSSL:-openssl}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
cd "$OUT"

"$OPENSSL" version

# Uma "AC" e o certificado do desenvolvedor assinado por ela, mais um segundo
# certificado sem relação (para o caso de .p12 e perfil trocados).
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj "/CN=Teste WWDR" 2>/dev/null
"$OPENSSL" req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=iPhone Distribution: Teste (ABCDE12345)/OU=ABCDE12345" 2>/dev/null
"$OPENSSL" x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 30 2>/dev/null
"$OPENSSL" x509 -in leaf.pem -outform DER -out leaf.der
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other.pem -days 30 -subj "/CN=iPhone Distribution: Outro (ZZZZZ99999)" 2>/dev/null

p12() { "$OPENSSL" pkcs12 -export -inkey leaf.key -in leaf.pem "$@"; }
p12 -out modern.p12 -passout pass:1                                   # padrão do OpenSSL 3: PBES2/AES-256, MAC SHA-256
p12 -out legacy.p12 -passout pass:1 -legacy                           # RC2-40 + 3DES, MAC SHA-1
p12 -out des3.p12 -passout pass:abc -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
p12 -out aes128-sha512.p12 -passout pass:segredo -keypbe AES-128-CBC -certpbe AES-128-CBC -macalg sha512
p12 -out empty.p12 -passout pass:
p12 -out unicode.p12 -passout "pass:senhá123"
p12 -out chain.p12 -passout pass:1 -certfile ca.pem
p12 -out nomac.p12 -passout pass:1 -nomac
"$OPENSSL" pkcs12 -export -inkey other.key -in other.pem -out other.p12 -passout pass:1
if [ -n "${LEGACY_OPENSSL:-}" ]; then
  "$LEGACY_OPENSSL" version
  "$LEGACY_OPENSSL" pkcs12 -export -inkey leaf.key -in leaf.pem -out libressl.p12 -passout pass:1
else
  cp legacy.p12 libressl.p12
fi
python3 "$HERE/make_ber.py" modern.p12 ber.p12

# Perfil (.mobileprovision): plist assinado em CMS, com o certificado do desenvolvedor.
profile() {
  local name="$1" uuid="$2" cert="$3"
  local b64
  b64=$(base64 < "$cert" | tr -d '\n')
  cat > "$name.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AppIDName</key><string>XSign</string>
  <key>CreationDate</key><date>2026-11-01T00:00:00Z</date>
  <key>DeveloperCertificates</key><array><data>$b64</data></array>
  <key>Entitlements</key><dict><key>application-identifier</key><string>ABCDE12345.*</string></dict>
  <key>ExpirationDate</key><date>2027-11-01T00:00:00Z</date>
  <key>Name</key><string>Perfil de teste</string>
  <key>ProvisionsAllDevices</key><true/>
  <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
  <key>TeamName</key><string>Teste Ltda</string>
  <key>UUID</key><string>$uuid</string>
</dict>
</plist>
PLIST
  "$OPENSSL" cms -sign -binary -nodetach -outform DER -in "$name.plist" -signer ca.pem -inkey ca.key -out "$name.mobileprovision"
}
profile profile 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 leaf.der
"$OPENSSL" x509 -in other.pem -outform DER -out other.der
profile other 11111111-2222-3333-4444-555555555555 other.der
ls -la
