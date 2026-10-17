import AppKit
import ImageIO
import SwiftUI
import Testing
import XnapCore
@testable import Xnap

/// Set XNAP_SNAPSHOT_DIR to write rendered PNGs for visual inspection.
private func writeSnapshot(_ image: CGImage, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["XNAP_SNAPSHOT_DIR"] else { return }
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

private func snapshot(of view: NSView) -> CGImage? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
}

/// A fake "web page" screenshot at 2x.
private func sampleImage(width: Int = 1200, height: Int = 800) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height - 90, width: width, height: 90))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.darkGray]
    for i in 0..<9 {
        ("Line \(i + 1): The quick brown fox jumps over the lazy dog." as NSString)
            .draw(at: CGPoint(x: 60, y: CGFloat(height) - 170 - CGFloat(i) * 66), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func defaultShortcutsFollowTheClipboardFileScheme() {
        #expect(CaptureAction.area.defaultShortcut?.displayString == "⌃⇧1")
        #expect(CaptureAction.areaToFile.defaultShortcut?.displayString == "⌃⌥⇧1")
        #expect(CaptureAction.scrolling.defaultShortcut?.displayString == "⌃⇧2")
        #expect(CaptureAction.scrollingToFile.defaultShortcut?.displayString == "⌃⌥⇧2")
        #expect(CaptureAction.scrollingToFile.destination == .file)
        #expect(CaptureAction.scrolling.destination == .clipboard)
    }

    @Test func defaultShortcutsAreUniqueAndValid() {
        let shortcuts = CaptureAction.allCases.compactMap(\.defaultShortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        let allValid = shortcuts.allSatisfy { $0.isValidGlobalShortcut }
        #expect(allValid)
        #expect(Set(CaptureAction.allCases.map(\.hotKeyID)).count == CaptureAction.allCases.count)
    }

    @Test func shiftAloneIsNotAGlobalShortcut() {
        #expect(!Shortcut(keyCode: 0, modifiers: [.shift]).isValidGlobalShortcut)
        #expect(Shortcut(keyCode: 122, modifiers: []).isValidGlobalShortcut) // F1
    }
}

@Suite("Editor")
@MainActor
struct EditorTests {
    @Test func addUndoRedo() {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        doc.add(doc.newAnnotation(.arrow(CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 120))))
        #expect(doc.annotations.count == 1)
        #expect(doc.canUndo)
        doc.undoManager.undo()
        #expect(doc.annotations.isEmpty)
        doc.undoManager.redo()
        #expect(doc.annotations.count == 1)
    }

    @Test func dragIsOneUndoStep() {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        var a = doc.newAnnotation(.rectangle(CGRect(x: 0, y: 0, width: 1, height: 1)))
        doc.beginInteraction()
        for i in 1...10 {
            a.shape = .rectangle(CGRect(x: 0, y: 0, width: i * 10, height: i * 10))
            doc.updateDuringInteraction(a)
        }
        doc.endInteraction("Add Rectangle")
        #expect(doc.annotations.count == 1)
        doc.undoManager.undo()
        #expect(doc.annotations.isEmpty)
    }

    @Test func cropMovesAnnotationsWithTheImage() {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        doc.add(doc.newAnnotation(.counter(CGPoint(x: 500, y: 400), 1)))
        doc.tool = .crop
        doc.cropRect = CGRect(x: 100, y: 50, width: 600, height: 400)
        doc.applyCrop()
        #expect(doc.image.width == 600 && doc.image.height == 400)
        guard case .counter(let c, _) = doc.annotations[0].shape else { Issue.record("not a counter"); return }
        #expect(c == CGPoint(x: 400, y: 350))
        doc.undoManager.undo()
        #expect(doc.image.width == 1200)
    }

    @Test func countersNumberThemselves() {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        #expect(doc.nextCounterNumber == 1)
        doc.add(doc.newAnnotation(.counter(.zero, doc.nextCounterNumber)))
        doc.add(doc.newAnnotation(.counter(.zero, doc.nextCounterNumber)))
        #expect(doc.nextCounterNumber == 3)
    }

    @Test func selectingShowsItsStyleWithoutEditingIt() {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        doc.color = .blue
        let a = doc.newAnnotation(.line(.zero, CGPoint(x: 100, y: 100)))
        doc.add(a, select: false)
        doc.color = .red
        doc.selectedID = a.id
        #expect(doc.color == .blue)
        #expect(doc.annotations[0].color == .blue)
        doc.color = .green
        #expect(doc.annotations[0].color == .green)
    }

    @Test func pixelationDestroysDetail() throws {
        let image = sampleImage()
        let doc = EditorDocument(image: image, scale: 2)
        let region = CGRect(x: 40, y: 140, width: 800, height: 200)
        doc.add(doc.newAnnotation(.pixelate(region)))
        let flat = try #require(doc.flattened())
        #expect(flat.width == image.width && flat.height == image.height)
        // Inside the region, each block is a single flat color.
        let block = Int(doc.pixelator.blockSize)
        let bitmap = NSBitmapImageRep(cgImage: flat)
        let x0 = (Int(region.minX) / block + 1) * block, y0 = (Int(region.minY) / block + 1) * block
        let reference = bitmap.colorAt(x: x0, y: y0)
        for dx in 0..<block { for dy in 0..<block {
            #expect(bitmap.colorAt(x: x0 + dx, y: y0 + dy) == reference)
        } }
    }

    @Test func rendersEveryToolForVisualCheck() throws {
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        // New shapes are auto-selected and a color change recolors the selection,
        // so add these without selecting them.
        func add(_ a: Annotation) { doc.add(a, select: false) }
        doc.color = .red
        add(doc.newAnnotation(.arrow(CGPoint(x: 700, y: 620), CGPoint(x: 420, y: 330))))
        add(doc.newAnnotation(.rectangle(CGRect(x: 50, y: 120, width: 520, height: 80))))
        doc.color = .blue
        add(doc.newAnnotation(.ellipse(CGRect(x: 820, y: 400, width: 300, height: 160))))
        doc.color = .yellow
        add(doc.newAnnotation(.highlighter([CGPoint(x: 60, y: 300), CGPoint(x: 400, y: 302), CGPoint(x: 700, y: 300)])))
        doc.color = .green
        add(doc.newAnnotation(.pen([CGPoint(x: 900, y: 150), CGPoint(x: 950, y: 220), CGPoint(x: 1000, y: 160),
                                        CGPoint(x: 1060, y: 240), CGPoint(x: 1120, y: 170)])))
        doc.color = .purple
        add(doc.newAnnotation(.text(CGPoint(x: 740, y: 660), "Fully local ✓")))
        doc.color = .red
        add(doc.newAnnotation(.counter(CGPoint(x: 1100, y: 330), 1)))
        add(doc.newAnnotation(.counter(CGPoint(x: 1100, y: 440), 2)))
        add(doc.newAnnotation(.pixelate(CGRect(x: 60, y: 480, width: 520, height: 120))))
        add(doc.newAnnotation(.line(CGPoint(x: 60, y: 760), CGPoint(x: 600, y: 760))))
        let flat = try #require(doc.flattened())
        writeSnapshot(flat, "editor-render.png")

        // The live canvas draws the same thing, plus selection handles.
        doc.tool = .select
        doc.selectedID = doc.annotations[1].id
        let canvas = CanvasView(document: doc)
        let shot = try #require(snapshot(of: canvas))
        writeSnapshot(shot, "editor-canvas.png")
        #expect(shot.width > 0)
    }

    /// The canvas repaints only the region that changed instead of the whole view, so the risk
    /// is an edit that stops invalidating anything at all and leaves stale pixels on screen.
    @Test func everyKindOfEditInvalidatesTheCanvas() {
        _ = NSApplication.shared
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        let canvas = CanvasView(document: doc)
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = canvas

        func invalidates(_ what: String, _ change: () -> Void) {
            canvas.displayIfNeeded()
            #expect(!canvas.needsDisplay, "\(what): the canvas was still dirty to begin with")
            change()
            #expect(canvas.needsDisplay, "\(what) left the canvas stale")
        }

        // Two annotations, so that reordering is a visible change rather than a no-op.
        let first = doc.newAnnotation(.rectangle(CGRect(x: 40, y: 40, width: 120, height: 80)))
        let second = doc.newAnnotation(.ellipse(CGRect(x: 300, y: 200, width: 160, height: 100)))
        invalidates("adding an annotation") { doc.add(first) }
        invalidates("adding a second annotation") { doc.add(second) }
        invalidates("moving an annotation") {
            doc.replace(doc.annotations[0].translated(by: CGSize(width: 30, height: 20)))
        }
        invalidates("restyling the selection") { doc.color = .green }
        invalidates("deselecting") { doc.selectedID = nil }
        invalidates("selecting") { doc.selectedID = first.id }
        invalidates("reordering") { doc.bringSelectionToFront() }
        invalidates("deleting") { doc.deleteSelection() }
        invalidates("switching tool") { doc.tool = .crop }
        invalidates("starting a crop") { doc.cropRect = CGRect(x: 10, y: 10, width: 200, height: 150) }
        invalidates("resizing a crop") { doc.cropRect = CGRect(x: 10, y: 10, width: 260, height: 150) }
        invalidates("applying a crop") { doc.applyCrop() }
        // Undo restores the image, whichever group the manager has coalesced.
        invalidates("undo") { doc.undoManager.undo() }
    }

    @Test func encodesRetinaDPI() throws {
        let data = try #require(OutputManager.shared.encode(sampleImage(), scale: 2, as: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? Double) == 144)
    }

    /// Encoding is the slow part of a capture, so it runs off the main thread. The background
    /// path has to produce exactly what the synchronous one does.
    @Test func backgroundEncodingMatchesTheSynchronousPath() async throws {
        let image = sampleImage(width: 240, height: 160)
        for format in Preferences.ImageFormat.allCases {
            let expected = try #require(OutputManager.shared.encode(image, scale: 2, as: format))
            let actual = try await OutputManager.shared.encoded(image, scale: 2, as: format)
            #expect(actual == expected)
        }
    }

    @Test func fileNamesAreReadableAndSortable() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23
        components.hour = 21; components.minute = 5; components.second = 9
        let date = Calendar.current.date(from: components)!
        #expect(OutputManager.shared.defaultBaseName(date: date) == "Xnap 2026-09-23 at 21.05.09")
    }
}

