import AppKit

/// An sRGB color that is cheap to compare and store.
struct RGBA: Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .systemRed
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Black or white, whichever reads better on top of this color.
    var contrasting: RGBA {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.6 ? .black : .white
    }

    static let red = RGBA(r: 1, g: 0.23, b: 0.19)
    static let orange = RGBA(r: 1, g: 0.58, b: 0)
    static let yellow = RGBA(r: 1, g: 0.8, b: 0)
    static let green = RGBA(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBA(r: 0, g: 0.48, b: 1)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, pixelate, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select & Move"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Numbered Step"
        case .pixelate: "Pixelate (redact)"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .pixelate: "b"
        case .crop: "c"
        }
    }

    var supportsFill: Bool { self == .rectangle || self == .ellipse }
    var usesColor: Bool { self != .pixelate && self != .crop && self != .select }
}

/// Stroke / text size presets, in points (multiplied by the image scale).
enum StrokeSize: Int, CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: Int { rawValue }
    var title: String { ["S", "M", "L", "XL"][rawValue] }
    var lineWidth: CGFloat { [2, 4, 7, 12][rawValue] }
    var fontSize: CGFloat { [15, 20, 30, 44][rawValue] }
    var counterSize: CGFloat { [13, 17, 23, 32][rawValue] }
}

/// One markup element. All geometry is in image pixels, origin top-left.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// Top-left origin of the text box.
        case text(CGPoint, String)
        case counter(CGPoint, Int)
        case pixelate(CGRect)
    }

    var id = UUID()
    var shape: Shape
    var color: RGBA
    var lineWidth: CGFloat
    var filled = false
    /// Font size for text and numbered steps, in image pixels.
    var fontSize: CGFloat = 0

    var textFont: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }
    var counterRadius: CGFloat { fontSize * 0.95 }

    var bounds: CGRect {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b):
            return CGRect(from: a, to: b).insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3)
        case .rectangle(let r), .ellipse(let r), .pixelate(let r):
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .pen(let pts), .highlighter(let pts):
            guard let first = pts.first else { return .null }
            let w = shape.isHighlighter ? lineWidth * 3 : lineWidth
            return pts.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -w, dy: -w)
        case .text(let origin, let string):
            return CGRect(origin: origin, size: TextMetrics.size(of: string, font: textFont))
        case .counter(let c, _):
            let r = counterRadius
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        }
    }

    func translated(by d: CGSize) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(let a, let b): copy.shape = .arrow(a + d, b + d)
        case .line(let a, let b): copy.shape = .line(a + d, b + d)
        case .rectangle(let r): copy.shape = .rectangle(r.offsetBy(dx: d.width, dy: d.height))
        case .ellipse(let r): copy.shape = .ellipse(r.offsetBy(dx: d.width, dy: d.height))
        case .pixelate(let r): copy.shape = .pixelate(r.offsetBy(dx: d.width, dy: d.height))
        case .pen(let pts): copy.shape = .pen(pts.map { $0 + d })
        case .highlighter(let pts): copy.shape = .highlighter(pts.map { $0 + d })
        case .text(let o, let s): copy.shape = .text(o + d, s)
        case .counter(let c, let n): copy.shape = .counter(c + d, n)
        }
        return copy
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b):
            return p.distance(toSegment: a, b) <= lineWidth + tolerance
        case .rectangle(let r):
            if filled { return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let reach = lineWidth / 2 + tolerance
            return r.insetBy(dx: -reach, dy: -reach).contains(p) && !r.insetBy(dx: reach, dy: reach).contains(p)
        case .ellipse(let r):
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            if filled { return d <= 1 + tolerance / min(r.width, r.height) }
            return abs(d - 1) * min(r.width, r.height) / 2 <= lineWidth / 2 + tolerance
        case .pixelate(let r):
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .pen(let pts), .highlighter(let pts):
            let reach = (shape.isHighlighter ? lineWidth * 1.5 : lineWidth / 2) + tolerance
            if pts.count == 1 { return p.distance(to: pts[0]) <= reach }
            return zip(pts, pts.dropFirst()).contains { p.distance(toSegment: $0, $1) <= reach }
        case .text, .counter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    // MARK: Handles

    /// Drag handles for resizable shapes: 4 corners, or 2 line endpoints.
    var handles: [CGPoint] {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b):
            return [a, b]
        case .rectangle(let r), .ellipse(let r), .pixelate(let r):
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default:
            return []
        }
    }

    func movingHandle(_ index: Int, to p: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(let a, let b): copy.shape = index == 0 ? .arrow(p, b) : .arrow(a, p)
        case .line(let a, let b): copy.shape = index == 0 ? .line(p, b) : .line(a, p)
        case .rectangle(let r): copy.shape = .rectangle(Annotation.resize(r, corner: index, to: p))
        case .ellipse(let r): copy.shape = .ellipse(Annotation.resize(r, corner: index, to: p))
        case .pixelate(let r): copy.shape = .pixelate(Annotation.resize(r, corner: index, to: p))
        default: break
        }
        return copy
    }

    /// Moves corner `index` (TL, TR, BR, BL) of `r` to `p`, keeping the opposite corner fixed.
    static func resize(_ r: CGRect, corner index: Int, to p: CGPoint) -> CGRect {
        let opposite: CGPoint
        switch index {
        case 0: opposite = CGPoint(x: r.maxX, y: r.maxY)
        case 1: opposite = CGPoint(x: r.minX, y: r.maxY)
        case 2: opposite = CGPoint(x: r.minX, y: r.minY)
        default: opposite = CGPoint(x: r.maxX, y: r.minY)
        }
        return CGRect(from: opposite, to: p)
    }
}

extension Annotation.Shape {
    var isHighlighter: Bool { if case .highlighter = self { true } else { false } }
    var isText: Bool { if case .text = self { true } else { false } }
    var isPixelate: Bool { if case .pixelate = self { true } else { false } }
}

enum TextMetrics {
    static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.04)
        shadow.shadowBlurRadius = font.pointSize * 0.12
        return [.font: font, .foregroundColor: color, .shadow: shadow]
    }

    static func size(of string: String, font: NSFont) -> CGSize {
        let text = string.isEmpty ? " " : string
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return CGSize(width: ceil(rect.width) + 2, height: ceil(rect.height))
    }
}
