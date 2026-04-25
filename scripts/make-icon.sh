#!/usr/bin/env bash
# Generate an AppIcon.appiconset for Orpheus.
#
# Uses App/Resources/AppIcon-source.png as the base when present; falls
# back to a CoreGraphics-rendered placeholder otherwise. Resampled to
# every size macOS expects via sips. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="$ROOT/App/Assets.xcassets/AppIcon.appiconset"
SOURCE="$ROOT/App/Resources/AppIcon-source.png"
mkdir -p "$SET"
mkdir -p "$ROOT/App/Assets.xcassets"

# Top-level catalog Contents.json (required by Xcode for the catalog itself).
cat > "$ROOT/App/Assets.xcassets/Contents.json" <<'EOF'
{
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
EOF

TMP_BASE="$(mktemp -t orpheus-icon-base).png"
trap "rm -f '$TMP_BASE'" EXIT

if [ -f "$SOURCE" ]; then
    echo "▶︎ Using $SOURCE"
    # Upscale to 1024×1024 so every downsize step starts from the same canvas.
    sips -s format png -z 1024 1024 "$SOURCE" --out "$TMP_BASE" >/dev/null
else
    echo "▶︎ No App/Resources/AppIcon-source.png found; rendering placeholder."
    xcrun --toolchain swift swift - "$TMP_BASE" <<'SWIFT'
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments[1]
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// Rounded-square background — macOS Sequoia draws icons as squircles, so
// we provide a slightly rounded square that reads well at any size.
let radius = CGFloat(size) * 0.22
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()

// Diagonal blue gradient — Pandora-ish without copying the brand.
let colors = [
    CGColor(red: 0.27, green: 0.55, blue: 0.97, alpha: 1.0),
    CGColor(red: 0.18, green: 0.34, blue: 0.78, alpha: 1.0),
] as CFArray
let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: CGFloat(size), y: 0),
    options: []
)

// Stylized eighth-note glyph in white. Two filled ellipses (the note heads)
// joined by a curved stem/flag suggesting the "P" in Pianobar.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

// Stem
let stemWidth = CGFloat(size) * 0.06
let stemX = CGFloat(size) * 0.55
let stemTopY = CGFloat(size) * 0.78
let stemBottomY = CGFloat(size) * 0.32
ctx.move(to: CGPoint(x: stemX, y: stemTopY))
ctx.addLine(to: CGPoint(x: stemX + stemWidth, y: stemTopY))
ctx.addLine(to: CGPoint(x: stemX + stemWidth, y: stemBottomY))
ctx.addLine(to: CGPoint(x: stemX, y: stemBottomY))
ctx.closePath()
ctx.fillPath()

// Note head — a tilted ellipse at the bottom of the stem.
let headW = CGFloat(size) * 0.30
let headH = CGFloat(size) * 0.22
let headRect = CGRect(
    x: stemX - headW * 0.55,
    y: stemBottomY - headH * 0.4,
    width: headW,
    height: headH
)
ctx.saveGState()
let centerX = headRect.midX, centerY = headRect.midY
ctx.translateBy(x: centerX, y: centerY)
ctx.rotate(by: -0.35)
ctx.translateBy(x: -centerX, y: -centerY)
ctx.fillEllipse(in: headRect)
ctx.restoreGState()

// Flag at top of the stem — a flowing curve to the right.
ctx.setLineCap(.round)
ctx.setLineWidth(CGFloat(size) * 0.07)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
let flagPath = CGMutablePath()
flagPath.move(to: CGPoint(x: stemX + stemWidth, y: stemTopY))
flagPath.addCurve(
    to: CGPoint(x: stemX + stemWidth + CGFloat(size) * 0.18, y: stemTopY - CGFloat(size) * 0.18),
    control1: CGPoint(x: stemX + stemWidth + CGFloat(size) * 0.20, y: stemTopY - CGFloat(size) * 0.02),
    control2: CGPoint(x: stemX + stemWidth + CGFloat(size) * 0.22, y: stemTopY - CGFloat(size) * 0.10)
)
ctx.addPath(flagPath)
ctx.strokePath()

// Encode to PNG.
guard let cgImage = ctx.makeImage() else { exit(1) }
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))
SWIFT
fi

echo "✓ Base icon rendered at $TMP_BASE"

# Resize to every required entry. macOS app icons need ten files spanning
# 16×16 to 1024×1024 across @1x and @2x scales.
make_size() {
    local px=$1 out=$2
    sips -s format png -z "$px" "$px" "$TMP_BASE" --out "$SET/$out" >/dev/null
}

make_size 16   icon_16x16.png
make_size 32   icon_16x16@2x.png
make_size 32   icon_32x32.png
make_size 64   icon_32x32@2x.png
make_size 128  icon_128x128.png
make_size 256  icon_128x128@2x.png
make_size 256  icon_256x256.png
make_size 512  icon_256x256@2x.png
make_size 512  icon_512x512.png
make_size 1024 icon_512x512@2x.png

cat > "$SET/Contents.json" <<'EOF'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",      "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",   "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",      "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",   "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",    "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png", "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",    "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png", "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",    "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png", "scale" : "2x" }
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
EOF

echo "✓ AppIcon.appiconset written to $SET"
ls "$SET"
