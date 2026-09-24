import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A window for annotating one image.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var openEditors: [EditorWindowController] = []

    let editorDocument: EditorDocument
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let zoom = ZoomModel()
    private var boundsObserver: NSObjectProtocol?

    static func open(image: CGImage, scale: CGFloat, title: String? = nil) {
        let controller = EditorWindowController(image: image, scale: scale, title: title)
        openEditors.append(controller)
        DockPresence.windowOpened()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.layoutIfNeeded()
        controller.zoomToFit(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    private init(image: CGImage, scale: CGFloat, title: String?) {
        editorDocument = EditorDocument(image: image, scale: scale)
        canvas = CanvasView(document: editorDocument)

        let visible = (NSScreen.underMouse).visibleFrame
        let imageSize = image.pointSize(scale: scale)
        let chrome = CGSize(width: 40, height: 52 + 26 + 40)
        let width = min(visible.width * 0.9, max(980, imageSize.width + chrome.width))
        let height = min(visible.height * 0.9, max(560, imageSize.height + chrome.height))
        let frame = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 980, height: 420)
        window.tabbingMode = .disallowed
        window.title = title ?? "Xnap — \(OutputManager.shared.defaultBaseName().replacingOccurrences(of: "Xnap ", with: ""))"
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in window: NSWindow) {
        let actions = EditorActions(
            undo: { [weak self] in self?.editorDocument.undoManager.undo() },
            redo: { [weak self] in self?.editorDocument.undoManager.redo() },
            copy: { [weak self] in self?.copy(nil) },
            save: { [weak self] in self?.saveDocument(nil) },
            pin: { [weak self] in self?.pinToScreen(nil) },
            recognizeText: { [weak self] in self?.recognizeText(nil) })
        let toolbar = NSHostingView(rootView: EditorToolbar(document: editorDocument, actions: actions))
        let status = NSHostingView(rootView: EditorStatusBar(
            document: editorDocument, zoom: zoom,
            zoomIn: { [weak self] in self?.zoomIn(nil) },
            zoomOut: { [weak self] in self?.zoomOut(nil) },
            zoomToFit: { [weak self] in self?.zoomToFit(nil) },
            actualSize: { [weak self] in self?.actualSize(nil) }))

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder

        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateZoomLabel() }
            }

        let content = NSView()
        for view in [toolbar, scrollView, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setZoom(scrollView.magnification / 1.25) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    @objc func zoomToFit(_ sender: Any?) {
        let available = scrollView.contentSize
        let doc = canvas.frame.size
        guard doc.width > 0, doc.height > 0, available.width > 0, available.height > 0 else { return }
        let inset: CGFloat = 24
        var fit = min((available.width - inset) / doc.width, (available.height - inset) / doc.height)
        let isTall = doc.height / doc.width > 2.5
        if isTall { fit = (available.width - inset) / doc.width } // long scroll captures: fit the width
        scrollView.magnification = max(scrollView.minMagnification, min(1, fit))
        if isTall { canvas.scroll(.zero) }
        updateZoomLabel()
    }

    private func setZoom(_ value: CGFloat) {
        let clamped = min(scrollView.maxMagnification, max(scrollView.minMagnification, value))
        let visible = scrollView.documentVisibleRect
        scrollView.setMagnification(clamped, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        let percent = Int((scrollView.magnification * 100).rounded())
        if zoom.percent != percent { zoom.percent = percent }
    }

    // MARK: Commands

    @objc func copy(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = editorDocument.flattened() else { return }
        OutputManager.shared.copy(image, scale: editorDocument.scale)
        editorDocument.isDirty = false
        Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
    }

    @objc func saveDocument(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = editorDocument.flattened() else { return }
        do {
            let url = try OutputManager.shared.save(image, scale: editorDocument.scale)
            editorDocument.isDirty = false
            Toast.show("Saved “\(url.lastPathComponent)”", symbol: "square.and.arrow.down.fill")
        } catch {
            presentError(error)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let window, let image = editorDocument.flattened() else { return }
        let panel = NSSavePanel()
        let format = Preferences.shared.imageFormat
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "\(OutputManager.shared.defaultBaseName()).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try OutputManager.shared.write(image, scale: self.editorDocument.scale, to: url)
                self.editorDocument.isDirty = false
                Toast.show("Saved “\(url.lastPathComponent)”", symbol: "square.and.arrow.down.fill")
            } catch {
                self.presentError(error)
            }
        }
    }

    @objc func pinToScreen(_ sender: Any?) {
        canvas.commitTextEditing()
        guard let image = editorDocument.flattened() else { return }
        PinWindow.show(image: image, scale: editorDocument.scale)
    }

    @objc func recognizeText(_ sender: Any?) {
        CaptureCoordinator.shared.copyRecognizedText(from: editorDocument.image)
    }

    @objc func delete(_ sender: Any?) { editorDocument.deleteSelection() }

    @objc func applyCrop(_ sender: Any?) { editorDocument.applyCrop() }

    @objc func bringToFront(_ sender: Any?) { editorDocument.bringSelectionToFront() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(delete(_:)), #selector(bringToFront(_:)): return editorDocument.selectedID != nil
        case #selector(applyCrop(_:)): return editorDocument.tool == .crop && editorDocument.cropRect != nil
        default: return true
        }
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editorDocument.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextEditing()
        guard editorDocument.isDirty, !editorDocument.annotations.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your annotations?"
        alert.informativeText = "This screenshot has changes that haven't been copied or saved."
        alert.addButton(withTitle: "Copy & Close")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.copy(nil)
                sender.close()
            case .alertThirdButtonReturn:
                self.editorDocument.isDirty = false
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        EditorWindowController.openEditors.removeAll { $0 === self }
        DockPresence.windowClosed()
    }
}

/// Keeps the editorDocument centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}
