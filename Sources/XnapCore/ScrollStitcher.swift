import CoreGraphics
import Foundation

/// Builds one tall image out of successive captures of a scrolling region.
///
/// Feed it every frame captured from the same screen rectangle while the user (or
/// auto-scroll) scrolls. For each frame it works out the vertical offset relative to
/// the previous frame and appends only the newly revealed rows.
///
/// Model: the scrolled page is a "document". Frame `k` shows document rows
/// `[offset_k, offset_k + H)`, except for rows that stay fixed on screen: sticky
/// headers (top `fixedTop` rows) and sticky footers/toolbars (bottom `fixedBottom`
/// rows). Those are detected at the first real movement. Only the scrolling band
/// between them is used for matching and appending. The footer is added once at the
/// end, taken from the frame that was scrolled furthest down.
public final class ScrollStitcher {
    public struct Configuration: Sendable {
        /// Hard limit on the height of the result, in pixels.
        public var maxOutputHeight: Int
        /// Minimum shared rows between consecutive frames, as a fraction of the scrolling band.
        public var minimumOverlapFraction: Double
        /// Fixed header/footer are each capped to this fraction of the frame height.
        public var maxFixedFraction: Double

        public init(maxOutputHeight: Int = 30_000,
                    minimumOverlapFraction: Double = 0.08,
                    maxFixedFraction: Double = 0.4) {
            self.maxOutputHeight = maxOutputHeight
            self.minimumOverlapFraction = minimumOverlapFraction
            self.maxFixedFraction = maxFixedFraction
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// First frame accepted.
        case started
        /// Nothing moved (the frame may still have changed in place, e.g. a hover effect).
        case unchanged
        /// Content moved by `delta` pixels (positive = scrolled down); `appended` new rows were added.
        case scrolled(delta: Int, appended: Int)
        /// No overlap with the previous frame — scrolled too far in one go. Scroll back a little.
        case lostTrack
        /// Frame size differs from the first frame; ignored.
        case sizeMismatch
        /// The height limit was reached; later frames are ignored.
        case limitReached
    }

    public let configuration: Configuration

    public private(set) var frameWidth = 0
    public private(set) var frameHeight = 0
    /// Current height of the stitched result in pixels.
    public private(set) var outputHeight = 0
    /// Number of frames that contributed a successful match.
    public private(set) var matchedFrames = 0
    /// Current scroll position relative to the first frame.
    public private(set) var currentOffset = 0
    public private(set) var fixedTop: Int?
    public private(set) var fixedBottom: Int?
    public var hasContent: Bool { !slices.isEmpty }

    private var previous: FrameSignature?
    private var slices: [Bitmap] = []
    private var committedEnd = 0
    private var maxOffset = 0
    private var footer: Bitmap?
    private var limitHit = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Feeding frames

    @discardableResult
    public func add(_ frame: Bitmap) -> Outcome {
        if limitHit { return .limitReached }

        guard let prev = previous else {
            guard frame.width > 0, frame.height > 0 else { return .sizeMismatch }
            frameWidth = frame.width
            frameHeight = frame.height
            previous = FrameSignature(frame)
            let rows = min(frame.height, configuration.maxOutputHeight)
            slices = [rows == frame.height ? frame : frame.rows(0..<rows)]
            committedEnd = rows
            outputHeight = rows
            matchedFrames = 1
            return .started
        }
        guard frame.width == frameWidth, frame.height == frameHeight else { return .sizeMismatch }

        let current = FrameSignature(frame)
        if current.hashes == prev.hashes { return .unchanged }

        let h = frameHeight
        let maxFixed = Int(Double(h) * configuration.maxFixedFraction)
        let top = fixedTop ?? min(maxFixed, leadingEqualRows(prev, current))
        let bottom = fixedBottom ?? min(maxFixed, trailingEqualRows(prev, current))
        let band = top..<(h - bottom)
        let minOverlap = max(8, Int(Double(band.count) * configuration.minimumOverlapFraction))

        // Almost everything is identical in place: a local change, not a scroll.
        guard band.count >= minOverlap * 2 else {
            previous = current
            return .unchanged
        }

        let shift: Int
        if let dy = votedShift(prev, current, band: band, minOverlap: minOverlap) {
            shift = dy
        } else if samePositionSimilarity(prev, current, band: band) >= 0.8 {
            previous = current
            return .unchanged
        } else if let dy = searchedShift(prev, current, band: band, minOverlap: minOverlap) {
            // Re-rendered in place (noise, not movement): track it without appending anything.
            if dy == 0 { previous = current; return .unchanged }
            shift = dy
        } else {
            return .lostTrack
        }

        return apply(shift: shift, frame: frame, signature: current, top: top, bottom: bottom)
    }

