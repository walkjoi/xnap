import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The screen currently under the mouse pointer.
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    /// Converts a rect in this screen's local, top-left-origin space (points) into
    /// AppKit's global, bottom-left-origin space.
    func globalRect(fromLocal r: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a local, top-left-origin rect into Quartz global coordinates
    /// (top-left origin of the primary display), used by CGEvent and CGWindowList.
    func quartzRect(fromLocal r: CGRect) -> CGRect {
        r.offsetBy(dx: CGDisplayBounds(displayID).minX, dy: CGDisplayBounds(displayID).minY)
    }

    /// Converts a Quartz global rect into this screen's local, top-left-origin space.
    func localRect(fromQuartz r: CGRect) -> CGRect {
        r.offsetBy(dx: -CGDisplayBounds(displayID).minX, dy: -CGDisplayBounds(displayID).minY)
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }

    /// The image size in points for a given pixel density.
    func pointSize(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }

    /// A crop that owns its pixels, in the same top-left-origin space as `cropping(to:)`.
    ///
    /// `cropping(to:)` only returns a window onto the original: it keeps the parent's data
    /// provider and row stride alive. Cropping a small area out of a display snapshot would
    /// therefore pin the whole screen's pixels — tens of megabytes — for as long as the result
    /// lives, and captures are long-lived (clipboard, editor undo states, pinned windows).
    /// Note that `copy()` does not detach either; the pixels have to be redrawn.
    func croppedCopy(to rect: CGRect) -> CGImage? {
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clamped.width >= 1, clamped.height >= 1, let view = cropping(to: clamped) else { return nil }
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: view.width, height: view.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(view, in: CGRect(x: 0, y: 0, width: view.width, height: view.height))
        return ctx.makeImage()
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGSize) -> CGPoint { CGPoint(x: a.x + b.width, y: a.y + b.height) }
    static func - (a: CGPoint, b: CGPoint) -> CGSize { CGSize(width: a.x - b.x, height: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }

    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    /// Distance from this point to the segment `a`–`b`.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

extension NSImage {
    convenience init(cgImage: CGImage, scale: CGFloat) {
        self.init(cgImage: cgImage, size: cgImage.pointSize(scale: scale))
    }
}

/// Keeps the app out of the Dock unless one of its document-like windows is open.
@MainActor
enum DockPresence {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
