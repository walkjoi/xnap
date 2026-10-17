import AppKit
import QuartzCore

/// A region the user picked on one display.
struct CaptureSelection {
    let snapshot: DisplaySnapshot
    /// In the screen's local, top-left-origin coordinate space, in points.
    let rect: CGRect

    var screen: NSScreen { snapshot.screen }
    var scale: CGFloat { snapshot.scale }

    var pixelRect: CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale).integral
    }

    /// Detached from the display snapshot on purpose — see `croppedCopy(to:)`.
    var croppedImage: CGImage? { snapshot.image.croppedCopy(to: pixelRect) }
}

/// Full-screen "freeze frame" overlay for picking an area or a window.
///
/// Each display shows its own snapshot, so menus and hover states captured at the
/// moment the shortcut was pressed are preserved. Drag to select; click to take the
/// window under the pointer (or the whole screen); Esc cancels.
@MainActor
final class SelectionOverlay {
    enum Purpose {
        case screenshot, scrolling, recognizeText

        var hint: String {
            switch self {
            case .screenshot: "Drag to select · Click a window to capture it · C copies the color · Esc cancels"
            case .scrolling: "Select the area that scrolls — a page, a list, or a whole window · Esc cancels"
            case .recognizeText: "Select the text to copy · Esc cancels"
            }
        }
    }

    private static var active: SelectionOverlay?
    private var windows: [OverlayWindow] = []
    private var completion: ((CaptureSelection?) -> Void)?

    static func present(purpose: Purpose, snapshots: [DisplaySnapshot],
                        completion: @escaping (CaptureSelection?) -> Void) {
        active?.finish(nil)
        let overlay = SelectionOverlay()
        overlay.completion = completion
        active = overlay

        let windowFrames = WindowList.visibleWindowFrames()
        for snapshot in snapshots {
            let screenBounds = CGRect(origin: .zero, size: snapshot.screen.frame.size)
            let localWindows = windowFrames
                .map { snapshot.screen.localRect(fromQuartz: $0) }
                .filter { $0.intersects(screenBounds) }
            let window = OverlayWindow(snapshot: snapshot, purpose: purpose, windowRects: localWindows) {
                [weak overlay] selection in overlay?.finish(selection)
            }
            overlay.windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate()
        let mouseScreen = NSScreen.underMouse
        (overlay.windows.first { $0.snapshot.screen == mouseScreen } ?? overlay.windows.first)?
            .makeKeyAndOrderFront(nil)
    }

    private func finish(_ selection: CaptureSelection?) {
        guard let completion else { return }
        self.completion = nil
        for window in windows { window.orderOut(nil) }
        SelectionOverlay.active = nil
        // Let the overlay leave the screen before anything else happens.
        DispatchQueue.main.async { [self] in
            windows.removeAll()
            completion(selection)
        }
    }
}

private final class OverlayWindow: NSWindow {
    let snapshot: DisplaySnapshot