/// A capture lives a long time — on the clipboard, in undo states, in a pinned window — and
/// the app runs for weeks, so a capture must never keep the display snapshot it came from.
@Suite("CaptureMemory")
@MainActor
struct CaptureMemoryTests {
    /// Every pixel encodes its own coordinates, so a mis-oriented crop can't go unnoticed.
    private func coded(width: Int, height: Int) -> Bitmap {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x & 0xFF)             // B
                pixels[i + 1] = UInt8(y & 0xFF)         // G
                pixels[i + 2] = UInt8((x ^ y) & 0xFF)   // R
                pixels[i + 3] = 255
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    @Test func croppedCopyDetachesFromTheParentImage() throws {
        let parent = try #require(coded(width: 256, height: 128).makeCGImage())
        let rect = CGRect(x: 32, y: 16, width: 64, height: 48)

        // cropping(to:) inherits the parent's row stride because it is only a window onto
        // the parent's pixels — which is exactly why it keeps them all alive.
        let shared = try #require(parent.cropping(to: rect))
        #expect(shared.bytesPerRow == parent.bytesPerRow)

        let detached = try #require(parent.croppedCopy(to: rect))
        #expect(detached.width == 64 && detached.height == 48)
        #expect(detached.bytesPerRow < parent.bytesPerRow)
    }

