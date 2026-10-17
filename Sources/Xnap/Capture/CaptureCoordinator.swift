import AppKit

/// Runs capture actions end to end: permission check → selection → capture → delivery.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let prefs = Preferences.shared
    private var isSelecting = false
    private var previousApp: NSRunningApplication?

    func perform(_ action: CaptureAction) {
        if ScrollCaptureSession.isRunning {
            // The scrolling shortcut doubles as "Done" while a scrolling capture runs.
            if action == .scrolling || action == .scrollingToFile { ScrollCaptureSession.finishCurrent() }
            return
        }
        switch action {
        case .area, .areaToFile: captureArea(to: action.destination)
        case .scrolling, .scrollingToFile: captureScrolling(to: action.destination)
        case .screen, .screenToFile: captureScreen(to: action.destination)
        case .recognizeText: captureText()
        }
    }

    // MARK: Actions

    func captureArea(to destination: CaptureDestination) {
        select(.screenshot) { [self] selection in
            restorePreviousApp()
            guard let image = selection.croppedImage else { return }
            deliver(image, scale: selection.scale, to: destination)
        }
    }

    func captureScreen(to destination: CaptureDestination) {
        guard ensurePermission() else { return }
        FloatingPreview.dismiss()
        Task {
            do {
                let snapshot = try await ScreenCapture.snapshotScreenUnderMouse(showCursor: prefs.showCursor)
                deliver(snapshot.image, scale: snapshot.scale, to: destination)
            } catch {
                report(error)
            }
        }
    }

    func captureScrolling(to destination: CaptureDestination) {
        select(.scrolling) { [self] selection in
            // Give focus back to the app being captured so it receives scrolls and keys.
            restorePreviousApp()
            guard selection.rect.height >= 60, selection.rect.width >= 60 else {
                Toast.show("Select a larger area to scroll-capture", symbol: "arrow.up.and.down", isError: true)
                return
            }
            // Capture just the scale: holding `selection` would keep the display snapshot
            // alive for the whole session.
            let scale = selection.scale
            ScrollCaptureSession.start(selection: selection, destination: destination) { [weak self] image in
                guard let self, let image else { return }
                self.deliver(image, scale: scale, to: destination)
            }
        }
    }

    func captureText() {
        select(.recognizeText) { [self] selection in
            restorePreviousApp()
            guard let image = selection.croppedImage else { return }
            copyRecognizedText(from: image)
        }
    }

    func copyRecognizedText(from image: CGImage) {
        Task {
            do {
                let text = try await TextRecognizer.recognize(in: image)
                if text.isEmpty {
                    Toast.show("No text found", symbol: "text.magnifyingglass", isError: true)
                } else {
                    OutputManager.shared.copy(text: text)
                    let words = text.split(whereSeparator: \.isWhitespace).count
                    Toast.show("Copied \(words) word\(words == 1 ? "" : "s") of text", symbol: "text.viewfinder")
                }
            } catch {
                report(error)
            }
        }
    }

    // MARK: Delivery

    func deliver(_ image: CGImage, scale: CGFloat, to destination: CaptureDestination) {
        // The shutter is the immediate feedback; encoding runs off the main thread, so the
        // menu bar stays responsive even while a tall scrolling capture is being written.
        CaptureSound.play()
        Task {
            let savedURL: URL?
            do {
                savedURL = try await OutputManager.shared.deliver(image, scale: scale, to: destination)
            } catch {
                report(error)
                return
            }
            switch prefs.afterCapture {
            case .showPreview:
                FloatingPreview.show(image: image, scale: scale, savedURL: savedURL)
            case .openEditor:
                EditorWindowController.open(image: image, scale: scale)
            case .nothing:
                if let savedURL {
                    Toast.show("Saved “\(savedURL.lastPathComponent)”", symbol: "square.and.arrow.down.fill")
                } else {
                    Toast.show("Copied to clipboard", symbol: "doc.on.clipboard.fill")
                }
            }
        }
    }

    // MARK: Helpers

    private func select(_ purpose: SelectionOverlay.Purpose, then handler: @escaping (CaptureSelection) -> Void) {
        guard !isSelecting, ensurePermission() else { return }
        isSelecting = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        FloatingPreview.dismiss()
        Task {
            do {
                let snapshots = try await ScreenCapture.snapshotAllScreens()
                SelectionOverlay.present(purpose: purpose, snapshots: snapshots) { selection in
                    self.isSelecting = false
                    guard let selection else { self.restorePreviousApp(); return }
                    handler(selection)
                }
            } catch {
                isSelecting = false
                report(error)
            }
        }
    }

    private func restorePreviousApp() {
        previousApp?.activate()
        previousApp = nil
    }

    /// Screen Recording is the only permission Xnap strictly needs.
    func ensurePermission() -> Bool {
        if ScreenCapture.hasPermission { return true }
        ScreenCapture.requestPermission()
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording"
        alert.informativeText = """
            Xnap needs Screen Recording permission to take screenshots. \
            Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, \
            then try again. Captures never leave your Mac.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { ScreenCapture.openPrivacySettings() }
        return false
    }

    private func report(_ error: Error) {
        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true,
                   duration: .seconds(4))
    }
}
