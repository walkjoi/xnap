import AppKit
import Combine

/// The editor's model: a base image plus editable annotations, with undo.
///
/// Every edit replaces `state` as a whole. Because `CGImage` is immutable and annotations
/// are values, snapshots are cheap and undo/redo is just swapping states.
@MainActor
final class EditorDocument: ObservableObject {
    struct State {
        var image: CGImage
        var annotations: [Annotation]
    }

    @Published private(set) var state: State {
        didSet {
            if state.image !== oldValue.image { pixelator = Pixelator(image: state.image, scale: scale) }
            isDirty = true
        }
    }
    @Published var tool: Tool = .arrow {
        didSet { if tool != .crop { cropRect = nil }; if tool != .select && tool != oldValue { selectedID = nil } }
    }
    @Published var color: RGBA = .red { didSet { applyToSelection { $0.color = color } } }
    @Published var strokeSize: StrokeSize = .medium { didSet { applyStrokeSizeToSelection() } }
    @Published var filled = false { didSet { applyToSelection { if $0.shape.isFillable { $0.filled = filled } } } }
    @Published var selectedID: UUID? { didSet { syncStyleFromSelection() } }
    @Published var cropRect: CGRect?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// True when there are edits that haven't been copied or saved.
    @Published var isDirty = false

    /// Image pixels per point (2 for Retina captures).
    let scale: CGFloat
    let undoManager = UndoManager()
    private(set) var pixelator: Pixelator
    private var interactionStart: State?
    private var syncingStyle = false
    private var observers: [NSObjectProtocol] = []

    var image: CGImage { state.image }
    var annotations: [Annotation] { state.annotations }
    var imageSize: CGSize { state.image.size }
    var selected: Annotation? { selectedID.flatMap { id in state.annotations.first { $0.id == id } } }

    init(image: CGImage, scale: CGFloat) {
        self.scale = max(1, scale)
        state = State(image: image, annotations: [])
        pixelator = Pixelator(image: image, scale: max(1, scale))
        isDirty = false
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refreshUndoState() }
            })
        }
    }

    deinit {
        // Block-based observations outlive the object they capture unless they are removed,
        // so every editor window would otherwise leave three of them registered for good.
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Style for new annotations

    var lineWidth: CGFloat { strokeSize.lineWidth * scale }
    var fontSize: CGFloat { strokeSize.fontSize * scale }
    var counterFontSize: CGFloat { strokeSize.counterSize * scale }
    var nextCounterNumber: Int {
        (state.annotations.compactMap { if case .counter(_, let n) = $0.shape { n } else { nil } }.max() ?? 0) + 1
    }

    func newAnnotation(_ shape: Annotation.Shape) -> Annotation {
        var a = Annotation(shape: shape, color: color, lineWidth: lineWidth, filled: filled && shape.isFillable)
        if case .counter = shape { a.fontSize = counterFontSize } else { a.fontSize = fontSize }
        return a
    }

    // MARK: Edits (undoable)

    func add(_ annotation: Annotation, select: Bool = true) {
        perform("Add \(annotation.shape.name)") { $0.annotations.append(annotation) }
        if select { selectedID = annotation.id }
    }

    func replace(_ annotation: Annotation, actionName: String = "Edit") {
        guard let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        perform(actionName) { $0.annotations[index] = annotation }
    }

    func remove(id: UUID) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        perform("Delete") { $0.annotations.remove(at: index) }
        if selectedID == id { selectedID = nil }
    }

    func deleteSelection() {
        if let id = selectedID { remove(id: id) }
    }

    func bringSelectionToFront() {
        guard let id = selectedID, let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        perform("Bring to Front") { $0.annotations.append($0.annotations.remove(at: index)) }
    }

    func applyCrop() {
        guard let rect = cropRect?.integral.intersection(CGRect(origin: .zero, size: imageSize)),
              rect.width >= 2, rect.height >= 2,
              // A shared crop would keep the uncropped pixels alive in every later undo state.
              let cropped = state.image.croppedCopy(to: rect) else { return }
        let offset = CGSize(width: -rect.minX, height: -rect.minY)
        perform("Crop") { state in
            state.image = cropped
            state.annotations = state.annotations.map { $0.translated(by: offset) }
        }
        cropRect = nil
        tool = .arrow
    }

    // MARK: Interactive edits (drags): one undo step per gesture

    func beginInteraction() { interactionStart = state }

    /// Updates without registering undo; call `endInteraction` when the gesture ends.
    func updateDuringInteraction(_ annotation: Annotation) {
        if let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) {
            state.annotations[index] = annotation
        } else {
            state.annotations.append(annotation)
        }
    }

    func endInteraction(_ name: String) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        let changed = start.annotations != state.annotations || start.image !== state.image
        if changed { registerUndo(restoring: start, name: name) }
    }

    func cancelInteraction() {
        if let start = interactionStart { state = start }
        interactionStart = nil
    }

    // MARK: Output

    func flattened() -> CGImage? {
        AnnotationRenderer.render(image: state.image, annotations: state.annotations, pixelator: pixelator)
    }

    // MARK: Undo plumbing

    private func perform(_ name: String, _ change: (inout State) -> Void) {
        let before = state
        var next = state
        change(&next)
        state = next
        registerUndo(restoring: before, name: name)
    }

    private func registerUndo(restoring previous: State, name: String) {
        undoManager.registerUndo(withTarget: self) { doc in
            let current = doc.state
            doc.state = previous
            if let id = doc.selectedID, !previous.annotations.contains(where: { $0.id == id }) { doc.selectedID = nil }
            doc.registerUndo(restoring: current, name: name)
        }
        undoManager.setActionName(name)
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    /// Selecting an annotation shows its color and size in the toolbar.
    private func syncStyleFromSelection() {
        guard let a = selected, !a.shape.isPixelate else { return }
        syncingStyle = true
        defer { syncingStyle = false }
        color = a.color
        if a.shape.isFillable { filled = a.filled }
        let size: StrokeSize?
        switch a.shape {
        case .text: size = StrokeSize.allCases.min { abs($0.fontSize * scale - a.fontSize) < abs($1.fontSize * scale - a.fontSize) }
        case .counter: size = StrokeSize.allCases.min { abs($0.counterSize * scale - a.fontSize) < abs($1.counterSize * scale - a.fontSize) }
        default: size = StrokeSize.allCases.min { abs($0.lineWidth * scale - a.lineWidth) < abs($1.lineWidth * scale - a.lineWidth) }
        }
        if let size { strokeSize = size }
    }

    private func applyToSelection(_ change: (inout Annotation) -> Void) {
        guard !syncingStyle, var a = selected, !a.shape.isPixelate else { return }
        let before = a
        change(&a)
        if a != before { replace(a, actionName: "Change Style") }
    }

    private func applyStrokeSizeToSelection() {
        applyToSelection { a in
            switch a.shape {
            case .text: a.fontSize = fontSize
            case .counter: a.fontSize = counterFontSize
            default: a.lineWidth = lineWidth
            }
        }
    }
}

extension Annotation.Shape {
    var isFillable: Bool {
        switch self { case .rectangle, .ellipse: true; default: false }
    }

    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Drawing"
        case .highlighter: "Highlight"
        case .text: "Text"
        case .counter: "Step"
        case .pixelate: "Pixelation"
        }
    }
}
