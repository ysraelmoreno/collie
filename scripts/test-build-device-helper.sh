#!/bin/bash
# Checks scripts/build-device-helper.sh refusals without SDK or JDK (ANDROID_HOME points nowhere).
set -euo pipefail
cd "$(dirname "$0")/.."
S=scripts/build-device-helper.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ANDROID_HOME="$T/no-sdk" JAVA_HOME="$T/no-jdk"
unset COLLIE_HELPER_KEYSTORE COLLIE_HELPER_STOREPASS
fail() { echo "FAIL: $*" >&2; exit 1; }
$S --help | grep -q -- --genkey || fail "--help sem --genkey"
set +e
$S --release 2>"$T/e"; rc=$?
[ $rc = 1 ] && grep -q -- --genkey "$T/e" || fail "--release com chave debug: rc=$rc"
$S 2>"$T/e"; grep -q "AVISO: chave DEBUG pública" "$T/e" || fail "sem aviso da chave debug"
$S --genkey Helpers/android-device/x.p12 2>"$T/e"; rc=$?
[ $rc = 1 ] && grep -q "dentro do repositório" "$T/e" || fail "--genkey dentro do repo: rc=$rc"
touch "$T/k.p12"; $S --genkey "$T/k.p12" 2>"$T/e"; rc=$?
[ $rc = 1 ] && grep -q "já existe" "$T/e" || fail "--genkey sobrescreveu: rc=$rc"
COLLIE_HELPER_KEYSTORE="$T/nope.p12" $S --release 2>"$T/e"; rc=$?
[ $rc = 1 ] && grep -q "não encontrado" "$T/e" || fail "keystore ausente: rc=$rc"
echo ok
