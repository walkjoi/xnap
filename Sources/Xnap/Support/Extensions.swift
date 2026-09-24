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
