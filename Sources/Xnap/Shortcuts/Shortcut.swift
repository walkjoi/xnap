import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus modifier keys.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection(Shortcut.relevantModifiers).rawValue
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var isFunctionKey: Bool { Shortcut.functionKeys[Int(keyCode)] != nil }

    /// A shortcut is usable globally if it has a non-Shift modifier, or is a function key.
    var isValidGlobalShortcut: Bool {
        isFunctionKey || !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    var displayString: String { Shortcut.symbols(for: modifierFlags) + keyName }

    /// Modifier symbols in the standard macOS order.
    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    var keyName: String {
        let code = Int(keyCode)
        if let name = Shortcut.functionKeys[code] { return name }
        if let name = Shortcut.specialKeys[code] { return name }
        return Shortcut.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// Key equivalent string suitable for `NSMenuItem` (display only).
    var menuKeyEquivalent: String {
        let code = Int(keyCode)
        if let index = Shortcut.functionKeyOrder.firstIndex(of: code),
           let scalar = UnicodeScalar(NSF1FunctionKey + index) {
            return String(Character(scalar))
        }
        if Shortcut.specialKeys[code] != nil { return "" }
        return Shortcut.character(for: keyCode)?.lowercased() ?? ""
    }

    // MARK: Key names

    private static let functionKeyOrder = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let functionKeys: [Int: String] = Dictionary(
        uniqueKeysWithValues: functionKeyOrder.enumerated().map { ($1, "F\($0 + 1)") })

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓",
        kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The character the key produces on the current keyboard layout.
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
