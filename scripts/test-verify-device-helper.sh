#!/bin/bash
# Checks scripts/verify-device-helper.sh with a fake apksigner on PATH (no SDK, no JDK).
set -euo pipefail
cd "$(dirname "$0")/.."
S=scripts/verify-device-helper.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
KNOWN=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
mkdir -p "$T/bin"
cat > "$T/bin/apksigner" <<STUB
#!/bin/bash
echo "Signer #1 certificate DN: CN=stub"
echo "Signer #1 certificate SHA-256 digest: $KNOWN"
echo "Signer #1 certificate SHA-1 digest: 0011223344556677889900112233445566778899"
STUB
chmod +x "$T/bin/apksigner"
touch "$T/x.apk"
export ANDROID_HOME="$T/no-sdk" HOME="$T" JAVA_HOME="$T/no-jdk"
STUBPATH="$T/bin:/usr/bin:/bin"
$S --help | grep -q -- --print || fail "--help sem --print"
echo "$KNOWN" > "$T/pin"
PATH="$STUBPATH" COLLIE_HELPER_PIN="$T/pin" $S "$T/x.apk" >/dev/null || fail "pino igual não passou"
[ "$(PATH="$STUBPATH" $S --print "$T/x.apk")" = "$KNOWN" ] || fail "--print não imprimiu o SHA-256"
set +e
echo ffff > "$T/pin"
PATH="$STUBPATH" COLLIE_HELPER_PIN="$T/pin" $S "$T/x.apk" 2>"$T/e"; rc=$?
[ $rc = 1 ] && grep -q "outra chave ou com a chave debug" "$T/e" && grep -q "$KNOWN" "$T/e" || fail "pino diferente: rc=$rc"
PATH="$STUBPATH" COLLIE_HELPER_PIN="$T/none" $S "$T/x.apk" 2>"$T/e"; rc=$?
[ $rc = 2 ] && grep -q "pino" "$T/e" || fail "sem pino: rc=$rc"
PATH=/usr/bin:/bin COLLIE_HELPER_PIN="$T/pin" $S "$T/x.apk" 2>"$T/e"; rc=$?
[ $rc = 2 ] && grep -q "apksigner não encontrado" "$T/e" || fail "sem apksigner: rc=$rc"
set -e
grep -q 'scripts/verify-device-helper.sh' scripts/release.sh || fail "release.sh não chama verify-device-helper.sh"
echo ok
