#!/bin/bash
# Builds Resources/collie-helper.apk from Helpers/android-device/helper (no Gradle): aapt2, javac, d8, zipalign, apksigner.
# Needs the Android SDK (ANDROID_HOME, default ~/Library/Android/sdk; latest build-tools and platform) and a JDK
# (JAVA_HOME, else the Android Studio JBR; this Mac has no system JRE). The APK (a few KB) is committed so CI needs none of this.
# The signing key Helpers/android-device/helper.jks is a public debug key, enough for a developer helper: swap it for
# a private one before shipping to end users.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK/build-tools" ] || { echo "no Android SDK at $SDK (set ANDROID_HOME)" >&2; exit 1; }
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
AJ="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)/android.jar"
if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
[ -n "${JAVA_HOME:-}" ] && export PATH="$JAVA_HOME/bin:$PATH"
command -v javac >/dev/null && javac -version >/dev/null 2>&1 || { echo "no JDK (set JAVA_HOME)" >&2; exit 1; }
SRC=Helpers/android-device/helper
KEY=Helpers/android-device/helper.jks
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
if [ ! -f "$KEY" ]; then
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
"$BT/apksigner" sign --ks "$KEY" --ks-pass pass:android --key-pass pass:android --out Resources/collie-helper.apk "$T/a.apk"
echo "ok: Resources/collie-helper.apk ($(wc -c < Resources/collie-helper.apk | tr -d ' ') bytes)"
