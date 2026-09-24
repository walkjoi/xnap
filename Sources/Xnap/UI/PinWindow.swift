import AppKit

/// Keeps a screenshot floating above all windows — handy as a reference while you work.
@MainActor
final class PinWindow: NSPanel, NSWindowDelegate {
    private static var pins: Set<PinWindow> = []
    private let image: CGImage
    private let scale: CGFloat

    static func show(image: CGImage, scale: CGFloat) {
        let pin = PinWindow(image: image, scale: scale)
        pins.insert(pin)
        pin.makeKeyAndOrderFront(nil)
    }

    private init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        let visible = NSScreen.underMouse.visibleFrame
        var size = image.pointSize(scale: scale)
        let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
        size = CGSize(width: max(80, size.width * fit), height: max(60, size.height * fit))
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        delegate = self

        let imageView = PinImageView()
        imageView.image = NSImage(cgImage: image, scale: scale)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.menu = makeMenu()
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        PinWindow.pins.remove(self)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Annotate…", action: #selector(annotate), keyEquivalent: "").target = self
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 80, 60, 40] {
            let item = sub.addItem(withTitle: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        OutputManager.shared.copy(image, scale: scale)
        Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
    }

    @objc private func annotate() {
        EditorWindowController.open(image: image, scale: scale)
        close()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closePin() { close() }
}

private final class PinImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.close() } else { window?.performDrag(with: event) }
    }
}
