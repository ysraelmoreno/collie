#!/bin/bash
# Cria a identidade autoassinada "Collie Local" (code signing) no keychain de login. Idempotente.
# Com ela o bundle-app.sh assina o Collie.app sempre com a mesma identidade e o macOS (TCC) mantém as permissões
# concedidas (Documentos, Acesso Total ao Disco) entre rebuilds. Rode uma vez; altera o keychain e a confiança do usuário.
set -euo pipefail
ID="${COLLIE_SIGN_IDENTITY:-Collie Local}"
KC="$HOME/Library/Keychains/login.keychain-db"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# saída em variável: grep -q fechando o pipe faria o pipefail acusar falha num acerto
valid="$(security find-identity -v -p codesigning || true)"
if grep -qF "\"$ID\"" <<<"$valid"; then echo "ok: identidade \"$ID\" já existe"; exit 0; fi

certs="$(security find-certificate -c "$ID" -a -p "$KC" 2>/dev/null || true)"
n="$(grep -c 'BEGIN CERTIFICATE' <<<"$certs" || true)"
if [ "$n" -gt 1 ]; then
  echo "erro: $n certificados \"$ID\" no keychain de login; remova os extras no Acesso às Chaves e rode de novo" >&2; exit 1
elif [ "$n" -eq 1 ]; then
  # execução anterior importou mas a confiança falhou/foi cancelada: só refaz a confiança, sem importar de novo
  echo "certificado \"$ID\" já importado mas sem confiança; refazendo só a confiança."
  printf '%s\n' "$certs" > "$T/cert.pem"
else
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
  security import "$T/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign
  echo "Aviso: no primeiro build o macOS pode pedir acesso do codesign à chave; escolha \"Sempre Permitir\"."
fi
echo "O macOS vai pedir sua senha para confiar no certificado (code signing)."
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem"
valid="$(security find-identity -v -p codesigning || true)"
grep -F "\"$ID\"" <<<"$valid" || { echo "erro: identidade \"$ID\" não ficou válida" >&2; exit 1; }
echo "ok: identidade \"$ID\" pronta. Rode scripts/bundle-app.sh."
