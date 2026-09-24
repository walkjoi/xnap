import Foundation
import Testing
@testable import XnapCore

/// Rough timing of the per-frame cost on a realistic Retina-sized region. Run with
/// `swift test -c release --filter StitcherPerformance` for meaningful numbers.
#if DEBUG
private let isOptimizedBuild = false
#else
private let isOptimizedBuild = true
#endif

@Suite("StitcherPerformance")
struct StitcherPerformanceTests {
    @Test(.enabled(if: isOptimizedBuild, "timings are only meaningful in release builds"))
    func perFrameCost() {
        let width = 1600, viewport = 1800, docHeight = 12_000
        var pixels = [UInt8](repeating: 255, count: width * docHeight * 4)
        var seed: UInt64 = 1
        for y in 0..<docHeight where (y % 30) < 16 {
            for x in stride(from: 0, to: width, by: 1) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = UInt8(truncatingIfNeeded: seed >> 56)
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        let doc = Bitmap(width: width, height: docHeight, pixels: pixels)
        let frames = stride(from: 0, to: 9_000, by: 180).map { doc.rows($0..<($0 + viewport)) }

        let stitcher = ScrollStitcher()
        let start = Date()
        for frame in frames { stitcher.add(frame) }
        let perFrame = Date().timeIntervalSince(start) / Double(frames.count) * 1000
        print("stitcher: \(String(format: "%.1f", perFrame)) ms/frame for \(width)x\(viewport) frames")
        #expect(stitcher.outputHeight == frames.count * 180 - 180 + viewport)
        #expect(perFrame < 25, "must keep up with a 20 fps stream")

        // Fallback path: frames that never match hashes exactly (rendering noise).
        var noisy = frames[0].pixels
        for i in stride(from: 0, to: noisy.count, by: 4) { noisy[i] ^= 0x0F }
        let noisyFrame = Bitmap(width: width, height: viewport, pixels: noisy)
        let fallback = ScrollStitcher()
        fallback.add(frames[0])
        let t = Date()
        fallback.add(noisyFrame)
        print("fallback search: \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms")
    }
}
