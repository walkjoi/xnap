import AppKit
import SwiftUI

/// A brief, non-interactive confirmation bubble near the bottom of the screen.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?
    /// Identifies the toast currently owning the shared panel. Cancelling `hideTask` does not
    /// stop a fade-out that already started, and its completion would otherwise order the
    /// panel out from under whichever toast replaced it.
    private static var generation = 0

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", isError: Bool = false,
                     duration: Duration = .milliseconds(1800)) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation += 1
        let token = generation
        let host = PanelHostingView(rootView: ToastView(message: message, symbol: symbol, isError: isError))
        panel.contentView = host
        let size = host.fittingSize
        let visible = NSScreen.underMouse.visibleFrame
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 72,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, token == generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: {
                MainActor.assumeIsolated {
                    if token == generation { panel.orderOut(nil) }
                }
            })
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isError ? Color.orange : Color.accentColor)
            Text(message)
                .lineLimit(2)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(12)
        .fixedSize()
    }
}
