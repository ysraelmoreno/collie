#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns (iconset 16..512 @1x/@2x + iconutil). Run after editing the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."
SVG="$PWD/Resources/AppIcon.svg"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("cannot load SVG") }
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2] + "/" + name))
    }
}
SWIFT
swift "$TMP/render.swift" "$SVG" "$SET"
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "ok: Resources/AppIcon.icns"
