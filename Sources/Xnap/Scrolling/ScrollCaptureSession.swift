import AppKit
import Carbon.HIToolbox
import XnapCore

/// One scrolling capture, from region selection to the stitched image.
///
/// Flow: the region is highlighted and a HUD appears. The user scrolls the content
/// under it (or starts Auto-Scroll); frames stream in and are stitched live. ⏎ or
/// "Done" finishes, ⎋ or "Cancel" aborts. Auto-scroll finishes by itself at the end.
@MainActor
final class ScrollCaptureSession {
    private(set) static var current: ScrollCaptureSession?

    private static let escapeHotKey: UInt32 = 900
    private static let returnHotKey: UInt32 = 901

    /// Only the geometry of the selection is kept. Holding the `CaptureSelection` itself would
    /// pin the whole display snapshot it was picked from for the entire session.
    private let screen: NSScreen
    private let region: CGRect
    private let scale: CGFloat
    private let completion: (CGImage?) -> Void
    private let model: ScrollHUDModel
    private let hud: ScrollHUDPanel
    private let highlight: RegionHighlightWindow
    private var pipeline: StitchingPipeline!
    private var stream: ScrollFrameStream!
    private var autoScrollTask: Task<Void, Never>?
    private var latestOffset = 0
    private var lostTrack = false
    private var isOver = false

    static var isRunning: Bool { current != nil }

    static func start(selection: CaptureSelection, destination: CaptureDestination,
                      completion: @escaping (CGImage?) -> Void) {
        let session = ScrollCaptureSession(selection: selection, destination: destination, completion: completion)
        current = session
        Task { await session.begin() }
    }

    /// Pressing the scrolling shortcut again while capturing finishes the capture.
    static func finishCurrent() { current?.finish() }

