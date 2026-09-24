import Testing
@testable import XnapCore

/// Deterministic RNG so test documents are reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A fake web page: bands of "text" rows separated by blank white gaps.
private func makeDocument(width: Int, height: Int, seed: UInt64 = 42) -> Bitmap {
    var rng = SplitMix64(state: seed)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        let inText = (y % 24) < 14
        for x in 0..<width {
            let i = (y * width + x) * 4
            if inText {
                let v = UInt8.random(in: 0...255, using: &rng)
                pixels[i] = v; pixels[i + 1] = v &+ 30; pixels[i + 2] = v &+ 60
            }
            pixels[i + 3] = 255
        }
    }
    return Bitmap(width: width, height: height, pixels: pixels)
}

private func solid(width: Int, height: Int, value: UInt8) -> Bitmap {
    var pixels = [UInt8](repeating: value, count: width * height * 4)
    for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
    // A little detail so the band isn't "flat".
    for y in 0..<height { let i = (y * width + (y * 7) % width) * 4; pixels[i] = 0 }
    return Bitmap(width: width, height: height, pixels: pixels)
}

/// What the screen shows at scroll offset `offset`, with optional sticky header/footer.
private func frame(_ doc: Bitmap, offset: Int, height: Int,
                   header: Bitmap? = nil, footer: Bitmap? = nil) -> Bitmap {
    let top = header?.height ?? 0, bottom = footer?.height ?? 0
    var parts: [Bitmap] = []
    if let header { parts.append(header) }
    parts.append(doc.rows((offset + top)..<(offset + height - bottom)))
    if let footer { parts.append(footer) }
    return Bitmap.stack(parts)!
}

private func addNoise(_ bitmap: Bitmap, amplitude: Int, seed: UInt64) -> Bitmap {
    var rng = SplitMix64(state: seed)
    var pixels = bitmap.pixels
    for i in pixels.indices where i % 4 != 3 {
        let n = Int.random(in: -amplitude...amplitude, using: &rng)
        pixels[i] = UInt8(clamping: Int(pixels[i]) + n)
    }
    return Bitmap(width: bitmap.width, height: bitmap.height, pixels: pixels)
}

private func meanAbsDifference(_ a: Bitmap, _ b: Bitmap) -> Double {
    precondition(a.pixels.count == b.pixels.count)
    var total = 0
    for i in a.pixels.indices { total += abs(Int(a.pixels[i]) - Int(b.pixels[i])) }
    return Double(total) / Double(a.pixels.count)
}

@Suite("ScrollStitcher")
struct ScrollStitcherTests {
    let width = 320
    let viewport = 500

    @Test func stitchesPlainDownwardScroll() {
        let doc = makeDocument(width: width, height: 4000)
        let stitcher = ScrollStitcher()
        let offsets = [0, 40, 95, 180, 300, 301, 450, 700, 1000, 1333, 1700, 2100, 2500, 2900, 3000]
        for (i, offset) in offsets.enumerated() {
            let outcome = stitcher.add(frame(doc, offset: offset, height: viewport))
            if i == 0 { #expect(outcome == .started) } else {
                if case .scrolled(let delta, _) = outcome {
                    #expect(delta == offset - offsets[i - 1])
                } else {
                    Issue.record("frame \(i) at offset \(offset): unexpected \(outcome)")
                }
            }
        }
        let result = stitcher.makeBitmap()!
        #expect(result == doc.rows(0..<3500))
        #expect(stitcher.outputHeight == 3500)
    }

    @Test func keepsStickyHeaderAndFooterOnce() {
        let doc = makeDocument(width: width, height: 3000, seed: 7)
        let header = solid(width: width, height: 50, value: 90)
        let footer = solid(width: width, height: 30, value: 200)
        let stitcher = ScrollStitcher()
        let offsets = [0, 60, 150, 330, 600, 900, 1200]
        for offset in offsets {
            stitcher.add(frame(doc, offset: offset, height: viewport, header: header, footer: footer))
        }
        #expect(stitcher.fixedTop == 50)
        #expect(stitcher.fixedBottom == 30)
        let expected = Bitmap.stack([header, doc.rows(50..<(1200 + viewport - 30)), footer])!
        #expect(stitcher.makeBitmap()! == expected)
    }

