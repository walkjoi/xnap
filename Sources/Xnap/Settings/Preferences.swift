import AppKit
import Combine
import UniformTypeIdentifiers

/// User settings, persisted in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum AfterCapture: String, CaseIterable, Identifiable {
        case showPreview, openEditor, nothing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .showPreview: "Show floating preview"
            case .openEditor: "Open in editor"
            case .nothing: "Do nothing"
            }
        }
    }

    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpeg
        var id: String { rawValue }
        var title: String { self == .png ? "PNG" : "JPEG" }
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var utType: UTType { self == .png ? .png : .jpeg }
    }

    enum AutoScrollSpeed: String, CaseIterable, Identifiable {
        case gentle, normal, fast
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Fraction of the region height scrolled per step, and pause between steps.
        var stepFraction: CGFloat { switch self { case .gentle: 0.25; case .normal: 0.4; case .fast: 0.6 } }
        var interval: Duration { switch self { case .gentle: .milliseconds(260); case .normal: .milliseconds(180); case .fast: .milliseconds(120) } }
    }

    private let defaults = UserDefaults.standard

    @Published var afterCapture: AfterCapture { didSet { defaults.set(afterCapture.rawValue, forKey: Key.afterCapture) } }
    @Published var previewSeconds: Double { didSet { defaults.set(previewSeconds, forKey: Key.previewSeconds) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: Key.showCursor) } }
    @Published var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Key.imageFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var copyWhenSaving: Bool { didSet { defaults.set(copyWhenSaving, forKey: Key.copyWhenSaving) } }
    @Published var saveFolderBookmark: Data? { didSet { defaults.set(saveFolderBookmark, forKey: Key.saveFolderBookmark) } }
    @Published var scrollMaxHeight: Int { didSet { defaults.set(scrollMaxHeight, forKey: Key.scrollMaxHeight) } }
    @Published var autoScrollSpeed: AutoScrollSpeed { didSet { defaults.set(autoScrollSpeed.rawValue, forKey: Key.autoScrollSpeed) } }
    @Published private var shortcutOverrides: [String: Shortcut] { didSet { persistShortcuts() } }
    @Published private var disabledShortcuts: Set<String> { didSet { persistShortcuts() } }
    /// Actions whose hotkey could not be registered (taken by another app).
    @Published var conflictingActions: Set<CaptureAction> = []
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    /// Fires whenever any shortcut changes.
    let shortcutsChanged = PassthroughSubject<Void, Never>()

    private enum Key {
        static let afterCapture = "afterCapture", previewSeconds = "previewSeconds", playSound = "playSound"
        static let showCursor = "showCursor", imageFormat = "imageFormat", jpegQuality = "jpegQuality"
        static let copyWhenSaving = "copyWhenSaving", saveFolderBookmark = "saveFolderBookmark"
        static let scrollMaxHeight = "scrollMaxHeight", autoScrollSpeed = "autoScrollSpeed"
        static let shortcuts = "shortcuts", disabledShortcuts = "disabledShortcuts"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.previewSeconds: 6.0, Key.playSound: true, Key.showCursor: false,
            Key.jpegQuality: 0.9, Key.copyWhenSaving: false, Key.scrollMaxHeight: 30_000,
        ])
        afterCapture = AfterCapture(rawValue: d.string(forKey: Key.afterCapture) ?? "") ?? .showPreview
        previewSeconds = d.double(forKey: Key.previewSeconds)
        playSound = d.bool(forKey: Key.playSound)
        showCursor = d.bool(forKey: Key.showCursor)
        imageFormat = ImageFormat(rawValue: d.string(forKey: Key.imageFormat) ?? "") ?? .png
        jpegQuality = d.double(forKey: Key.jpegQuality)
        copyWhenSaving = d.bool(forKey: Key.copyWhenSaving)
        saveFolderBookmark = d.data(forKey: Key.saveFolderBookmark)
        scrollMaxHeight = d.integer(forKey: Key.scrollMaxHeight)
        autoScrollSpeed = AutoScrollSpeed(rawValue: d.string(forKey: Key.autoScrollSpeed) ?? "") ?? .normal
        if let data = d.data(forKey: Key.shortcuts),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcutOverrides = decoded
        } else {
            shortcutOverrides = [:]
        }
        disabledShortcuts = Set(d.stringArray(forKey: Key.disabledShortcuts) ?? [])
    }

    // MARK: Shortcuts

    func shortcut(for action: CaptureAction) -> Shortcut? {
        if disabledShortcuts.contains(action.rawValue) { return nil }
        return shortcutOverrides[action.rawValue] ?? action.defaultShortcut
    }

    func setShortcut(_ shortcut: Shortcut?, for action: CaptureAction) {
        if let shortcut {
            // A combination can only belong to one action.
            for other in CaptureAction.allCases where other != action && self.shortcut(for: other) == shortcut {
                disabledShortcuts.insert(other.rawValue)
            }
            disabledShortcuts.remove(action.rawValue)
            shortcutOverrides[action.rawValue] = shortcut
        } else {
            disabledShortcuts.insert(action.rawValue)
        }
        shortcutsChanged.send()
    }

    func resetShortcuts() {
        shortcutOverrides = [:]
        disabledShortcuts = []
        shortcutsChanged.send()
    }

    private func persistShortcuts() {
        if let data = try? JSONEncoder().encode(shortcutOverrides) { defaults.set(data, forKey: Key.shortcuts) }
        defaults.set(Array(disabledShortcuts), forKey: Key.disabledShortcuts)
    }
}
