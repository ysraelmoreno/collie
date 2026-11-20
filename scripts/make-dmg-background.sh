#!/bin/bash
# Renders Resources/dmg-background.svg into Resources/dmg-background.tiff (660x420 at 1x and 2x in one file, which is
# what Finder wants for a Retina window background). Run after editing the SVG. DM Mono comes from vendor/fonts
# (scripts/fetch-fonts.sh); without it the caption falls back to Menlo.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
import CoreText
let a = CommandLine.arguments
for f in a.dropFirst(3) { CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: f) as CFURL, .process, nil) }
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("cannot load SVG") }
for scale in [1, 2] {
    let w = 660 * scale, h = 420 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2] + "/bg\(scale == 2 ? "@2x" : "").png"))
}
SWIFT
FONTS=(); for f in vendor/fonts/DMMono-Regular.ttf; do [ -f "$f" ] && FONTS+=("$PWD/$f"); done
[ ${#FONTS[@]} -gt 0 ] || echo "warning: vendor/fonts/DMMono-Regular.ttf missing (scripts/fetch-fonts.sh): caption in Menlo" >&2
swift "$TMP/render.swift" "$PWD/Resources/dmg-background.svg" "$TMP" ${FONTS[@]+"${FONTS[@]}"}
# the 2x PNG must say 144 dpi for tiffutil to pair it with the 1x one
sips -s dpiWidth 144 -s dpiHeight 144 "$TMP/bg@2x.png" >/dev/null
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out Resources/dmg-background.tiff
echo "ok: Resources/dmg-background.tiff"