    @Test func identicalFramesAreUnchanged() {
        let doc = makeDocument(width: width, height: 1000)
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(frame(doc, offset: 0, height: viewport)) == .started)
        #expect(stitcher.add(frame(doc, offset: 0, height: viewport)) == .unchanged)
        #expect(stitcher.outputHeight == viewport)
    }

    @Test func localChangeInPlaceIsNotAScroll() {
        let doc = makeDocument(width: width, height: 1000)
        let stitcher = ScrollStitcher()
        let base = frame(doc, offset: 0, height: viewport)
        stitcher.add(base)
        var changed = base
        for i in (200 * width * 4)..<(215 * width * 4) where i % 4 != 3 { changed.pixels[i] = 17 }
        #expect(stitcher.add(changed) == .unchanged)
        #expect(stitcher.outputHeight == viewport)
    }

    @Test func handlesScrollingBackUp() {
        let doc = makeDocument(width: width, height: 2000, seed: 3)
        let stitcher = ScrollStitcher()
        for offset in [0, 120, 60, 200, 380, 250, 380] {
            stitcher.add(frame(doc, offset: offset, height: viewport))
        }
        #expect(stitcher.makeBitmap()! == doc.rows(0..<880))
    }

    @Test func recoversAfterLosingTrack() {
        let doc = makeDocument(width: width, height: 2000, seed: 11)
        let stitcher = ScrollStitcher()
        stitcher.add(frame(doc, offset: 0, height: viewport))
        stitcher.add(frame(doc, offset: 100, height: viewport))
        #expect(stitcher.add(frame(doc, offset: 700, height: viewport)) == .lostTrack)
        #expect(stitcher.add(frame(doc, offset: 300, height: viewport)) == .scrolled(delta: 200, appended: 200))
        #expect(stitcher.makeBitmap()! == doc.rows(0..<800))
    }

    @Test func toleratesRenderingNoise() {
        let doc = makeDocument(width: width, height: 2500, seed: 5)
        let stitcher = ScrollStitcher()
        let offsets = [0, 70, 180, 400, 650, 900, 1200, 1500]
        for (i, offset) in offsets.enumerated() {
            let f = addNoise(frame(doc, offset: offset, height: viewport), amplitude: 4, seed: UInt64(i + 1))
            let outcome = stitcher.add(f)
            if i > 0 { #expect(outcome == .scrolled(delta: offset - offsets[i - 1], appended: offset - offsets[i - 1])) }
        }
        let result = stitcher.makeBitmap()!
        #expect(result.height == 1500 + viewport)
        #expect(meanAbsDifference(result, doc.rows(0..<(1500 + viewport))) < 3)
    }

    @Test func noiseWithoutMovementIsUnchanged() {
        let doc = makeDocument(width: width, height: 1500, seed: 9)
        let stitcher = ScrollStitcher()
        stitcher.add(frame(doc, offset: 0, height: viewport))
        let noisy = addNoise(frame(doc, offset: 0, height: viewport), amplitude: 4, seed: 99)
        #expect(stitcher.add(noisy) == .unchanged)
        #expect(stitcher.add(frame(doc, offset: 120, height: viewport)) == .scrolled(delta: 120, appended: 120))
        #expect(stitcher.makeBitmap()!.height == viewport + 120)
    }

    @Test func stopsAtHeightLimit() {
        let doc = makeDocument(width: width, height: 4000)
        let stitcher = ScrollStitcher(configuration: .init(maxOutputHeight: 1200))
        var last: ScrollStitcher.Outcome = .started
        for offset in stride(from: 0, through: 2000, by: 200) {
            last = stitcher.add(frame(doc, offset: offset, height: viewport))
        }
        #expect(last == .limitReached)
        #expect(stitcher.makeBitmap()! == doc.rows(0..<1200))
    }

    @Test func ignoresFramesOfDifferentSize() {
        let doc = makeDocument(width: width, height: 1000)
        let stitcher = ScrollStitcher()
        stitcher.add(frame(doc, offset: 0, height: viewport))
        #expect(stitcher.add(frame(doc, offset: 0, height: viewport - 10)) == .sizeMismatch)
    }

    @Test func producesTailPreview() throws {
        let doc = makeDocument(width: width, height: 3000)
        let stitcher = ScrollStitcher()
        for offset in stride(from: 0, through: 1500, by: 150) {
            stitcher.add(frame(doc, offset: offset, height: viewport))
        }
        let preview = try #require(stitcher.makeTailPreview(width: 80, height: 120))
        #expect(preview.width == 80)
        #expect(preview.height == 120)
    }

    @Test func bitmapRoundTripsThroughCGImage() throws {
        let doc = makeDocument(width: 64, height: 48)
        let image = try #require(doc.makeCGImage())
        let back = try #require(Bitmap(cgImage: image))
        #expect(back == doc)
    }
}
