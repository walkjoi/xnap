// Renders the Xnap app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the 1024×1024 master in Core Graphics coordinates (origin bottom-left).
func drawIcon(in ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Tile with soft drop shadow and a blue → violet gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x4B6BFB))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x3FA1FF), color(0x5B5CF6), color(0x7B3FE4)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A long page that runs past the bottom of the tile: "more than fits on screen".
    let page = CGRect(x: 322, y: 60, width: 380, height: 730)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x1A1060, 0.45))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: 38, cornerHeight: 38, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Page content: a headline, an image block and text lines.
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                           cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    bar(372, 712, 220, 30, color(0x2C2C54))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 372, y: 540, width: 280, height: 136),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(color(0xCFE3FF))
    ctx.fillPath()
    for (i, w) in [280, 250, 270, 200, 262, 236].enumerated() {
        bar(372, 490 - CGFloat(i) * 46, CGFloat(w), 20, color(0xD9DCE6))
    }

    // Scroll chevrons near the bottom of the page.
    ctx.setStrokeColor(color(0x5B5CF6))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for dy in [0.0, 44.0] {
        ctx.move(to: CGPoint(x: 472, y: 190 - dy + 36))
        ctx.addLine(to: CGPoint(x: 512, y: 190 - dy))
        ctx.addLine(to: CGPoint(x: 552, y: 190 - dy + 36))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Viewfinder corners in warm yellow.
    let frame = CGRect(x: 236, y: 250, width: 552, height: 600)
    let arm: CGFloat = 118
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x1A1060, 0.35))
    ctx.setStrokeColor(color(0xFFD043))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (p, sx, sy) in corners {
        ctx.move(to: CGPoint(x: p.x + sx * arm, y: p.y))
        ctx.addLine(to: p)
        ctx.addLine(to: CGPoint(x: p.x, y: p.y + sy * arm))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    try render(size: size)!.write(to: output.appendingPathComponent("\(name).png"))
}
print("Wrote \(output.path)")