    init(snapshot: DisplaySnapshot, purpose: SelectionOverlay.Purpose, windowRects: [CGRect],
         onFinish: @escaping (CaptureSelection?) -> Void) {
        self.snapshot = snapshot
        super.init(contentRect: snapshot.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        setFrame(snapshot.screen.frame, display: false)
        let view = SelectionView(snapshot: snapshot, purpose: purpose, windowRects: windowRects, onFinish: onFinish)
        contentView = view
        initialFirstResponder = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let snapshot: DisplaySnapshot
    private let purpose: SelectionOverlay.Purpose
    private let windowRects: [CGRect]
    private let onFinish: (CaptureSelection?) -> Void

    private var dragOrigin: CGPoint?
    private var isDragging = false
    private var selection: CGRect?
    private var hoveredWindow: CGRect?
    private var mouse: CGPoint?
    private var finished = false

    private let imageLayer = CALayer()
    /// The dim is four plain layers tiled around the selection, and the border is a plain
    /// layer's border, rather than display-sized `CAShapeLayer`s. Changing a shape layer's
    /// path makes the render server re-rasterize the whole layer, and these are updated on
    /// every pointer move — which on a 5K display means re-rasterizing 5120×2880 each time.
    private let dimBands = [CALayer(), CALayer(), CALayer(), CALayer()]
    private let borderLayer = CALayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let sizeLabel: PillLabel
    private let hintLabel: PillLabel
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeCenter = CALayer()
    private let loupeInfo: PillLabel
    private var loupeColorHex = ""

    private static let loupeSize: CGFloat = 120
    private static let loupePixels = 15

    init(snapshot: DisplaySnapshot, purpose: SelectionOverlay.Purpose, windowRects: [CGRect],
         onFinish: @escaping (CaptureSelection?) -> Void) {
        self.snapshot = snapshot
        self.purpose = purpose
        self.windowRects = windowRects
        self.onFinish = onFinish
        sizeLabel = PillLabel(scale: snapshot.scale)
        hintLabel = PillLabel(scale: snapshot.scale)
        loupeInfo = PillLabel(scale: snapshot.scale)
        super.init(frame: CGRect(origin: .zero, size: snapshot.screen.frame.size))

        // Layer-hosting view: the layer tree uses the default bottom-left origin.
        layer = CALayer()
        wantsLayer = true
        buildLayers()

        let p = NSEvent.mouseLocation
        if NSMouseInRect(p, snapshot.screen.frame, false) {
            mouse = CGPoint(x: p.x - snapshot.screen.frame.minX, y: snapshot.screen.frame.maxY - p.y)
            updateHover()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayers() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        imageLayer.frame = bounds
        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        let dimColor = NSColor.black.withAlphaComponent(0.4).cgColor
        for band in dimBands {
            band.backgroundColor = dimColor
            root.addSublayer(band)
        }

        borderLayer.borderWidth = 1.5
        borderLayer.isHidden = true
        root.addSublayer(borderLayer)

        for line in [crossH, crossV] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
            root.addSublayer(line)
        }

        root.addSublayer(sizeLabel)

        let hintSize = hintLabel.set(purpose.hint, fontSize: 13)
        hintLabel.frame = CGRect(x: (bounds.width - hintSize.width) / 2, y: bounds.height - 64 - hintSize.height,
                                 width: hintSize.width, height: hintSize.height)
        root.addSublayer(hintLabel)

        loupe.bounds = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
        loupe.cornerRadius = 10
        loupe.masksToBounds = true
        loupe.borderWidth = 2
        loupe.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupe.backgroundColor = NSColor.black.cgColor
        loupeImage.frame = loupe.bounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupe.addSublayer(loupeImage)
        let cell = Self.loupeSize / CGFloat(Self.loupePixels)
        loupeCenter.frame = CGRect(x: (Self.loupeSize - cell) / 2, y: (Self.loupeSize - cell) / 2, width: cell, height: cell)
        loupeCenter.borderWidth = 1
        loupeCenter.borderColor = NSColor.systemRed.cgColor
        loupe.addSublayer(loupeCenter)
        root.addSublayer(loupe)
        root.addSublayer(loupeInfo)
    }

    // MARK: Coordinates

    /// Top-left-origin rect → layer (bottom-left) rect.
    private func toLayer(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func point(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, bounds.height - p.y), bounds.height))
    }

