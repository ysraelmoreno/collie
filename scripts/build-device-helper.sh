#!/bin/bash
# Builds Resources/collie-helper.apk from Helpers/android-device/helper (no Gradle): aapt2, javac, d8, zipalign, apksigner.
# Needs the Android SDK (ANDROID_HOME, default ~/Library/Android/sdk; latest build-tools and platform) and a JDK
# (JAVA_HOME, else the Android Studio JBR; this Mac has no system JRE). The APK (a few KB) is committed so CI needs none of this.
# Signing: see usage() and "Assinatura" in Helpers/android-device/README.md. Passwords only travel by environment
# (keytool -storepass:env, apksigner env:), never as a command-line argument nor in the log.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
DEBUG_KEY=Helpers/android-device/helper.jks
KC_SERVICE=collie-helper-keystore

usage() {
  cat <<EOF
uso: scripts/build-device-helper.sh [--release]
     scripts/build-device-helper.sh --genkey <caminho fora do repo>
     scripts/build-device-helper.sh --help

Gera Resources/collie-helper.apk. Chave de assinatura:
  COLLIE_HELPER_KEYSTORE   caminho do keystore privado (sem ela: chave DEBUG pública do repo, com aviso)
  COLLIE_HELPER_KEY_ALIAS  alias da chave (padrão collie-helper)
  COLLIE_HELPER_STOREPASS  senha; sem ela, no macOS, vem do Keychain (item genérico '$KC_SERVICE')
  --release                recusa a chave debug: exige COLLIE_HELPER_KEYSTORE
  --genkey <caminho>       cria um keystore privado (RSA 4096, 36500 dias, 0600) fora do repositório;
                           não sobrescreve um existente. Senha: COLLIE_HELPER_STOREPASS ou digitada no keytool.
A senha nunca vai por argumento de linha de comando.
EOF
}

find_jdk() {
  if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  fi
  [ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
  command -v "$1" >/dev/null || { echo "no JDK (set JAVA_HOME)" >&2; exit 1; }
}

# Exit 0 when $1 (absolute, physical) is inside this checkout or the main checkout it hangs off (worktrees live inside it).
inside_repo() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  for r in "$ROOT" ${common:+"$(cd "$(dirname "$common")" && pwd -P)"}; do
    case "$1/" in "$r"/*) return 0 ;; esac
  done
  return 1
}

genkey() {
  local p="${1:-}"
  [ -n "$p" ] || { echo "--genkey precisa de um caminho" >&2; exit 2; }
  local dir; dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { echo "pasta não existe: $(dirname "$p")" >&2; exit 1; }
  local abs="$dir/$(basename "$p")"
  if inside_repo "$abs"; then echo "recusado: $abs está dentro do repositório; a chave privada fica fora dele" >&2; exit 1; fi
  if [ -e "$abs" ]; then echo "recusado: $abs já existe; não sobrescrevo um keystore" >&2; exit 1; fi
  find_jdk keytool
  local alias="${COLLIE_HELPER_KEY_ALIAS:-collie-helper}"
  local pass=()
  [ -n "${COLLIE_HELPER_STOREPASS:-}" ] && pass=(-storepass:env COLLIE_HELPER_STOREPASS)
  (umask 077; keytool -genkeypair -keystore "$abs" -storetype PKCS12 ${pass[@]+"${pass[@]}"} -alias "$alias" \
    -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=collie-helper")
  chmod 0600 "$abs"
  cat <<EOF
ok: $abs (alias $alias, permissão 0600)
Guarde a senha no Keychain (o security pede a senha; não a passe na linha de comando):
  security add-generic-password -s $KC_SERVICE -a "\$USER" -w
Depois:
  COLLIE_HELPER_KEYSTORE="$abs" scripts/build-device-helper.sh --release
EOF
  exit 0
}

RELEASE=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --genkey) genkey "${2:-}" ;;
  --release) RELEASE=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

# Key choice before any SDK or JDK lookup, so refusals need neither.
if [ -n "${COLLIE_HELPER_KEYSTORE:-}" ]; then
  KEY="$COLLIE_HELPER_KEYSTORE"
  [ -f "$KEY" ] || { echo "keystore não encontrado: $KEY" >&2; exit 1; }
  ALIAS="${COLLIE_HELPER_KEY_ALIAS:-collie-helper}"
  if [ -z "${COLLIE_HELPER_STOREPASS:-}" ] && [ "$(uname)" = Darwin ]; then
    COLLIE_HELPER_STOREPASS="$(security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null)" || true
  fi
  [ -n "${COLLIE_HELPER_STOREPASS:-}" ] || {
    echo "sem senha: defina COLLIE_HELPER_STOREPASS ou guarde-a no Keychain (security add-generic-password -s $KC_SERVICE -a \"\$USER\" -w)" >&2; exit 1; }
else
  if [ "$RELEASE" = 1 ]; then
    echo "recusado: --release não assina com a chave DEBUG pública. Gere uma privada:" >&2
    echo "  scripts/build-device-helper.sh --genkey ~/.collie/collie-helper.p12" >&2
    echo "e rode com COLLIE_HELPER_KEYSTORE apontando para ela." >&2
    exit 1
  fi
  echo "AVISO: chave DEBUG pública, só para desenvolvimento; não distribua este APK" >&2
  KEY="$DEBUG_KEY"; ALIAS=collie-helper; COLLIE_HELPER_STOREPASS=android
fi
export COLLIE_HELPER_STOREPASS

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK/build-tools" ] || { echo "no Android SDK at $SDK (set ANDROID_HOME)" >&2; exit 1; }
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
AJ="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)/android.jar"
find_jdk javac
javac -version >/dev/null 2>&1 || { echo "no JDK (set JAVA_HOME)" >&2; exit 1; }
SRC=Helpers/android-device/helper
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if [ "$KEY" = "$DEBUG_KEY" ] && [ ! -f "$KEY" ]; then
  keytool -genkeypair -keystore "$KEY" -storepass android -keypass android -alias collie-helper -keyalg RSA -keysize 2048 \
    -validity 36500 -dname "CN=collie-helper (debug)" >/dev/null
fi
"$BT/aapt2" compile --dir "$SRC/res" -o "$T/res.zip"
"$BT/aapt2" link -I "$AJ" --manifest "$SRC/AndroidManifest.xml" -o "$T/base.apk" "$T/res.zip"
mkdir "$T/cls"
javac -source 8 -target 8 -Xlint:-options -cp "$AJ" -d "$T/cls" $(find "$SRC/src" -name '*.java')
"$BT/d8" --min-api 26 --lib "$AJ" --output "$T" $(find "$T/cls" -name '*.class')
cp "$T/base.apk" "$T/u.apk"; (cd "$T" && zip -q u.apk classes.dex)
"$BT/zipalign" -f 4 "$T/u.apk" "$T/a.apk"
mkdir -p Resources
"$BT/apksigner" sign --ks "$KEY" --ks-key-alias "$ALIAS" --ks-pass env:COLLIE_HELPER_STOREPASS --key-pass env:COLLIE_HELPER_STOREPASS \
  --out Resources/collie-helper.apk "$T/a.apk"
echo "ok: Resources/collie-helper.apk ($(wc -c < Resources/collie-helper.apk | tr -d ' ') bytes)"