    @Test func croppedCopyMatchesCroppingPixelForPixel() throws {
        let source = coded(width: 256, height: 128)
        let parent = try #require(source.makeCGImage())
        let rect = CGRect(x: 32, y: 16, width: 64, height: 48)
        let detachedImage = try #require(parent.croppedCopy(to: rect))
        let detached = try #require(Bitmap(cgImage: detachedImage))
        let sharedImage = try #require(parent.cropping(to: rect))
        let shared = try #require(Bitmap(cgImage: sharedImage))
        #expect(detached == shared)
        // Top-left origin, like cropping(to:): the first pixel is the source pixel at (32, 16).
        let i = (16 * source.width + 32) * 4
        #expect(Array(detached.pixels[0..<3]) == Array(source.pixels[i..<(i + 3)]))
    }

    @Test func croppedCopyClampsToTheImage() throws {
        let parent = try #require(coded(width: 64, height: 64).makeCGImage())
        let edge = try #require(parent.croppedCopy(to: CGRect(x: 48, y: 48, width: 64, height: 64)))
        #expect(edge.width == 16 && edge.height == 16)
        #expect(parent.croppedCopy(to: CGRect(x: 100, y: 100, width: 10, height: 10)) == nil)
    }

    @Test func croppingInTheEditorDropsTheUncroppedPixels() throws {
        let image = try #require(coded(width: 256, height: 128).makeCGImage())
        let doc = EditorDocument(image: image, scale: 2)
        let strideBefore = doc.image.bytesPerRow
        doc.tool = .crop
        doc.cropRect = CGRect(x: 16, y: 16, width: 64, height: 48)
        doc.applyCrop()
        #expect(doc.image.width == 64 && doc.image.height == 48)
        #expect(doc.image.bytesPerRow < strideBefore)
    }