    private var screenBounds: CGRect { CGRect(origin: .zero, size: bounds.size) }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = point(for: event)
        updateHover()
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        guard dragOrigin == nil else { return }
        mouse = nil
        hoveredWindow = nil
        refresh()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = point(for: event)
        updateHover()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = point(for: event)
        isDragging = false
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = point(for: event)
        mouse = p
        if !isDragging && (abs(p.x - origin.x) > 3 || abs(p.y - origin.y) > 3) { isDragging = true }
        if isDragging {
            var rect = CGRect(from: origin, to: p)
            if event.modifierFlags.contains(.shift) {
                let side = min(rect.width, rect.height)
                rect = CGRect(x: p.x < origin.x ? origin.x - side : origin.x,
                              y: p.y < origin.y ? origin.y - side : origin.y, width: side, height: side)
            }
            selection = rect
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if isDragging {
            isDragging = false
            if let rect = selection, rect.width >= 4, rect.height >= 4 {
                finish(rect)
            } else {
                selection = nil
                refresh()
            }
            return
        }
        finish(hoveredWindow?.intersection(screenBounds) ?? screenBounds)
    }

    override func rightMouseDown(with event: NSEvent) { cancel() }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: cancel() // Esc
        case 36, 76: finish(hoveredWindow?.intersection(screenBounds) ?? screenBounds) // Return / Enter
        case 8 where purpose == .screenshot && !loupeColorHex.isEmpty: // C
            OutputManager.shared.copy(text: loupeColorHex)
            let hex = loupeColorHex
            cancel()
            Toast.show("Copied color \(hex)", symbol: "eyedropper")
        default: super.keyDown(with: event)
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onFinish(nil)
    }

    private func finish(_ rect: CGRect) {
        guard !finished, rect.width >= 1, rect.height >= 1 else { return }
        finished = true
        onFinish(CaptureSelection(snapshot: snapshot, rect: rect))
    }

    private func updateHover() {
        guard let mouse, dragOrigin == nil else { hoveredWindow = nil; return }
        hoveredWindow = windowRects.first { $0.contains(mouse) }
    }

    // MARK: Drawing

    /// Tiles the dim around `hole` (in layer coordinates). An empty hole dims everything.
    private func setDim(hole: CGRect) {
        let frames = [
            CGRect(x: 0, y: hole.maxY, width: bounds.width, height: max(0, bounds.height - hole.maxY)),
            CGRect(x: 0, y: 0, width: bounds.width, height: max(0, hole.minY)),
            CGRect(x: 0, y: hole.minY, width: max(0, hole.minX), height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: max(0, bounds.width - hole.maxX), height: hole.height),
        ]
        for (band, frame) in zip(dimBands, frames) { band.frame = frame }
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let active = selection ?? (isDragging ? nil : hoveredWindow)?.intersection(screenBounds)
        setDim(hole: active.map(toLayer) ?? .zero)

        if let active {
            borderLayer.isHidden = false
            borderLayer.frame = toLayer(active).insetBy(dx: -1.5, dy: -1.5)
            borderLayer.borderColor = (selection != nil ? NSColor.white : NSColor.controlAccentColor).cgColor
            let text = "\(Int(active.width.rounded())) × \(Int(active.height.rounded()))"
            let size = sizeLabel.set(text, fontSize: 12)
            var origin = CGPoint(x: active.minX, y: active.maxY + 8)
            if origin.y + size.height > bounds.height - 4 { origin.y = active.maxY - size.height - 8 }
            origin.x = min(max(4, origin.x), bounds.width - size.width - 4)
            sizeLabel.frame = toLayer(CGRect(origin: origin, size: size))
            sizeLabel.isHidden = false
        } else {
            borderLayer.isHidden = true
            sizeLabel.isHidden = true
        }

        hintLabel.isHidden = isDragging || selection != nil

        guard let mouse else {
            crossH.isHidden = true; crossV.isHidden = true
            loupe.isHidden = true; loupeInfo.isHidden = true
            return
        }
        let showCross = !isDragging
        crossH.isHidden = !showCross
        crossV.isHidden = !showCross
        crossH.frame = toLayer(CGRect(x: 0, y: mouse.y.rounded(.down), width: bounds.width, height: 1))
        crossV.frame = toLayer(CGRect(x: mouse.x.rounded(.down), y: 0, width: 1, height: bounds.height))

        updateLoupe(at: mouse)
    }

