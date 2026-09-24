import AppKit
import SwiftUI

struct EditorActions {
    let undo: () -> Void
    let redo: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    let recognizeText: () -> Void
}

/// Tool palette and style controls along the top of the editor.
struct EditorToolbar: View {
    @ObservedObject var document: EditorDocument
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, isSelected: document.tool == tool) { document.tool = tool }
                }
            }

            Divider().frame(height: 22)

            if document.tool == .crop {
                Text(document.cropRect == nil ? "Drag over the image to choose the crop area" : "Adjust the corners, then apply")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") { document.tool = .arrow }
                Button("Apply Crop") { document.applyCrop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(document.cropRect == nil)
                    .keyboardShortcut(.defaultAction)
            } else {
                colorRow
                Picker("Size", selection: $document.strokeSize) {
                    ForEach(StrokeSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 106)
                .help("Stroke and text size")

                if showsFill {
                    Toggle(isOn: $document.filled) {
                        Image(systemName: document.filled ? "square.fill" : "square")
                    }
                    .toggleStyle(.button)
                    .help("Fill shape")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: actions.undo)
                    .disabled(!document.canUndo)
                IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: actions.redo)
                    .disabled(!document.canRedo)
            }
            Divider().frame(height: 22)
            HStack(spacing: 2) {
                IconButton(symbol: "text.viewfinder", help: "Copy Text from Image (⇧⌘T)", action: actions.recognizeText)
                IconButton(symbol: "pin", help: "Pin to Screen (⌃⌘P)", action: actions.pin)
                IconButton(symbol: "square.and.arrow.down", help: "Save (⌘S)", action: actions.save)
            }
            Button(action: actions.copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Copy to Clipboard (⌘C)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var showsFill: Bool {
        document.tool.supportsFill || (document.tool == .select && document.selected?.shape.isFillable == true)
    }

    private func openColorPanel() {
        let doc = document
        ColorPanelBridge.shared.open(with: doc.color.nsColor) { [weak doc] in doc?.color = RGBA($0) }
    }

    private var colorRow: some View {
        HStack(spacing: 3) {
            ForEach(Array(RGBA.palette.enumerated()), id: \.offset) { index, color in
                Button { document.color = color } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(Circle().strokeBorder(document.color == color ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help("Color \(index + 1)")
            }
            Button(action: openColorPanel) {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .overlay(Circle().strokeBorder(RGBA.palette.contains(document.color) ? .clear : Color.accentColor,
                                                   lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Custom Color…")
        }
    }
}

/// Routes the shared color panel to whichever editor opened it last.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(with color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil
        panel.showsAlpha = false
        panel.color = color
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) { onChange?(sender.color) }
}

private struct ToolButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

@MainActor
final class ZoomModel: ObservableObject {
    @Published var percent = 100
}

struct EditorStatusBar: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var zoom: ZoomModel
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomToFit: () -> Void
    let actualSize: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(document.image.width) × \(document.image.height) px")
                .monospacedDigit()
            if document.scale > 1 {
                Text("@\(Int(document.scale))x").foregroundStyle(.tertiary)
            }
            if !document.annotations.isEmpty {
                Text("· \(document.annotations.count) annotation\(document.annotations.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out (⌘−)")
            Button(action: actualSize) { Text("\(zoom.percent)%").monospacedDigit().frame(minWidth: 40) }
                .help("Actual Size (⌘0)")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }.help("Zoom In (⌘+)")
            Button("Fit", action: zoomToFit).help("Zoom to Fit (⌘9)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}
