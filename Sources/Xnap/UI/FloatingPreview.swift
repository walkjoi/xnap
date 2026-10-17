import AppKit
import SwiftUI

/// The thumbnail that slides in after a capture. Click it to annotate, drag it into
/// another app, or use the quick actions on hover. Dismisses itself after a few seconds.
@MainActor
final class FloatingPreview {
    private static var current: FloatingPreview?

    private let image: CGImage
    private let scale: CGFloat
    private var savedURL: URL?
    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?
    private let hover = HoverModel()

    static func show(image: CGImage, scale: CGFloat, savedURL: URL?) {
        current?.close(animated: false)
        let preview = FloatingPreview(image: image, scale: scale, savedURL: savedURL)
        current = preview
        preview.present()
    }

    static func dismiss() { current?.close(animated: true) }

    private init(image: CGImage, scale: CGFloat, savedURL: URL?) {
        self.image = image
        self.scale = scale
        self.savedURL = savedURL
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
    }

    private func present() {
        let boxWidth: CGFloat = 220
        let aspect = CGFloat(image.height) / CGFloat(max(1, image.width))
        let boxHeight = min(180, max(90, boxWidth * aspect))
        // Tall captures show their top part rather than a thin sliver.
        let cropHeight = min(CGFloat(image.height), CGFloat(image.width) * boxHeight / boxWidth)
        let thumbSource = image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: cropHeight)) ?? image

        let caption: String
        if let savedURL { caption = "Saved · \(savedURL.deletingLastPathComponent().lastPathComponent)" }
        else { caption = "Copied to clipboard" }

        let view = FloatingPreviewView(
            thumbnail: NSImage(cgImage: thumbSource, scale: scale),
            size: CGSize(width: boxWidth, height: boxHeight),
            caption: caption,
            dimensions: "\(image.width) × \(image.height)",
            isSaved: savedURL != nil,
            hover: hover,
            actions: .init(
                annotate: { [weak self] in self?.annotate() },
                copy: { [weak self] in self?.copy() },
                save: { [weak self] in self?.save() },
                pin: { [weak self] in self?.pin() },
                recognizeText: { [weak self] in self?.recognizeText() },
                close: { [weak self] in self?.close(animated: true) },
                dragItem: { [weak self] in self?.dragItem() ?? NSItemProvider() }))
        let host = PanelHostingView(rootView: view)
        host.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host
        let size = host.fittingSize
        let visible = NSScreen.underMouse.visibleFrame
        let final = CGRect(x: visible.maxX - size.width - 4, y: visible.minY + 4, width: size.width, height: size.height)
        panel.setFrame(final.offsetBy(dx: 60, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let seconds = Preferences.shared.previewSeconds
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.hover.isHovering else { return }
            self.close(animated: true)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { hover.isHovering = hovering }
        if hovering { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func close(animated: Bool) {
        dismissTask?.cancel()
        if FloatingPreview.current === self { FloatingPreview.current = nil }
        let panel = self.panel
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(panel.frame.offsetBy(dx: 60, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: Actions

    private func annotate() {
        close(animated: false)
        EditorWindowController.open(image: image, scale: scale)
    }

    private func copy() {
        let image = self.image, scale = self.scale
        close(animated: true)
        Task {
            do {
                try await OutputManager.shared.copy(image, scale: scale)
                Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func save() {
        if let savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
            close(animated: true)
            return
        }
        let image = self.image, scale = self.scale
        close(animated: true)
        Task {
            do {
                let url = try await OutputManager.shared.save(image, scale: scale)
                Toast.show("Saved “\(url.lastPathComponent)”", symbol: "square.and.arrow.down.fill")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true)
            }
        }
    }

    private func pin() {
        close(animated: false)
        PinWindow.show(image: image, scale: scale)
    }

    private func recognizeText() {
        let image = self.image
        close(animated: true)
        CaptureCoordinator.shared.copyRecognizedText(from: image)
    }

    private func dragItem() -> NSItemProvider {
        guard let url = savedURL ?? OutputManager.shared.temporaryFile(for: image, scale: scale),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        // Once dropped somewhere, the preview has done its job.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.close(animated: true)
        }
        return provider
    }
}

@MainActor
private final class HoverModel: ObservableObject {
    @Published var isHovering = false
}

private struct FloatingPreviewView: View {
    struct Actions {
        let annotate: () -> Void
        let copy: () -> Void
        let save: () -> Void
        let pin: () -> Void
        let recognizeText: () -> Void
        let close: () -> Void
        let dragItem: () -> NSItemProvider
    }

    let thumbnail: NSImage
    let size: CGSize
    let caption: String
    let dimensions: String
    let isSaved: Bool
    @ObservedObject var hover: HoverModel
    let actions: Actions

    private var hovering: Bool { hover.isHovering }

    var body: some View {
        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()

            if hovering {
                Color.black.opacity(0.38)
                VStack(spacing: 0) {
                    HStack {
                        Text(dimensions)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        RoundButton(symbol: "xmark", help: "Close", action: actions.close)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        RoundButton(symbol: "pencil.tip.crop.circle", help: "Annotate", action: actions.annotate)
                        RoundButton(symbol: "doc.on.doc", help: "Copy", action: actions.copy)
                        RoundButton(symbol: isSaved ? "folder" : "square.and.arrow.down",
                                    help: isSaved ? "Show in Finder" : "Save", action: actions.save)
                        RoundButton(symbol: "pin", help: "Pin to Screen", action: actions.pin)
                        RoundButton(symbol: "text.viewfinder", help: "Copy Text", action: actions.recognizeText)
                    }
                }
                .padding(8)
            } else {
                VStack {
                    Spacer()
                    HStack {
                        Label(caption, systemImage: isSaved ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                }
                .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.28)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.annotate)
        .onDrag(actions.dragItem)
        .help("Click to annotate · Drag into any app")
        .padding(16)
    }
}

private struct RoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.ultraThickMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
