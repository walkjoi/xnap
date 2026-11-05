import AppKit
import SwiftUI

/// Hosting view for non-activating panels (HUD, preview, toast): accepts the first click and
/// tracks hover even while Xnap isn't the active app.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["panelHover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["panelHover": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

/// An accent-filled button that looks the same whether or not its window is key.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
