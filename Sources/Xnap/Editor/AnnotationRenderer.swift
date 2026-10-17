import AppKit

/// Draws annotations with Core Graphics — shared by the on-screen canvas and the export.
///
/// The context must be in image-pixel units with a top-left origin (y down), and the
/// current `NSGraphicsContext` must wrap it with `flipped: true` so text draws upright.
enum AnnotationRenderer {
    static func draw(_ a: Annotation, in ctx: CGContext, pixelator: Pixelator, shadowScale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor

        func dropShadow() {
            let s = max(1, a.lineWidth * 0.35) * shadowScale
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.6), blur: s * 1.6,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
        }

        switch a.shape {
        case .arrow(let from, let to):
            dropShadow()
            ctx.setFillColor(color)
            ctx.addPath(arrowPath(from: from, to: to, width: a.lineWidth))
            ctx.fillPath()

        case .line(let from, let to):
            dropShadow()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .rectangle(let r):
            dropShadow()
            let radius = min(a.lineWidth * 0.9, min(r.width, r.height) / 2)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            if a.filled {
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(a.lineWidth)
                ctx.strokePath()
            }

        case .ellipse(let r):
            dropShadow()
            ctx.addEllipse(in: r)
            if a.filled {
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(a.lineWidth)
                ctx.strokePath()
            }

        case .pen(let points):
            dropShadow()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(points))
            ctx.strokePath()

        case .highlighter(let points):
            // Multiply keeps the text underneath readable, like a real marker.
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.cgColor.copy(alpha: 0.42) ?? color)
            ctx.setLineWidth(a.lineWidth * 3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(smoothPath(points))
            ctx.strokePath()

        case .text(let origin, let string):
            let attributes = TextMetrics.attributes(font: a.textFont, color: a.color.nsColor)
            let size = TextMetrics.size(of: string, font: a.textFont)
            (string as NSString).draw(with: CGRect(origin: origin, size: CGSize(width: size.width + 4, height: size.height)),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: attributes)

        case .counter(let center, let number):
            let r = a.counterRadius
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            dropShadow()
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(max(1, r * 0.1))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.05, dy: r * 0.05))
            let font = NSFont.systemFont(ofSize: a.fontSize, weight: .bold)
            let text = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: a.color.contrasting.nsColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)

        case .pixelate(let r):
            guard let (image, snapped) = pixelator.pixelated(r) else { return }
            ctx.clip(to: r)
            ctx.interpolationQuality = .none
            drawImage(image, in: snapped, ctx: ctx)
        }
    }

    /// Draws a `CGImage` upright into a flipped (y-down) context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// A tapered arrow with a swept-back head, as one fillable outline.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let path = CGMutablePath()
        guard length > 1 else { return path }
        let head = min(length * 0.65, max(w * 4.5, 10))
        let wing = head * 0.52
        let base = length - head
        let shaftEnd = w * 0.62, shaftStart = w * 0.22
        let points = [
            CGPoint(x: 0, y: -shaftStart), CGPoint(x: base, y: -shaftEnd),
            CGPoint(x: base - head * 0.18, y: -wing), CGPoint(x: length, y: 0),
            CGPoint(x: base - head * 0.18, y: wing), CGPoint(x: base, y: shaftEnd),
            CGPoint(x: 0, y: shaftStart),
        ]
        let transform = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: atan2(dy, dx))
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }

    /// Quadratic smoothing through the midpoints of a freehand stroke.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            if points.count == 1 { path.addLine(to: first) }
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Flattens the image and its annotations into a new image.
    static func render(image: CGImage, annotations: [Annotation], pixelator: Pixelator) -> CGImage? {
        guard !annotations.isEmpty else { return image }
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for a in annotations { draw(a, in: ctx, pixelator: pixelator, shadowScale: 1) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Mosaic redaction. Averages blocks of the *original* pixels, so the text underneath
/// is destroyed rather than merely blurred.
final class Pixelator {
    let image: CGImage
    let blockSize: CGFloat
    /// Keyed by the snapped region, which is always whole pixels. A struct of four integers
    /// hashes without allocating, unlike the interpolated string this used to build on every
    /// single draw of every mosaic.
    private struct Region: Hashable {
        let x: Int, y: Int, width: Int, height: Int
        init(_ r: CGRect) {
            x = Int(r.minX); y = Int(r.minY); width = Int(r.width); height = Int(r.height)
        }
    }

    private var cache: [Region: CGImage] = [:]

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        blockSize = max(8, (10 * scale).rounded())
    }

    /// The mosaic for `rect`, snapped to the block grid so neighbouring regions line up.
    func pixelated(_ rect: CGRect) -> (CGImage, CGRect)? {
        let b = blockSize
        let snapped = CGRect(x: floor(rect.minX / b) * b, y: floor(rect.minY / b) * b,
                             width: 0, height: 0)
        let full = CGRect(x: snapped.minX, y: snapped.minY,
                          width: ceil(rect.maxX / b) * b - snapped.minX,
                          height: ceil(rect.maxY / b) * b - snapped.minY)
            .intersection(CGRect(origin: .zero, size: image.size))
        guard full.width >= 1, full.height >= 1 else { return nil }
        let key = Region(full)
        if let cached = cache[key] { return (cached, full) }
        guard let crop = image.cropping(to: full) else { return nil }
        let w = max(1, Int(ceil(full.width / b))), h = max(1, Int(ceil(full.height / b)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = small
        return (small, full)
    }
}
