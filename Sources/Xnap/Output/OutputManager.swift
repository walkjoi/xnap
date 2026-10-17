import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Delivers finished images: to the pasteboard, or to disk in the chosen folder.
@MainActor
final class OutputManager {
    static let shared = OutputManager()
    private let prefs = Preferences.shared

    enum OutputError: LocalizedError {
        case encodingFailed
        case folderUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: "The image could not be encoded."
            case .folderUnavailable(let path): "The folder “\(path)” is not accessible. Choose another save location in Settings."
            }
        }
    }

    /// Copies or saves according to `destination`. Returns the file URL if one was written.
    ///
    /// Encoding happens off the main thread: PNG takes tens of milliseconds for an area
    /// capture, a few hundred for a full 5K screen and around a second for a tall scrolling
    /// capture, which is far too long to block the menu bar and the preview for.
    @discardableResult
    func deliver(_ image: CGImage, scale: CGFloat, to destination: CaptureDestination) async throws -> URL? {
        switch destination {
        case .clipboard:
            put(png: try await encoded(image, scale: scale, as: .png), pointSize: image.pointSize(scale: scale))
            return nil
        case .file:
            let format = prefs.imageFormat
            let data = try await encoded(image, scale: scale, as: format)
            let url = try writeToSaveFolder(data, format: format)
            if prefs.copyWhenSaving {
                // Reuse the bytes just written rather than encoding the image a second time.
                let png = format == .png ? data : try await encoded(image, scale: scale, as: .png)
                put(png: png, pointSize: image.pointSize(scale: scale))
            }
            return url
        }
    }

    // MARK: Pasteboard

    /// Keeps the pasteboard's TIFF promise fulfillable. Exactly one is alive at a time: each
    /// copy replaces the last, so nothing accumulates over a long-running session.
    private var tiffPromise: LazyTIFFProvider?

    func copy(_ image: CGImage, scale: CGFloat) async throws {
        put(png: try await encoded(image, scale: scale, as: .png), pointSize: image.pointSize(scale: scale))
    }

    private func put(png: Data, pointSize: CGSize) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // TIFF is large for tall captures, so only produce it if an app asks for it.
        let promise = LazyTIFFProvider(png: png, pointSize: pointSize)
        tiffPromise = promise
        item.setDataProvider(promise, forTypes: [.tiff])
        pasteboard.writeObjects([item])
    }

    func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Files

    func save(_ image: CGImage, scale: CGFloat) async throws -> URL {
        let format = prefs.imageFormat
        return try writeToSaveFolder(try await encoded(image, scale: scale, as: format), format: format)
    }

    func write(_ image: CGImage, scale: CGFloat, to url: URL) async throws {
        let type: Preferences.ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        try await encoded(image, scale: scale, as: type).write(to: url, options: .atomic)
    }

    private func writeToSaveFolder(_ data: Data, format: Preferences.ImageFormat) throws -> URL {
        try withSaveFolder { folder in
            let url = uniqueURL(in: folder, base: defaultBaseName(), ext: format.fileExtension)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    /// Encodes on a background thread. `CGImageDestination` is purely CPU-bound, and the cost
    /// scales with the pixel count, so a tall scrolling capture must not run on the main thread.
    func encoded(_ image: CGImage, scale: CGFloat, as format: Preferences.ImageFormat) async throws -> Data {
        let quality = prefs.jpegQuality
        let task = Task.detached(priority: .userInitiated) {
            Self.encode(image, scale: scale, as: format, jpegQuality: quality)
        }
        guard let data = await task.value else { throw OutputError.encodingFailed }
        return data
    }

    func encode(_ image: CGImage, scale: CGFloat, as format: Preferences.ImageFormat) -> Data? {
        Self.encode(image, scale: scale, as: format, jpegQuality: prefs.jpegQuality)
    }

    nonisolated static func encode(_ image: CGImage, scale: CGFloat, as format: Preferences.ImageFormat,
                                   jpegQuality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Building a `DateFormatter` is expensive and this runs for every save and every editor
    /// window title, so it is made once.
    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    func defaultBaseName(date: Date = Date()) -> String {
        "Xnap \(Self.fileNameFormatter.string(from: date))"
    }

    private func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    // MARK: Save folder

    /// `~/Pictures/Xnap` of the real home folder (not the sandbox container).
    var defaultFolder: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Pictures/Xnap", isDirectory: true)
    }

    /// Resolving a bookmark hits the filesystem, and `saveFolder` is read on every save and on
    /// every render of the Settings pane, so the result is kept until the bookmark changes.
    private var resolvedFolder: (bookmark: Data, url: URL, isStale: Bool)?

    /// The folder screenshots are saved to. Custom folders are remembered with a
    /// security-scoped bookmark so the sandboxed app can keep writing there.
    var saveFolder: URL { resolveSaveFolder()?.url ?? defaultFolder }

    private func resolveSaveFolder() -> (bookmark: Data, url: URL, isStale: Bool)? {
        guard let bookmark = prefs.saveFolderBookmark else { return nil }
        if let resolvedFolder, resolvedFolder.bookmark == bookmark { return resolvedFolder }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let entry = (bookmark: bookmark, url: url, isStale: stale)
        resolvedFolder = entry
        return entry
    }

    func setSaveFolder(_ url: URL?) {
        resolvedFolder = nil
        prefs.saveFolderBookmark = url.flatMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    func withSaveFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let entry = resolveSaveFolder()
        let folder = entry?.url ?? defaultFolder
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw OutputError.folderUnavailable(folder.path)
        }
        let result = try body(folder)
        // A stale bookmark still resolves but will eventually stop. Re-record it now that the
        // folder has proven writable, so a renamed or moved folder keeps working instead of
        // silently falling back to ~/Pictures/Xnap one day.
        if entry?.isStale == true { setSaveFolder(folder) }
        return result
    }

    func revealSaveFolder() {
        _ = try? withSaveFolder { NSWorkspace.shared.open($0) }
    }

    /// Writes a temporary PNG, used for dragging a capture into other apps.
    ///
    /// The previous drag file is deleted first, so these don't pile up unbounded in the
    /// container's temporary directory over a long-running session. Any earlier drag has
    /// already been dropped (or abandoned) by the time a new one starts.
    func temporaryFile(for image: CGImage, scale: CGFloat) -> URL? {
        guard let data = encode(image, scale: scale, as: .png) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Drag", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(defaultBaseName()).appendingPathExtension("png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}

/// Supplies TIFF data to the pasteboard only when requested.
///
/// It keeps the PNG bytes that are already on the pasteboard rather than the `CGImage`, and
/// decodes them if the promise is ever called in. Holding the image instead would keep a whole
/// uncompressed capture resident — and, before captures were detached from their snapshot, the
/// entire display's pixels with it — for as long as the clipboard held the item.
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data
    private let pointSize: CGSize

    init(png: Data, pointSize: CGSize) {
        self.png = png
        self.pointSize = pointSize
        super.init()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        if let data = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(data, forType: .tiff) }
    }
}

/// The capture "shutter" sound.
@MainActor
enum CaptureSound {
    private static let sound: NSSound? = {
        let base = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
        for name in ["Screen Capture.aif", "Grab.aif", "Shutter.aif"] {
            if let s = NSSound(contentsOfFile: base + name, byReference: true) { return s }
        }
        return NSSound(named: "Tink")
    }()

    static func play() {
        guard Preferences.shared.playSound, let sound else { return }
        sound.stop()
        sound.play()
    }
}