    private func updateLoupe(at mouse: CGPoint) {
        let scale = snapshot.scale
        let image = snapshot.image
        let px = min(max(0, Int(mouse.x * scale)), image.width - 1)
        let py = min(max(0, Int(mouse.y * scale)), image.height - 1)
        let span = Self.loupePixels
        let window = Loupe.window(x: px, y: py, width: image.width, height: image.height, span: span)
        loupeImage.contents = image.cropping(to: CGRect(x: window.originX, y: window.originY,
                                                        width: span, height: span))

        // The centre cell marks the pixel actually under the pointer, which is off-centre
        // once the window has been pushed back inside the image near an edge.
        let cell = Self.loupeSize / CGFloat(span)
        loupeCenter.frame = CGRect(x: CGFloat(window.offsetX) * cell,
                                   y: Self.loupeSize - CGFloat(window.offsetY + 1) * cell,
                                   width: cell, height: cell)

        let size = Self.loupeSize
        var origin = CGPoint(x: mouse.x + 24, y: mouse.y + 24)
        if origin.x + size > bounds.width - 8 { origin.x = mouse.x - 24 - size }
        if origin.y + size + 40 > bounds.height - 8 { origin.y = mouse.y - 24 - size - 34 }
        let loupeRect = CGRect(origin: origin, size: CGSize(width: size, height: size))
        loupe.frame = toLayer(loupeRect)
        loupe.isHidden = false

        loupeColorHex = hexColor(of: snapshot.image, x: px, y: py) ?? ""
        let info = "\(Int(mouse.x)), \(Int(mouse.y))  \(loupeColorHex)"
        let infoSize = loupeInfo.set(info, fontSize: 11)
        loupeInfo.frame = toLayer(CGRect(x: loupeRect.midX - infoSize.width / 2, y: loupeRect.maxY + 6,
                                         width: infoSize.width, height: infoSize.height))
        loupeInfo.isHidden = false
    }

    /// One reused 1×1 context, because the colour under the pointer is sampled on every
    /// mouse-moved event and building a `CGContext` per event is pure waste.
    private lazy var probe: CGContext? = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)

    private func hexColor(of image: CGImage, x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let probe, let data = probe.data,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        probe.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        return String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }
}

/// Geometry of the magnifier's sample window.
enum Loupe {
    struct Window: Equatable {
        /// Top-left of the sampled square, in image pixels.
        var originX: Int, originY: Int
        /// Where the sampled pixel sits inside that square.
        var offsetX: Int, offsetY: Int
    }

    /// The `span`×`span` pixel square to magnify around (`x`, `y`), shifted to stay fully
    /// inside the image.
    ///
    /// A window that hangs off the edge comes back from `cropping(to:)` smaller than asked
    /// for and then gets stretched to fill the loupe, which both changes the magnification
    /// and moves the centre marker off the pixel being sampled. Shifting instead of shrinking
    /// keeps the scale honest.
    static func window(x: Int, y: Int, width: Int, height: Int, span: Int) -> Window {
        let originX = min(max(0, x - span / 2), max(0, width - span))
        let originY = min(max(0, y - span / 2), max(0, height - span))
        return Window(originX: originX, originY: originY,
                      offsetX: x - originX, offsetY: y - originY)
    }
}

/// A rounded, dark "pill" with a single line of white text.
final class PillLabel: CALayer {
    private let textLayer = CATextLayer()
    private let padding = CGSize(width: 8, height: 4)

    init(scale: CGFloat) {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        cornerRadius = 6
        contentsScale = scale
        textLayer.contentsScale = scale
        addSublayer(textLayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the text and returns the size the pill needs.
    @discardableResult
    func set(_ string: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
        textLayer.string = attributed
        let text = attributed.size()
        let textSize = CGSize(width: ceil(text.width), height: ceil(text.height))
        textLayer.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height), size: textSize)
        return CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
    }
}
