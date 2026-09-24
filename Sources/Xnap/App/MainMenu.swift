import AppKit

/// The main menu. Only visible while an editor or Settings window is open, but it also
/// provides the standard key equivalents (⌘C, ⌘S, ⌘Z…) routed through the responder chain.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        main.addSubmenu("Xnap") { m in
            m.item("About Xnap", #selector(AppDelegate.showAbout(_:)))
            m.addItem(.separator())
            m.item("Settings…", #selector(AppDelegate.showSettings(_:)), ",")
            m.addItem(.separator())
            m.item("Hide Xnap", #selector(NSApplication.hide(_:)), "h")
            m.item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            m.item("Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            m.item("Quit Xnap", #selector(NSApplication.terminate(_:)), "q")
        }

        main.addSubmenu("File") { m in
            m.item("Open Image…", #selector(AppDelegate.openImageDocument(_:)), "o")
            m.item("Annotate Clipboard Image", #selector(AppDelegate.annotateClipboard(_:)), "v", [.command, .shift])
            m.addItem(.separator())
            m.item("Close", #selector(NSWindow.performClose(_:)), "w")
            m.item("Save", #selector(EditorWindowController.saveDocument(_:)), "s")
            m.item("Save As…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        }

        main.addSubmenu("Edit") { m in
            m.item("Undo", Selector(("undo:")), "z")
            m.item("Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            m.item("Cut", #selector(NSText.cut(_:)), "x")
            m.item("Copy", #selector(NSText.copy(_:)), "c")
            m.item("Paste", #selector(NSText.paste(_:)), "v")
            m.item("Delete", #selector(EditorWindowController.delete(_:)))
            m.item("Select All", #selector(NSText.selectAll(_:)), "a")
        }

        main.addSubmenu("Image") { m in
            m.item("Apply Crop", #selector(EditorWindowController.applyCrop(_:)))
            m.item("Bring to Front", #selector(EditorWindowController.bringToFront(_:)), "f", [.command, .shift])
            m.addItem(.separator())
            m.item("Copy Text from Image", #selector(EditorWindowController.recognizeText(_:)), "t", [.command, .shift])
            m.item("Pin to Screen", #selector(EditorWindowController.pinToScreen(_:)), "p", [.command, .control])
        }

        main.addSubmenu("View") { m in
            m.item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "=")
            m.item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-")
            m.item("Actual Size", #selector(EditorWindowController.actualSize(_:)), "0")
            m.item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "9")
        }

        let window = main.addSubmenu("Window") { m in
            m.item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            m.item("Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            m.item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window
        return main
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
        let submenu = NSMenu(title: title)
        build(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return submenu
    }

    func item(_ title: String, _ action: Selector, _ key: String = "",
              _ modifiers: NSEvent.ModifierFlags = .command) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
    }
}
