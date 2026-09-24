import AppKit
import SwiftUI

@MainActor
final class ScrollHUDModel: ObservableObject {
    enum Tone { case normal, warning, busy }

    @Published var message = "Scroll down slowly. Press ⏎ when done, ⎋ to cancel."
    @Published var tone: Tone = .normal
    @Published var heightPixels = 0
    @Published var scale: CGFloat = 2
    @Published var preview: CGImage?
    @Published var isAutoScrolling = false
    @Published var isFinishing = false
    let savesToFile: Bool

    var onAutoScroll: () -> Void = {}
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    init(savesToFile: Bool) { self.savesToFile = savesToFile }

    func say(_ message: String, _ tone: Tone = .normal) {
        self.message = message
        self.tone = tone
    }
}

/// Floating control panel shown next to the region during a scrolling capture.
/// It never takes focus, so the app being captured keeps receiving scrolls and keys.
final class ScrollHUDPanel: NSPanel {
    init(model: ScrollHUDModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PanelHostingView(rootView: ScrollHUDView(model: model))
    }

    /// Places the panel below the region, else above it, else inside its bottom edge.
    func position(near region: CGRect, on screen: NSScreen) {
        let size = contentView?.fittingSize ?? CGSize(width: 440, height: 110)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 4)
        if origin.y < visible.minY {
            origin.y = region.maxY + 4
            if origin.y + size.height > visible.maxY { origin.y = region.minY + 12 }
        }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

private struct ScrollHUDView: View {
    @ObservedObject var model: ScrollHUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            previewBox
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RecordingDot(active: !model.isFinishing)
                    Text("Scrolling Capture").font(.system(size: 13, weight: .semibold))
                    if model.savesToFile {
                        Text("→ File").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(model.heightPixels.formatted()) px")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(messageColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(action: model.onAutoScroll) {
                        Label(model.isAutoScrolling ? "Stop" : "Auto-Scroll",
                              systemImage: model.isAutoScrolling ? "pause.fill" : "arrow.down.to.line")
                    }
                    .help("Scroll automatically until the end of the page")
                    Spacer()
                    Button("Cancel", action: model.onCancel)
                    Button(action: model.onDone) {
                        Text(model.savesToFile ? "Save" : "Done")
                            .frame(minWidth: 40)
                    }
                    .buttonStyle(ProminentButtonStyle())
                }
                .controlSize(.small)
                .disabled(model.isFinishing)
            }
        }
        .padding(12)
        .frame(width: 440, height: 124)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(14)
    }

    private var messageColor: Color {
        switch model.tone {
        case .normal: .secondary
        case .warning: .orange
        case .busy: .accentColor
        }
    }

    private var previewBox: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.08))
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 70, maxHeight: 100, alignment: .bottom)
            } else {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 70, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
    }
}

private struct RecordingDot: View {
    let active: Bool

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(active ? Color.red : Color.secondary)
            .symbolEffect(.pulse, isActive: active)
    }
}

/// Dims everything except the region and draws a "marching ants" frame around it.
/// Mouse events pass straight through to the app underneath.
final class RegionHighlightWindow: NSWindow {
    init(screen: NSScreen, region: CGRect) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)

        let size = screen.frame.size
        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.layer = CALayer()
        view.wantsLayer = true
        let hole = CGRect(x: region.minX, y: size.height - region.maxY, width: region.width, height: region.height)

        let dim = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        path.addRect(hole)
        dim.path = path
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        view.layer?.addSublayer(dim)

        let border = CAShapeLayer()
        border.path = CGPath(rect: hole.insetBy(dx: -1.5, dy: -1.5), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [7, 5]
        border.contentsScale = screen.backingScaleFactor
        dim.contentsScale = screen.backingScaleFactor
        let ants = CABasicAnimation(keyPath: "lineDashPhase")
        ants.fromValue = 0
        ants.toValue = 12
        ants.duration = 0.6
        ants.repeatCount = .infinity
        border.add(ants, forKey: "ants")
        view.layer?.addSublayer(border)

        contentView = view
    }
}