    private init(selection: CaptureSelection, destination: CaptureDestination,
                 completion: @escaping (CGImage?) -> Void) {
        screen = selection.screen
        region = selection.rect
        scale = selection.scale
        self.completion = completion
        model = ScrollHUDModel(savesToFile: destination == .file)
        model.scale = scale
        hud = ScrollHUDPanel(model: model)
        highlight = RegionHighlightWindow(screen: screen, region: region)

        pipeline = StitchingPipeline(maxHeight: Preferences.shared.scrollMaxHeight) { [weak self] progress in
            self?.handle(progress)
        }
        let pipeline = self.pipeline!
        stream = ScrollFrameStream(queue: pipeline.queue) { frame in pipeline.process(frame) }
        stream.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self, !self.isOver else { return }
                self.model.say("Capture stopped: \(error.localizedDescription)", .warning)
                self.finish()
            }
        }

        model.onDone = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
    }

    private func begin() async {
        highlight.orderFrontRegardless()
        hud.position(near: screen.globalRect(fromLocal: region), on: screen)
        hud.orderFrontRegardless()

        HotKeyCenter.shared.register(id: Self.escapeHotKey, shortcut: Shortcut(keyCode: kVK_Escape, modifiers: [])) {
            [weak self] in self?.cancel()
        }
        HotKeyCenter.shared.register(id: Self.returnHotKey, shortcut: Shortcut(keyCode: kVK_Return, modifiers: [])) {
            [weak self] in self?.finish()
        }

        do {
            let content = try await ScreenCapture.shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw ScreenCapture.CaptureError.noDisplay
            }
            // ⎋ and ⏎ are live from the moment the hotkeys above are registered, so the session
            // can already be over by the time the capture is ready to start.
            guard !isOver else { return }
            try await stream.start(filter: ScreenCapture.filter(for: display, in: content),
                                   sourceRect: region, scale: scale)
            // Ended while the stream was starting: `cancel` found nothing to stop, so stop it
            // here or it would keep capturing with no session left to own it.
            if isOver { await stream.stop() }
        } catch {
            guard !isOver else { return }
            isOver = true
            Toast.show("Scrolling capture failed: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle.fill", isError: true)
            tearDown()
            completion(nil)
        }
    }

    // MARK: Progress

    private func handle(_ progress: StitchingPipeline.Progress) {
        guard !isOver || model.isFinishing else { return }
        model.heightPixels = progress.height
        if let preview = progress.preview { model.preview = preview }
        latestOffset = progress.offset
        switch progress.outcome {
        case .lostTrack:
            lostTrack = true
            model.say("Scrolled too far at once — scroll back up a little.", .warning)
        case .scrolled:
            if lostTrack || model.tone == .warning { model.say(defaultMessage) }
            lostTrack = false
        case .limitReached:
            model.say("Maximum height reached (\(Preferences.shared.scrollMaxHeight.formatted()) px).", .warning)
            finish()
        case .sizeMismatch:
            model.say("The capture area changed size — press Done to keep what's captured.", .warning)
        case .started, .unchanged:
            break
        }
    }

    private var defaultMessage: String {
        model.isAutoScrolling
            ? "Auto-scrolling… move the pointer away to pause."
            : "Scroll down slowly. Press ⏎ when done, ⎋ to cancel."
    }

    // MARK: Auto-scroll

    private func toggleAutoScroll() {
        if autoScrollTask != nil {
            stopAutoScroll("Auto-scroll stopped. Keep scrolling manually or press Done.")
            return
        }
        guard AutoScroll.hasPermission else {
            AutoScroll.requestPermission()
            model.say("Auto-Scroll needs Accessibility access: System Settings › Privacy & Security › Accessibility.", .warning)
            return
        }
        let region = screen.quartzRect(fromLocal: self.region)
        let pointer = CGEvent(source: nil)?.location ?? .zero
        if !region.contains(pointer) {
            CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: region.midY))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        model.isAutoScrolling = true
        model.say(defaultMessage, .busy)
        autoScrollTask = Task { [weak self] in await self?.runAutoScroll(in: region) }
    }

    private func stopAutoScroll(_ message: String?) {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        model.isAutoScrolling = false
        if let message { model.say(message, .warning) }
    }

    private func runAutoScroll(in region: CGRect) async {
        let speed = Preferences.shared.autoScrollSpeed
        var step = max(40, Int(self.region.height * speed.stepFraction))
        var direction: Int32 = -1
        var stalls = 0
        var calibrated = false
        try? await Task.sleep(for: .milliseconds(150))

        while !Task.isCancelled && !isOver {
            guard let pointer = CGEvent(source: nil)?.location,
                  region.insetBy(dx: -2, dy: -2).contains(pointer) else {
                stopAutoScroll("Auto-scroll paused — the pointer left the capture area.")
                return
            }
            let before = latestOffset
            // Several small events read as a smooth trackpad scroll to most apps.
            let pieces = 4
            for _ in 0..<pieces {
                AutoScroll.post(deltaY: direction * Int32(step / pieces), at: pointer)
                try? await Task.sleep(for: .milliseconds(12))
            }
            try? await Task.sleep(for: speed.interval)
            var waited = 0
            while latestOffset == before && !lostTrack && waited < 8 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                waited += 1
            }
            guard !Task.isCancelled, !isOver else { return }

            if lostTrack {
                // The app scrolled further than asked: back up a bit and use smaller steps.
                AutoScroll.post(deltaY: -direction * Int32(step / 2), at: pointer)
                step = max(24, step / 2)
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let moved = latestOffset - before
            if !calibrated && moved != 0 {
                calibrated = true
                if moved < 0 { direction = -direction } // this app scrolls the other way
            }
            if moved == 0 {
                stalls += 1
                if stalls >= 3 {
                    model.say("Reached the end.", .busy)
                    finish()
                    return
                }
            } else {
                stalls = 0
            }
        }
    }

    // MARK: Ending

    func finish() {
        guard !isOver else { return }
        isOver = true
        stopAutoScroll(nil)
        model.isFinishing = true
        model.say("Stitching…", .busy)
        Task {
            await stream.stop()
            pipeline.finish { image in
                self.tearDown()
                self.completion(image)
            }
        }
    }

    func cancel() {
        guard !isOver else { return }
        isOver = true
        stopAutoScroll(nil)
        Task {
            await stream.stop()
            tearDown()
            completion(nil)
        }
    }

    private func tearDown() {
        HotKeyCenter.shared.unregister(id: Self.escapeHotKey)
        HotKeyCenter.shared.unregister(id: Self.returnHotKey)
        hud.orderOut(nil)
        highlight.orderOut(nil)
        if ScrollCaptureSession.current === self { ScrollCaptureSession.current = nil }
    }
}
