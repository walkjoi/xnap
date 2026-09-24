import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A click-to-record field for a global shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    let action: CaptureAction
    @ObservedObject var prefs: Preferences

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView()
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = prefs.shortcut(for: action)
        view.hasConflict = prefs.conflictingActions.contains(action)
        view.toolTip = view.hasConflict ? "This shortcut is already used by another app." : nil
        let action = self.action, prefs = self.prefs
        view.onChange = { prefs.setShortcut($0, for: action) }
    }
}

final class ShortcutRecorderView: NSView {
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var hasConflict = false { didSet { needsDisplay = true } }
    var onChange: ((Shortcut?) -> Void)?

    private var liveModifiers: NSEvent.ModifierFlags = []
    private var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            // Global hotkeys would swallow the keystrokes we're trying to record.
            if isRecording { HotKeyCenter.shared.pause() } else { HotKeyCenter.shared.resume() }
            liveModifiers = []
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    private var clearButtonRect: CGRect {
        CGRect(x: bounds.maxX - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if shortcut != nil, !isRecording, clearButtonRect.insetBy(dx: -3, dy: -3).contains(p) {
            onChange?(nil)
            return
        }
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { isRecording = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        if modifiers.isEmpty && code == kVK_Escape { stopRecording(); return }
        if modifiers.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) {
            onChange?(nil)
            stopRecording()
            return
        }
        let candidate = Shortcut(keyCode: code, modifiers: modifiers)
        guard candidate.isValidGlobalShortcut else { NSSound.beep(); return }
        onChange?(candidate)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            let prefix = Shortcut.symbols(for: liveModifiers)
            text = prefix.isEmpty ? "Type shortcut…" : "\(prefix)…"
            color = .secondaryLabelColor
        } else if let shortcut {
            text = shortcut.displayString
            color = hasConflict ? .systemOrange : .labelColor
        } else {
            text = "Click to record"
            color = .tertiaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: shortcut != nil && !isRecording ? .medium : .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: 10, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        if shortcut != nil && !isRecording {
            let clear = clearButtonRect
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: clear).fill()
            NSColor.controlBackgroundColor.setStroke()
            let x = NSBezierPath()
            x.lineWidth = 1.5
            let inset = clear.insetBy(dx: 5, dy: 5)
            x.move(to: CGPoint(x: inset.minX, y: inset.minY)); x.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
            x.move(to: CGPoint(x: inset.minX, y: inset.maxY)); x.line(to: CGPoint(x: inset.maxX, y: inset.minY))
            x.stroke()
        }
    }
}
