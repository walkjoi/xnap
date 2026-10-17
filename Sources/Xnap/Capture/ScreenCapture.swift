import AppKit
import ScreenCaptureKit

/// A still image of one display, taken just before the selection overlay appears.
struct DisplaySnapshot {
    let screen: NSScreen
    let display: SCDisplay
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
}

/// Thin wrapper around ScreenCaptureKit.
@MainActor
enum ScreenCapture {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display is available for capture." }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// A filter for a whole display that hides Xnap's own windows
    /// (overlays, HUD, previews), so they never appear in a capture.
    static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
    }

    static func snapshot(of screen: NSScreen, display: SCDisplay, content: SCShareableContent,
                         showCursor: Bool) async throws -> DisplaySnapshot {
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = showCursor
        config.captureResolution = .best
        config.shouldBeOpaque = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter(for: display, in: content), configuration: config)
        return DisplaySnapshot(screen: screen, display: display, image: image, scale: scale)
    }

    static func snapshotAllScreens(showCursor: Bool = false) async throws -> [DisplaySnapshot] {
        let content = try await shareableContent()
        var result: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            result.append(try await snapshot(of: screen, display: display, content: content, showCursor: showCursor))
        }
        if result.isEmpty { throw CaptureError.noDisplay }
        return result
    }

    static func snapshotScreenUnderMouse(showCursor: Bool) async throws -> DisplaySnapshot {
        let content = try await shareableContent()
        let screen = NSScreen.underMouse
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        return try await snapshot(of: screen, display: display, content: content, showCursor: showCursor)
    }
}

/// On-screen windows of other apps, front to back, for click-to-capture-window.
enum WindowList {
    /// Frames in Quartz global coordinates.
    static func visibleWindowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            return rect
        }
    }
}