    private func apply(shift dy: Int, frame: Bitmap, signature: FrameSignature, top: Int, bottom: Int) -> Outcome {
        let h = frameHeight

        if fixedTop == nil {
            // First real movement: the fixed header/footer are now known. The first frame's
            // footer rows are provisional content, so trim them and keep them as the footer.
            fixedTop = top
            fixedBottom = bottom
            if bottom > 0, let first = slices.first, slices.count == 1, first.height == h {
                footer = first.rows((h - bottom)..<h)
                slices[0] = first.rows(0..<(h - bottom))
                committedEnd = h - bottom
            }
        }

        let newOffset = currentOffset + dy
        var appended = 0
        let bandBottom = newOffset + h - bottom
        if bandBottom > committedEnd {
            let start = max(top, committedEnd - newOffset)
            var end = h - bottom
            let room = configuration.maxOutputHeight - committedEnd - bottom
            if end - start > room {
                end = start + max(0, room)
                limitHit = true
            }
            if end > start {
                slices.append(frame.rows(start..<end))
                appended = end - start
                committedEnd += appended
            }
        }
        if newOffset >= maxOffset {
            maxOffset = newOffset
            footer = bottom > 0 ? frame.rows((h - bottom)..<h) : nil
        }

        previous = signature
        currentOffset = newOffset
        matchedFrames += 1
        outputHeight = committedEnd + (footer?.height ?? 0)
        return limitHit ? .limitReached : .scrolled(delta: dy, appended: appended)
    }

    // MARK: - Output

    public func makeBitmap() -> Bitmap? {
        guard !slices.isEmpty else { return nil }
        return Bitmap.stack(slices + (footer.map { [$0] } ?? []))
    }

    /// The finished image. **Consumes** the stitcher: the appended slices are handed to the
    /// image one at a time and released as they go, so composing a tall capture needs room
    /// for one copy of the result rather than three. Call it once, at the end of a session.
    public func takeImage() -> CGImage? {
        guard !slices.isEmpty else { return nil }
        if let footer { slices.append(footer) }
        footer = nil
        return Bitmap.stackedImage(consuming: &slices)
    }

    /// A small nearest-neighbour preview of the bottom of the stitched result.
    public func makeTailPreview(width previewWidth: Int, height previewHeight: Int) -> CGImage? {
        guard !slices.isEmpty, previewWidth > 0, previewHeight > 0, frameWidth > 0 else { return nil }
        let parts = slices + (footer.map { [$0] } ?? [])
        let total = parts.reduce(0) { $0 + $1.height }
        let scale = Double(frameWidth) / Double(previewWidth)
        let sourceRows = min(total, Int(Double(previewHeight) * scale))
        let outHeight = max(1, Int(Double(sourceRows) / scale))
        let tailStart = total - sourceRows

        // Row start offsets of each part within the full result.
        var starts: [Int] = []
        var acc = 0
        for p in parts { starts.append(acc); acc += p.height }

        var out = [UInt8](repeating: 0, count: previewWidth * outHeight * 4)
        var partIndex = 0
        for py in 0..<outHeight {
            let docRow = min(total - 1, tailStart + Int(Double(py) * scale))
            while partIndex + 1 < parts.count && starts[partIndex + 1] <= docRow { partIndex += 1 }
            let part = parts[partIndex]
            let rowBase = (docRow - starts[partIndex]) * part.bytesPerRow
            for px in 0..<previewWidth {
                let sx = min(frameWidth - 1, Int(Double(px) * scale))
                let s = rowBase + sx * 4, d = (py * previewWidth + px) * 4
                out[d] = part.pixels[s]; out[d + 1] = part.pixels[s + 1]
                out[d + 2] = part.pixels[s + 2]; out[d + 3] = part.pixels[s + 3]
            }
        }
        return Bitmap(width: previewWidth, height: outHeight, pixels: out).makeCGImage()
    }

    // MARK: - Matching

    private func leadingEqualRows(_ a: FrameSignature, _ b: FrameSignature) -> Int {
        var y = 0
        while y < a.height && a.hashes[y] == b.hashes[y] { y += 1 }
        return y
    }

    private func trailingEqualRows(_ a: FrameSignature, _ b: FrameSignature) -> Int {
        var n = 0
        while n < a.height && a.hashes[a.height - 1 - n] == b.hashes[b.height - 1 - n] { n += 1 }
        return n
    }

