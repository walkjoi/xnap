import Foundation

/// Compact per-row fingerprints of a frame, used to find how far content moved
/// between two consecutive captures of the same screen region.
///
/// * `hashes` — exact hash of each row (colors quantized to 5 bits, columns sampled).
/// * `flat`   — rows with (almost) no detail, e.g. blank background. These match
///              everywhere and are ignored when voting on an offset.
/// * `features` — `binCount` average-luminance bins per row, a noise-tolerant
///              descriptor used for verification and the fallback search.
///
/// The right edge is excluded from fingerprints so macOS overlay scrollbars,
/// which move while scrolling, don't disturb matching.
struct FrameSignature {
    static let binCount = 32

    let height: Int
    let hashes: [UInt64]
    let flat: [Bool]
    let features: [UInt8]

    init(_ bitmap: Bitmap) {
        let width = bitmap.width, height = bitmap.height
        self.height = height

        var left = min(8, width / 20)
        var right = min(48, width / 8)
        if width - left - right < 16 { left = 0; right = 0 }
        let usable = max(1, width - left - right)
        let step = max(1, usable / 512)
        let samples = max(1, usable / step)
        let bins = FrameSignature.binCount

        var hashes = [UInt64](repeating: 0, count: height)
        var flat = [Bool](repeating: true, count: height)
        var features = [UInt8](repeating: 0, count: height * bins)

        // Precompute which bin every sample falls into.
        var binOf = [Int](repeating: 0, count: samples)
        var binCounts = [Int](repeating: 0, count: bins)
        for i in 0..<samples {
            let b = min(bins - 1, i * bins / samples)
            binOf[i] = b
            binCounts[b] += 1
        }

        bitmap.pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var sums = [Int](repeating: 0, count: bins)
            for y in 0..<height {
                let row = base + y * bitmap.bytesPerRow
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                var minL = 255, maxL = 0
                for b in 0..<bins { sums[b] = 0 }
                for i in 0..<samples {
                    let p = row + (left + i * step) * 4
                    let bl = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                    let packed = UInt64((bl >> 3) | ((g >> 3) << 5) | ((r >> 3) << 10))
                    hash = (hash ^ packed) &* 0x0000_0100_0000_01b3
                    let lum = (r * 77 + g * 150 + bl * 29) >> 8
                    if lum < minL { minL = lum }
                    if lum > maxL { maxL = lum }
                    sums[binOf[i]] += lum
                }
                hashes[y] = hash
                flat[y] = maxL - minL < 10
                let f = y * bins
                for b in 0..<bins {
                    features[f + b] = UInt8(sums[b] / max(1, binCounts[b]))
                }
            }
        }

        self.hashes = hashes
        self.flat = flat
        self.features = features
    }

    /// Sum of absolute differences between the feature vectors of two rows.
    @inline(__always)
    func featureDistance(row a: Int, to other: FrameSignature, row b: Int) -> Int {
        let bins = FrameSignature.binCount
        var total = 0
        features.withUnsafeBufferPointer { fa in
            other.features.withUnsafeBufferPointer { fb in
                let pa = fa.baseAddress! + a * bins, pb = fb.baseAddress! + b * bins
                for k in 0..<bins { total += abs(Int(pa[k]) - Int(pb[k])) }
            }
        }
        return total
    }
}