    /// Guards against the document outliving its window: it owns three block-based
    /// notification observations, which stay registered unless `deinit` removes them.
    @Test func editorDocumentDeallocatesWithItsObservers() throws {
        let image = try #require(coded(width: 64, height: 48).makeCGImage())
        weak var released: EditorDocument?
        do {
            let doc = EditorDocument(image: image, scale: 2)
            doc.add(doc.newAnnotation(.counter(.zero, 1)))
            #expect(doc.canUndo)
            released = doc
        }
        #expect(released == nil)
        // The notifications it listened for must not reach anything now.
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    /// The pasteboard's TIFF promise must not pin a whole capture: it keeps the PNG bytes
    /// that are already on the clipboard, and only one promise is alive at a time.
    @Test func clipboardTIFFPromiseIsFulfilledFromThePNG() async throws {
        let image = try #require(coded(width: 64, height: 48).makeCGImage())
        try await OutputManager.shared.copy(image, scale: 2)
        let board = NSPasteboard.general
        #expect(board.data(forType: .png) != nil)
        let tiff = try #require(board.data(forType: .tiff))
        let rep = try #require(NSBitmapImageRep(data: tiff))
        #expect(rep.pixelsWide == 64 && rep.pixelsHigh == 48)
        #expect(rep.size == CGSize(width: 32, height: 24)) // 48 x 64 px at 2x
    }
}

@Suite("Loupe")
struct LoupeTests {
    private let span = 15

    @Test func centresTheWindowAwayFromTheEdges() {
        let w = Loupe.window(x: 100, y: 80, width: 400, height: 300, span: span)
        #expect(w == Loupe.Window(originX: 93, originY: 73, offsetX: 7, offsetY: 7))
    }

    /// Near an edge the window is pushed back inside rather than clipped, so the magnifier
    /// keeps its scale and the marker follows the pointer off-centre.
    @Test func shiftsTheWindowInsideAtTheEdges() {
        let topLeft = Loupe.window(x: 2, y: 1, width: 400, height: 300, span: span)
        #expect(topLeft == Loupe.Window(originX: 0, originY: 0, offsetX: 2, offsetY: 1))

        let bottomRight = Loupe.window(x: 399, y: 299, width: 400, height: 300, span: span)
        #expect(bottomRight == Loupe.Window(originX: 385, originY: 285, offsetX: 14, offsetY: 14))
    }

    @Test func alwaysProducesAWindowInsideTheImage() {
        for x in [0, 1, 7, 8, 199, 200, 399] {
            for y in [0, 1, 7, 8, 299] {
                let w = Loupe.window(x: x, y: y, width: 400, height: 300, span: span)
                #expect(w.originX >= 0 && w.originX + span <= 400)
                #expect(w.originY >= 0 && w.originY + span <= 300)
                // The marker always lands on the pixel that was asked for.
                #expect(w.originX + w.offsetX == x)
                #expect(w.originY + w.offsetY == y)
                #expect((0..<span).contains(w.offsetX) && (0..<span).contains(w.offsetY))
            }
        }
    }

    /// An image smaller than the loupe can't be shifted anywhere; it must not go negative.
    @Test func handlesAnImageSmallerThanTheWindow() {
        let w = Loupe.window(x: 3, y: 2, width: 8, height: 5, span: span)
        #expect(w == Loupe.Window(originX: 0, originY: 0, offsetX: 3, offsetY: 2))
    }
}

@Suite("Chrome")
@MainActor
struct ChromeSnapshotTests {
    @Test func scrollHUD() throws {
        _ = NSApplication.shared
        let model = ScrollHUDModel(savesToFile: false)
        model.heightPixels = 12_480
        model.say("Scrolled too far at once — scroll back up a little.", .warning)
        let panel = ScrollHUDPanel(model: model)
        let view = try #require(panel.contentView)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let shot = try #require(snapshot(of: view))
        writeSnapshot(shot, "scroll-hud.png")
        #expect(view.fittingSize.width > 400)
    }

    @Test func editorToolbar() throws {
        _ = NSApplication.shared
        let doc = EditorDocument(image: sampleImage(), scale: 2)
        let actions = EditorActions(undo: {}, redo: {}, copy: {}, save: {}, pin: {}, recognizeText: {})
        let host = NSHostingView(rootView: EditorToolbar(document: doc, actions: actions))
        host.frame = CGRect(x: 0, y: 0, width: 980, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        let shot = try #require(snapshot(of: host))
        writeSnapshot(shot, "editor-toolbar.png")
        let needed = host.fittingSize.width
        #expect(needed <= 980, "toolbar needs \(needed) pt") // the editor window's minimum width
    }
}
