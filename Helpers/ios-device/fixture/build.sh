#!/bin/bash
# Monta o .app do fixture iOS, assina ad-hoc e instala no Simulator ligado.
# Uso: Helpers/ios-device/fixture/build.sh [udid]   (padrão: o Simulator ligado)
set -euo pipefail
cd "$(dirname "$0")"
UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for v in json.load(sys.stdin)["devices"].values() for d in v))')}"
OUT="${OUT:-build}"; APP="$OUT/Fixture.app"
rm -rf "$APP"; mkdir -p "$APP"
swiftc -O -suppress-warnings -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios17.0-simulator \
  -o "$APP/Fixture" main.swift
cp Info.plist "$APP/Info.plist"
codesign --force --sign - "$APP"
xcrun simctl install "$UDID" "$APP"
echo "instalado em $UDID: com.collie.fixture.ios"
