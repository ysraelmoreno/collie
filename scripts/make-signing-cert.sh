#!/bin/bash
# Cria a identidade autoassinada "Collie Local" (code signing) no keychain de login. Idempotente.
# Com ela o bundle-app.sh assina o Collie.app sempre com a mesma identidade e o macOS (TCC) mantém as permissões
# concedidas (Documentos, Acesso Total ao Disco) entre rebuilds. Rode uma vez; altera o keychain e a confiança do usuário.
set -euo pipefail
ID="${COLLIE_SIGN_IDENTITY:-Collie Local}"
if security find-identity -v -p codesigning | grep -qF "\"$ID\""; then
  echo "ok: identidade \"$ID\" já existe"; exit 0
fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS="collie-$$-$RANDOM"
cat > "$T/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/openssl.cnf" -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
# OpenSSL 3 cifra o .p12 com algoritmos que o macOS não importa: -legacy; LibreSSL (macOS) não conhece a flag
if ! openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$PASS" 2>/dev/null; then
  openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$PASS"
fi
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign
echo "O macOS vai pedir sua senha para confiar no certificado (code signing)."
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem"
security find-identity -v -p codesigning | grep -F "\"$ID\"" || { echo "erro: identidade \"$ID\" não ficou válida" >&2; exit 1; }
echo "ok: identidade \"$ID\" criada. Rode scripts/bundle-app.sh."
