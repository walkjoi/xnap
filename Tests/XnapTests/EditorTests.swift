import AppKit
import ImageIO
import SwiftUI
import Testing
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

    @Test func encodesRetinaDPI() throws {
        let data = try #require(OutputManager.shared.encode(sampleImage(), scale: 2, as: .png))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? Double) == 144)
    }

    @Test func fileNamesAreReadableAndSortable() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23
        components.hour = 21; components.minute = 5; components.second = 9
        let date = Calendar.current.date(from: components)!
        #expect(OutputManager.shared.defaultBaseName(date: date) == "Xnap 2026-09-23 at 21.05.09")
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
