import AppKit
import Combine

/// Draws the screenshot with its annotations and turns mouse/keyboard input into edits.
///
/// The view is sized in points (image pixels ÷ scale) and flipped, so it lines up
/// with the image's top-left pixel coordinates. The enclosing scroll view zooms it.
final class CanvasView: NSView {
    let document: EditorDocument
    private var subscriptions = Set<AnyCancellable>()
    private var drag: DragState = .idle
    private var textEditor: InlineTextEditor?
    private var editingTextID: UUID?
    /// The last state painted, so a change can be narrowed to what actually moved.
    private var shown: EditorDocument.State

    private enum DragState {
        case idle
        case creating(Annotation, origin: CGPoint)
        case moving(id: UUID, last: CGPoint)
        case handle(id: UUID, index: Int)
        case newCrop(origin: CGPoint)
        case movingCrop(last: CGPoint)
        case cropHandle(index: Int)
    }

    init(document: EditorDocument) {
        self.document = document
        shown = document.state
        super.init(frame: CGRect(origin: .zero, size: document.image.pointSize(scale: document.scale)))
        document.$state
            .sink { [weak self] state in self?.stateChanged(to: state) }
            .store(in: &subscriptions)
        document.$selectedID
            .removeDuplicates()
            .sink { [weak self] id in self?.selectionChanged(to: id) }
            .store(in: &subscriptions)
        document.$cropRect
            .sink { [weak self] rect in self?.cropChanged(to: rect) }
            .store(in: &subscriptions)
        document.$tool
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.commitTextEditing()
                self.window?.invalidateCursorRects(for: self)
                self.needsDisplay = true
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// How many image pixels one screen point covers at the current zoom.
    private var pixelsPerScreenPoint: CGFloat { document.scale / magnification }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil) * document.scale
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), document.imageSize.width), y: min(max(0, p.y), document.imageSize.height))
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch document.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Invalidation

    /// `draw` repaints the base image inside the dirty rect, so invalidating the whole view on
    /// every drag step means resampling the entire visible capture — which for a tall scrolling
    /// capture is the difference between a smooth drag and a stuttering one. Narrow it to the
    /// annotations that changed, and fall back to a full repaint whenever that isn't clear-cut.
    private func stateChanged(to state: EditorDocument.State) {
        let previous = shown
        shown = state
        if previous.image !== state.image {
            setFrameSize(state.image.pointSize(scale: document.scale))
            needsDisplay = true
            return
        }
        guard previous.annotations.count == state.annotations.count else { needsDisplay = true; return }
        var changed: [Annotation] = []
        for (before, after) in zip(previous.annotations, state.annotations) where before != after {
            guard before.id == after.id else { needsDisplay = true; return } // reordered
            changed.append(before)
            changed.append(after)
        }
        invalidate(changed)
    }

    /// Published properties report the new value while the document still holds the old one.
    private func selectionChanged(to id: UUID?) {
        // Only the selection carries handles: repaint the one losing them and the one gaining them.
        let affected = [document.selectedID, id].compactMap { target in
            shown.annotations.first { $0.id == target }
        }
        invalidate(affected)
    }

    private func cropChanged(to rect: CGRect?) {
        // The crop tool dims everything outside its rect, so appearing or disappearing repaints
        // the image; moving or resizing it only repaints the area the two rects cover.
        guard let before = document.cropRect, let after = rect else { needsDisplay = true; return }
        let pad = 28 * pixelsPerScreenPoint
        invalidate(rect: before.union(after).insetBy(dx: -pad, dy: -pad))
    }

    private func invalidate(_ annotations: [Annotation]) {
        var region = CGRect.null
        for a in annotations {
            let pad = a.lineWidth * 2 + 14 * pixelsPerScreenPoint // shadow, handles, antialiasing
            region = region.union(a.bounds.insetBy(dx: -pad, dy: -pad))
        }
        invalidate(rect: region)
    }

    /// `rect` is in image pixels; the view is sized in points.
    private func invalidate(rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty, !rect.isInfinite else { return }
        let s = document.scale
        setNeedsDisplay(CGRect(x: rect.minX / s, y: rect.minY / s,
                               width: rect.width / s, height: rect.height / s).integral)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = document.scale
        ctx.saveGState()
        ctx.scaleBy(x: 1 / s, y: 1 / s)

        let devicePixelsPerImagePixel = magnification / s * (window?.backingScaleFactor ?? 2)
        ctx.interpolationQuality = devicePixelsPerImagePixel > 1.5 ? .none : .high
        AnnotationRenderer.drawImage(document.image, in: CGRect(origin: .zero, size: document.imageSize), ctx: ctx)
        ctx.interpolationQuality = .high

        let shadowScale = magnification / s
        for annotation in document.annotations where annotation.id != editingTextID {
            AnnotationRenderer.draw(annotation, in: ctx, pixelator: document.pixelator, shadowScale: shadowScale)
        }
        drawSelection(in: ctx)
        drawCrop(in: ctx)
        ctx.restoreGState()
    }

    private func drawSelection(in ctx: CGContext) {
        guard document.tool != .crop, let a = document.selected, a.id != editingTextID else { return }
        let px = pixelsPerScreenPoint
        let accent = NSColor.controlAccentColor.cgColor
        ctx.saveGState()
        if a.handles.isEmpty || a.shape.isPixelate {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.2 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.stroke(a.bounds.insetBy(dx: -4 * px, dy: -4 * px))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for handle in a.handles {
            let r = CGRect(x: handle.x - 5 * px, y: handle.y - 5 * px, width: 10 * px, height: 10 * px)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 * px)
            ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
    }

    private func drawCrop(in ctx: CGContext) {
        guard document.tool == .crop, let r = document.cropRect else { return }
        let px = pixelsPerScreenPoint
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: document.imageSize))
        path.addRect(r)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1 * px)
        for i in 1...2 {
            let f = CGFloat(i) / 3
            ctx.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 * px)
        ctx.stroke(r)
        for corner in cropCorners(r) {
            let h = CGRect(x: corner.x - 5 * px, y: corner.y - 5 * px, width: 10 * px, height: 10 * px)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(h)
        }

        let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * px, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: r.minX, y: max(0, r.minY - size.height - 10 * px),
                        width: size.width + 12 * px, height: size.height + 6 * px)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 4 * px, cornerHeight: 4 * px, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: bg.minX + 6 * px, y: bg.minY + 3 * px), withAttributes: attrs)
        ctx.restoreGState()
    }

    private func cropCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textEditor != nil {
            commitTextEditing()
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        let tolerance = 5 * pixelsPerScreenPoint
        let tool = document.tool

        if tool == .crop {
            beginCrop(at: p, clickCount: event.clickCount)
            return
        }

        if event.clickCount == 2, let hit = topmostAnnotation(at: p, tolerance: tolerance), hit.shape.isText {
            startTextEditor(for: hit, isNew: false)
            return
        }

        if let selected = document.selected, let index = handleIndex(of: selected, at: p) {
            document.beginInteraction()
            drag = .handle(id: selected.id, index: index)
            return
        }

        // Clicking an existing annotation selects and drags it (freehand tools always draw).
        if tool != .pen && tool != .highlighter, let hit = topmostAnnotation(at: p, tolerance: tolerance) {
            if tool == .text && hit.shape.isText {
                startTextEditor(for: hit, isNew: false)
                return
            }
            document.selectedID = hit.id
            document.beginInteraction()
            drag = .moving(id: hit.id, last: p)
            return
        }

        document.selectedID = nil
        let start = clamped(p)
        switch tool {
        case .select, .crop:
            break
        case .text:
            startTextEditor(for: document.newAnnotation(.text(start, "")), isNew: true)
        case .counter:
            document.add(document.newAnnotation(.counter(start, document.nextCounterNumber)))
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .pixelate:
            let shape: Annotation.Shape
            switch tool {
            case .arrow: shape = .arrow(start, start)
            case .line: shape = .line(start, start)
            case .rectangle: shape = .rectangle(CGRect(origin: start, size: .zero))
            case .ellipse: shape = .ellipse(CGRect(origin: start, size: .zero))
            case .pen: shape = .pen([start])
            case .highlighter: shape = .highlighter([start])
            default: shape = .pixelate(CGRect(origin: start, size: .zero))
            }
            document.beginInteraction()
            drag = .creating(document.newAnnotation(shape), origin: start)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(event)
        let p = clamped(raw)
        let constrain = event.modifierFlags.contains(.shift)

        switch drag {
        case .idle:
            break
        case .creating(var a, let origin):
            a.shape = reshape(a.shape, origin: origin, to: p, constrain: constrain)
            drag = .creating(a, origin: origin)
            document.updateDuringInteraction(a)
        case .moving(let id, let last):
            guard let a = document.annotations.first(where: { $0.id == id }) else { return }
            document.updateDuringInteraction(a.translated(by: raw - last))
            drag = .moving(id: id, last: raw)
        case .handle(let id, let index):
            guard let a = document.annotations.first(where: { $0.id == id }) else { return }
            var target = p
            if constrain {
                switch a.shape {
                case .arrow(let s, let e), .line(let s, let e): target = snapAngle(from: index == 0 ? e : s, to: p)
                default: break
                }
            }
            document.updateDuringInteraction(a.movingHandle(index, to: target))
        case .newCrop(let origin):
            document.cropRect = CGRect(from: origin, to: p)
        case .movingCrop(let last):
            guard var r = document.cropRect else { return }
            let size = document.imageSize
            r = r.offsetBy(dx: raw.x - last.x, dy: raw.y - last.y)
            r.origin.x = min(max(0, r.origin.x), size.width - r.width)
            r.origin.y = min(max(0, r.origin.y), size.height - r.height)
            document.cropRect = r
            drag = .movingCrop(last: raw)
        case .cropHandle(let index):
            guard let r = document.cropRect else { return }
            document.cropRect = Annotation.resize(r, corner: index, to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .idle }
        switch drag {
        case .creating(let a, _):
            if isMeaningful(a) {
                document.endInteraction("Add \(a.shape.name)")
                if case .pen = a.shape {} else if case .highlighter = a.shape {} else { document.selectedID = a.id }
            } else {
                document.cancelInteraction()
            }
        case .moving:
            document.endInteraction("Move")
        case .handle:
            document.endInteraction("Resize")
        case .newCrop:
            if let r = document.cropRect, r.width < 4 || r.height < 4 { document.cropRect = nil }
        default:
            break
        }
    }

    private func beginCrop(at p: CGPoint, clickCount: Int) {
        if let r = document.cropRect {
            if clickCount == 2 && r.contains(p) {
                document.applyCrop()
                return
            }
            let reach = 8 * pixelsPerScreenPoint
            if let index = cropCorners(r).firstIndex(where: { $0.distance(to: p) <= reach }) {
                drag = .cropHandle(index: index)
                return
            }
            if r.contains(p) {
                drag = .movingCrop(last: p)
                return
            }
        }
        drag = .newCrop(origin: clamped(p))
    }

    private func reshape(_ shape: Annotation.Shape, origin: CGPoint, to p: CGPoint, constrain: Bool) -> Annotation.Shape {
        switch shape {
        case .arrow: return .arrow(origin, constrain ? snapAngle(from: origin, to: p) : p)
        case .line: return .line(origin, constrain ? snapAngle(from: origin, to: p) : p)
        case .rectangle: return .rectangle(rect(from: origin, to: p, square: constrain))
        case .ellipse: return .ellipse(rect(from: origin, to: p, square: constrain))
        case .pixelate: return .pixelate(rect(from: origin, to: p, square: constrain))
        case .pen(var pts):
            if let last = pts.last, last.distance(to: p) >= pixelsPerScreenPoint { pts.append(p) }
            return .pen(pts)
        case .highlighter(var pts):
            if constrain { return .highlighter([origin, CGPoint(x: p.x, y: origin.y)]) }
            if let last = pts.last, last.distance(to: p) >= pixelsPerScreenPoint { pts.append(p) }
            return .highlighter(pts)
        default:
            return shape
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        guard square else { return CGRect(from: a, to: b) }
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGRect(x: b.x < a.x ? a.x - side : a.x, y: b.y < a.y ? a.y - side : a.y, width: side, height: side)
    }

    private func snapAngle(from o: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - o.x, dy = p.y - o.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: o.x + cos(angle) * length, y: o.y + sin(angle) * length)
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        let minimum = 3 * pixelsPerScreenPoint
        switch a.shape {
        case .arrow(let s, let e), .line(let s, let e): return s.distance(to: e) >= minimum
        case .rectangle(let r), .ellipse(let r), .pixelate(let r): return r.width >= minimum && r.height >= minimum
        case .pen(let pts), .highlighter(let pts): return !pts.isEmpty
        default: return true
        }
    }

    private func topmostAnnotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        document.annotations.last { $0.hitTest(p, tolerance: tolerance) }
    }

    private func handleIndex(of a: Annotation, at p: CGPoint) -> Int? {
        let reach = 7 * pixelsPerScreenPoint
        return a.handles.firstIndex { $0.distance(to: p) <= reach }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch Int(event.keyCode) {
        case 51, 117: // Delete, Forward Delete
            document.deleteSelection()
            return
        case 53: // Esc
            if document.tool == .crop, document.cropRect != nil { document.cropRect = nil }
            else if document.selectedID != nil { document.selectedID = nil }
            else { super.keyDown(with: event) }
            return
        case 36, 76: // Return / Enter
            if document.tool == .crop { document.applyCrop() }
            else if let a = document.selected, a.shape.isText { startTextEditor(for: a, isNew: false) }
            return
        case 123...126 where modifiers.isEmpty && document.selected != nil:
            nudgeSelection(keyCode: Int(event.keyCode), big: event.modifierFlags.contains(.shift))
            return
        default:
            break
        }
        if modifiers.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first {
            if let tool = Tool.allCases.first(where: { $0.key == ch }) {
                document.tool = tool
                return
            }
            if let digit = ch.wholeNumberValue, (1...RGBA.palette.count).contains(digit) {
                document.color = RGBA.palette[digit - 1]
                return
            }
        }
        super.keyDown(with: event)
    }

    private func nudgeSelection(keyCode: Int, big: Bool) {
        guard let a = document.selected else { return }
        let d = (big ? 10 : 1) * document.scale
        let offset: CGSize
        switch keyCode {
        case 123: offset = CGSize(width: -d, height: 0)
        case 124: offset = CGSize(width: d, height: 0)
        case 125: offset = CGSize(width: 0, height: d)
        default: offset = CGSize(width: 0, height: -d)
        }
        document.replace(a.translated(by: offset), actionName: "Move")
    }

    // MARK: Text editing

    private func startTextEditor(for annotation: Annotation, isNew: Bool) {
        commitTextEditing()
        guard case .text(let origin, let string) = annotation.shape else { return }
        let s = document.scale
        editingTextID = isNew ? nil : annotation.id
        document.selectedID = nil

        let font = NSFont.systemFont(ofSize: annotation.fontSize / s, weight: .semibold)
        let editor = InlineTextEditor(origin: CGPoint(x: origin.x / s, y: origin.y / s), font: font,
                                      color: annotation.color.nsColor)
        editor.string = string
        editor.onCommit = { [weak self] text in
            self?.finishTextEditing(original: annotation, text: text, isNew: isNew)
        }
        addSubview(editor)
        editor.fitToText()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        textEditor = editor
        needsDisplay = true
    }

    func commitTextEditing() {
        textEditor?.commit()
    }

    private func finishTextEditing(original: Annotation, text: String, isNew: Bool) {
        // This can run inside the editor's resignFirstResponder, so remove it on the next turn.
        let editor = textEditor
        textEditor = nil
        editingTextID = nil
        DispatchQueue.main.async { [weak self] in
            editor?.removeFromSuperview()
            if let self, let window = self.window, window.firstResponder === window { window.makeFirstResponder(self) }
        }
        guard case .text(let origin, _) = original.shape else { return }
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var edited = original
        edited.shape = .text(origin, text)
        if isNew {
            if !isEmpty { document.add(edited, select: false) }
        } else if isEmpty {
            document.remove(id: original.id)
        } else if edited != original {
            document.replace(edited, actionName: "Edit Text")
        }
        needsDisplay = true
    }
}

/// A borderless text view placed over the canvas while typing a text annotation.
/// Return (or Esc, or clicking elsewhere) commits; ⇧Return inserts a new line.
final class InlineTextEditor: NSTextView {
    var onCommit: ((String) -> Void)?
    private var committed = false

    init(origin: CGPoint, font: NSFont, color: NSColor) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: 100_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 24, height: font.pointSize * 1.3)),
                   textContainer: container)
        self.font = font
        textColor = color
        typingAttributes = [.font: font, .foregroundColor: color]
        insertionPointColor = color
        isRichText = false
        allowsUndo = false
        drawsBackground = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = .zero
        maxSize = CGSize(width: 100_000, height: 100_000)
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 1
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 || (isReturn && event.modifierFlags.isDisjoint(with: [.shift, .option])) {
            commit()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        fitToText()
    }

    func fitToText() {
        guard let layoutManager, let textContainer, let font else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        setFrameSize(CGSize(width: max(24, ceil(used.width) + font.pointSize * 0.5),
                            height: max(font.pointSize * 1.25, ceil(used.height))))
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { commit() }
        return resigned
    }

    func commit() {
        guard !committed else { return }
        committed = true
        onCommit?(string)
    }
}
