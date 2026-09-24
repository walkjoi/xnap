import AppKit
import Carbon.HIToolbox

/// Where a capture ends up.
enum CaptureDestination {
    case clipboard
    case file
}

/// Every action that can be bound to a global shortcut.
///
/// Default scheme: ⌃⇧ + digit copies to the clipboard; add ⌥ to save to a file instead.
enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    case area
    case areaToFile
    case scrolling
    case scrollingToFile
    case screen
    case screenToFile
    case recognizeText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .areaToFile: "Capture Area to File"
        case .scrolling: "Scrolling Capture"
        case .scrollingToFile: "Scrolling Capture to File"
        case .screen: "Capture Full Screen"
        case .screenToFile: "Capture Full Screen to File"
        case .recognizeText: "Capture Text (OCR)"
        }
    }

    var symbol: String {
        switch self {
        case .area, .areaToFile: "rectangle.dashed"
        case .scrolling, .scrollingToFile: "arrow.up.and.down.text.horizontal"
        case .screen, .screenToFile: "display"
        case .recognizeText: "text.viewfinder"
        }
    }

    var destination: CaptureDestination {
        switch self {
        case .areaToFile, .scrollingToFile, .screenToFile: .file
        default: .clipboard
        }
    }

    var defaultShortcut: Shortcut? {
        let clip: NSEvent.ModifierFlags = [.control, .shift]
        let file: NSEvent.ModifierFlags = [.control, .option, .shift]
        switch self {
        case .area: return Shortcut(keyCode: kVK_ANSI_1, modifiers: clip)
        case .areaToFile: return Shortcut(keyCode: kVK_ANSI_1, modifiers: file)
        case .scrolling: return Shortcut(keyCode: kVK_ANSI_2, modifiers: clip)
        case .scrollingToFile: return Shortcut(keyCode: kVK_ANSI_2, modifiers: file)
        case .screen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: clip)
        case .screenToFile: return Shortcut(keyCode: kVK_ANSI_3, modifiers: file)
        case .recognizeText: return Shortcut(keyCode: kVK_ANSI_4, modifiers: clip)
        }
    }

    /// Stable Carbon hotkey identifier (1...99 are reserved for capture actions).
    var hotKeyID: UInt32 { UInt32(CaptureAction.allCases.firstIndex(of: self)! + 1) }
}
