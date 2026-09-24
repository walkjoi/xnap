import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        statusBar = StatusBarController()
        registerHotKeys()
        Preferences.shared.shortcutsChanged
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &subscriptions)

        if !Preferences.shared.hasLaunchedBefore {
            Preferences.shared.hasLaunchedBefore = true
            DispatchQueue.main.async { self.showWelcome() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.show() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openImage(at:))
    }

    private func registerHotKeys() {
        var conflicts = Set<CaptureAction>()
        for action in CaptureAction.allCases {
            HotKeyCenter.shared.unregister(id: action.hotKeyID)
            guard let shortcut = Preferences.shared.shortcut(for: action) else { continue }
            let ok = HotKeyCenter.shared.register(id: action.hotKeyID, shortcut: shortcut) {
                CaptureCoordinator.shared.perform(action)
            }
            if !ok { conflicts.insert(action) }
        }
        Preferences.shared.conflictingActions = conflicts
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show() }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Handy screenshots with scrolling capture and rich image tools.\nFully local — no network access.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func openImageDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openImage(at:))
    }

    @objc func annotateClipboard(_ sender: Any?) {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("There's no image on the clipboard", symbol: "doc.on.clipboard", isError: true)
            return
        }
        let scale = image.size.width > 0 ? CGFloat(cgImage.width) / image.size.width : 1
        EditorWindowController.open(image: cgImage, scale: scale.rounded(), title: "Clipboard Image")
    }

    @objc func openScreenshotsFolder(_ sender: Any?) { OutputManager.shared.revealSaveFolder() }

    private func openImage(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Toast.show("Couldn't open “\(url.lastPathComponent)”", symbol: "exclamationmark.triangle.fill", isError: true)
            return
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        EditorWindowController.open(image: image, scale: max(1, (dpi / 72).rounded()), title: url.lastPathComponent)
    }

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Xnap"
        alert.informativeText = """
            Xnap lives in your menu bar.

            ⌃⇧1   Capture an area or window
            ⌃⇧2   Scrolling capture
            ⌃⇧3   Capture the full screen
            ⌃⇧4   Copy text from the screen

            Captures go to the clipboard. Add ⌥ (⌃⌥⇧1…3) to save to a file instead.

            Everything stays on your Mac — the app has no network access. \
            Next, allow Screen Recording so it can take screenshots.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open Settings")
        NSApp.activate()
        let response = alert.runModal()
        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        if response == .alertSecondButtonReturn { SettingsWindowController.show() }
    }
}