    private func samePositionSimilarity(_ a: FrameSignature, _ b: FrameSignature, band: Range<Int>) -> Double {
        guard !band.isEmpty else { return 1 }
        var same = 0
        for y in band where a.hashes[y] == b.hashes[y] { same += 1 }
        return Double(same) / Double(band.count)
    }

    /// Exact-hash voting: every detailed row of the new frame votes for the offsets at
    /// which an identical row exists in the previous frame. Best candidates are verified.
    /// Convention: `current[y] ≈ previous[y + dy]`, so scrolling down gives `dy > 0`.
    private func votedShift(_ prev: FrameSignature, _ cur: FrameSignature,
                            band: Range<Int>, minOverlap: Int) -> Int? {
        let n = band.count
        var index: [UInt64: [Int]] = [:]
        index.reserveCapacity(n)
        for j in band where !prev.flat[j] { index[prev.hashes[j], default: []].append(j) }

        var votes = [Int32](repeating: 0, count: 2 * n + 1)
        for y in band where !cur.flat[y] {
            guard let matches = index[cur.hashes[y]], matches.count <= 4 else { continue }
            for j in matches {
                let dy = j - y
                if dy == 0 || n - abs(dy) < minOverlap { continue }
                votes[dy + n] += 1
            }
        }

        var candidates: [(dy: Int, votes: Int32)] = []
        for (i, v) in votes.enumerated() where v >= 2 { candidates.append((i - n, v)) }
        candidates.sort { $0.votes != $1.votes ? $0.votes > $1.votes : abs($0.dy) < abs($1.dy) }

        var best: (dy: Int, score: Double, votes: Int32)?
        for candidate in candidates.prefix(4) {
            let score = verify(prev, cur, dy: candidate.dy, band: band)
            guard score >= 0.6 else { continue }
            if best == nil || score > best!.score + 0.02 { best = (candidate.dy, score, candidate.votes) }
        }
        return best?.dy
    }

    /// Share of detailed overlapping rows that match exactly at offset `dy`.
    private func verify(_ prev: FrameSignature, _ cur: FrameSignature, dy: Int, band: Range<Int>) -> Double {
        let lo = max(band.lowerBound, band.lowerBound - dy)
        let hi = min(band.upperBound, band.upperBound - dy)
        guard hi > lo else { return 0 }
        var match = 0, mismatch = 0
        for y in lo..<hi {
            let j = y + dy
            if cur.flat[y] && prev.flat[j] {
                // Blank on both sides: only a mismatch if the background color differs.
                if cur.featureDistance(row: y, to: prev, row: j) > FrameSignature.binCount * 3 { mismatch += 1 }
                continue
            }
            if cur.hashes[y] == prev.hashes[j] { match += 1 } else { mismatch += 1 }
        }
        let total = match + mismatch
        return total >= 4 ? Double(match) / Double(total) : 0
    }

    /// Fallback for content that doesn't re-render pixel-identically: exhaustive search for
    /// the offset minimizing the mean feature distance. Returns 0 if nothing moved.
    private func searchedShift(_ prev: FrameSignature, _ cur: FrameSignature,
                               band: Range<Int>, minOverlap: Int) -> Int? {
        let n = band.count
        let maxShift = n - minOverlap
        guard maxShift > 0 else { return nil }
        let rowStep = n > 600 ? 3 : (n > 300 ? 2 : 1)
        let bins = FrameSignature.binCount

        var bestDy = 0
        var bestCost = Double.greatestFiniteMagnitude
        prev.features.withUnsafeBufferPointer { pf in
            cur.features.withUnsafeBufferPointer { cf in
                let pBase = pf.baseAddress!, cBase = cf.baseAddress!
                for dy in -maxShift...maxShift {
                    let lo = max(band.lowerBound, band.lowerBound - dy)
                    let hi = min(band.upperBound, band.upperBound - dy)
                    var sum = 0, rows = 0, detailed = 0
                    var y = lo
                    let budget = bestCost * Double((hi - lo) / rowStep + 1)
                    while y < hi {
                        let pa = cBase + y * bins, pb = pBase + (y + dy) * bins
                        for k in 0..<bins { sum += abs(Int(pa[k]) - Int(pb[k])) }
                        if !cur.flat[y] { detailed += 1 }
                        rows += 1
                        y += rowStep
                        if Double(sum) / Double(bins) > budget { break }
                    }
                    guard rows > 0, detailed >= 4, y >= hi else { continue }
                    let cost = Double(sum) / Double(rows * bins)
                    if cost < bestCost { bestCost = cost; bestDy = dy }
                }
            }
        }
        // Mean per-bin luminance difference must be small for a credible match.
        return bestCost <= 2.5 ? bestDy : nil
    }
}
