import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Xnap")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Xnap"
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        for action in [CaptureAction.area, .scrolling, .screen, .recognizeText] { add(action) }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Save to File"))
        for action in [CaptureAction.areaToFile, .scrollingToFile, .screenToFile] { add(action) }
        menu.addItem(.separator())
        add("Open Image…", symbol: "photo", action: #selector(AppDelegate.openImageDocument(_:)))
        add("Annotate Clipboard Image", symbol: "doc.on.clipboard", action: #selector(AppDelegate.annotateClipboard(_:)))
        add("Open Screenshots Folder", symbol: "folder", action: #selector(AppDelegate.openScreenshotsFolder(_:)))
        menu.addItem(.separator())
        add("Settings…", symbol: "gearshape", action: #selector(AppDelegate.showSettings(_:)), key: ",")
        add("About Xnap", symbol: "info.circle", action: #selector(AppDelegate.showAbout(_:)))
        add("Quit Xnap", symbol: nil, action: #selector(NSApplication.terminate(_:)), key: "q")
    }

    private func add(_ action: CaptureAction) {
        let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let shortcut = Preferences.shared.shortcut(for: action), !shortcut.menuKeyEquivalent.isEmpty {
            item.keyEquivalent = shortcut.menuKeyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        menu.addItem(item)
    }

    private func add(_ title: String, symbol: String?, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        menu.addItem(item)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CaptureAction(rawValue: raw) else { return }
        // Let the menu finish closing before the screen is frozen for selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            CaptureCoordinator.shared.perform(action)
        }
    }
}
