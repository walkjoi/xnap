import AppKit
import XnapCore
import Testing

/// End-to-end stitching on real AppKit rendering: a text view in a scroll view with a
/// fixed toolbar above it is scrolled by uneven amounts, each visible state is rendered
/// like the screen would show it, and the stitched result is compared with a render of
/// the whole document.
@Suite("RealScrollStitching")
@MainActor
struct RealScrollStitchingTests {
    private let pageWidth: CGFloat = 520
    private let viewportHeight: CGFloat = 360
    private let toolbarHeight: CGFloat = 44

    private func makeText() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 14)
        let heading = NSFont.boldSystemFont(ofSize: 20)
        let text = NSMutableAttributedString()
        let words = ["screenshot", "scrolling", "privacy", "local", "annotate", "stitch", "capture", "pasteboard",
                     "window", "retina", "pixel", "sandbox", "arrow", "highlight", "crop", "pin"]
        for i in 0..<60 {
            if i % 8 == 0 {
                text.append(NSAttributedString(string: "Section \(i / 8 + 1)\n\n", attributes: [.font: heading]))
            }
            let sentence = (0..<(8 + i % 9)).map { words[($0 * 7 + i * 3) % words.count] }.joined(separator: " ")
            text.append(NSAttributedString(string: "\(i + 1). \(sentence.capitalized).\n", attributes: [
                .font: body, .foregroundColor: i % 5 == 0 ? NSColor.systemBlue : NSColor.textColor,
            ]))
            if i % 3 == 2 { text.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
        }
        return text
    }

    private func snapshot(_ view: NSView) -> CGImage {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage!
    }

    @Test func stitchesAScrolledTextViewUnderAFixedToolbar() throws {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: pageWidth, height: viewportHeight + toolbarHeight))
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = container
        window.appearance = NSAppearance(named: .aqua)

        let toolbar = NSTextField(labelWithString: "  Toolbar · Back · Forward · Share")
        toolbar.frame = CGRect(x: 0, y: viewportHeight, width: pageWidth, height: toolbarHeight)
        toolbar.drawsBackground = true
        toolbar.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        container.addSubview(toolbar)

        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: pageWidth, height: viewportHeight))
        scrollView.hasVerticalScroller = false
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: pageWidth, height: viewportHeight))
        textView.textStorage?.setAttributedString(makeText())
        textView.textContainerInset = CGSize(width: 16, height: 12)
        textView.backgroundColor = .white
        textView.isVerticallyResizable = true
        textView.sizeToFit()
        scrollView.documentView = textView
        container.addSubview(scrollView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let documentHeight = textView.frame.height
        #expect(documentHeight > viewportHeight * 4)

        let stitcher = ScrollStitcher()
        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        var step: CGFloat = 23
        while y + viewportHeight < documentHeight - 40 {
            offsets.append(y)
            y += step
            step = step >= 150 ? 31 : step + 29 // uneven, like a real trackpad
        }
        for offset in offsets {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let frame = try #require(Bitmap(cgImage: snapshot(container)))
            let outcome = stitcher.add(frame)
            if case .lostTrack = outcome { Issue.record("lost track at offset \(offset)") }
        }

        let result = try #require(stitcher.makeBitmap())
        let scale = CGFloat(result.width) / pageWidth
        let last = offsets.last!
        #expect(stitcher.fixedTop == Int(toolbarHeight * scale))
        #expect(result.height == Int((toolbarHeight + last + viewportHeight) * scale))

        // Expected: the toolbar once, then the document from the top down to the last viewport.
        scrollView.contentView.scroll(to: .zero)
        let toolbarImage = try #require(Bitmap(cgImage: snapshot(toolbar)))
        textView.frame.size.height = documentHeight
        let full = try #require(Bitmap(cgImage: snapshot(textView)))
        let docRows = Int((last + viewportHeight) * scale)
        let expected = try #require(Bitmap.stack([toolbarImage, full.rows(0..<min(full.height, docRows))]))
        #expect(expected.height == result.height)

        var diff = 0
        for i in expected.pixels.indices { diff += abs(Int(expected.pixels[i]) - Int(result.pixels[i])) }
        let mean = Double(diff) / Double(expected.pixels.count)
        #expect(mean < 0.5, "mean pixel difference \(mean)")

        if let dir = ProcessInfo.processInfo.environment["XNAP_SNAPSHOT_DIR"], let image = result.makeCGImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("stitched-textview.png"))
        }
    }
}
