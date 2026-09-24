import AppKit
import CoreMedia
import XnapCore
import ScreenCaptureKit

/// Streams frames of a fixed screen rectangle with ScreenCaptureKit.
///
/// Xnap's own windows are excluded from the stream, so the highlight frame and
/// HUD drawn around the region never end up in the stitched image. Only frames whose
/// content actually changed are delivered (`SCFrameStatus.complete`).
final class ScrollFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue: DispatchQueue
    private let onFrame: (Bitmap) -> Void
    var onStop: ((Error) -> Void)?

    init(queue: DispatchQueue, onFrame: @escaping (Bitmap) -> Void) {
        self.queue = queue
        self.onFrame = onFrame
    }

    /// - Parameter sourceRect: region in the display's local, top-left-origin space, in points.
    func start(filter: SCContentFilter, sourceRect: CGRect, scale: CGFloat) async throws {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.queueDepth = 5
        config.captureResolution = .best

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bitmap = Bitmap(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer),
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                            base: base)
        onFrame(bitmap)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

/// Owns the stitcher and runs it on a private serial queue, reporting progress to the main thread.
final class StitchingPipeline: @unchecked Sendable {
    struct Progress {
        let outcome: ScrollStitcher.Outcome
        let height: Int
        let offset: Int
        let preview: CGImage?
    }

    let queue = DispatchQueue(label: "app.xnap.stitching", qos: .userInitiated)
    private let stitcher: ScrollStitcher
    private var lastPreview: CFAbsoluteTime = 0
    private let onProgress: @MainActor (Progress) -> Void

    init(maxHeight: Int, onProgress: @escaping @MainActor (Progress) -> Void) {
        stitcher = ScrollStitcher(configuration: .init(maxOutputHeight: maxHeight))
        self.onProgress = onProgress
    }

    /// Must be called on `queue` (the stream delivers frames there).
    func process(_ frame: Bitmap) {
        let outcome = stitcher.add(frame)
        let now = CFAbsoluteTimeGetCurrent()
        var preview: CGImage?
        let grew: Bool
        switch outcome {
        case .started, .limitReached: grew = true
        case .scrolled(_, let appended): grew = appended > 0
        default: grew = false
        }
        if grew && now - lastPreview > 0.25 {
            lastPreview = now
            preview = stitcher.makeTailPreview(width: 112, height: 144)
        }
        let progress = Progress(outcome: outcome, height: stitcher.outputHeight,
                                offset: stitcher.currentOffset, preview: preview)
        let handler = onProgress
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(progress) } }
    }

    /// Composes the final image after all queued frames have been processed.
    func finish(_ completion: @escaping @MainActor (CGImage?) -> Void) {
        queue.async { [stitcher] in
            let image = stitcher.makeImage()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }
}

/// Synthesized scroll-wheel events for hands-free capture (needs Accessibility permission).
enum AutoScroll {
    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    static func requestPermission() { _ = CGRequestPostEventAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts a trackpad-like (continuous, pixel-based) scroll. Negative `deltaY` scrolls down.
    static func post(deltaY: Int32, at point: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}
