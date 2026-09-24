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
    @discardableResult
    func deliver(_ image: CGImage, scale: CGFloat, to destination: CaptureDestination) throws -> URL? {
        switch destination {
        case .clipboard:
            copy(image, scale: scale)
            return nil
        case .file:
            let url = try save(image, scale: scale)
            if prefs.copyWhenSaving { copy(image, scale: scale) }
            return url
        }
    }

    // MARK: Pasteboard

    func copy(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let png = encode(image, scale: scale, as: .png) { item.setData(png, forType: .png) }
        // TIFF is large for tall captures, so only produce it if an app asks for it.
        let provider = LazyTIFFProvider(image: image, scale: scale)
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.writeObjects([item])
    }

    func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Files

    func save(_ image: CGImage, scale: CGFloat) throws -> URL {
        let format = prefs.imageFormat
        guard let data = encode(image, scale: scale, as: format) else { throw OutputError.encodingFailed }
        return try withSaveFolder { folder in
            let url = uniqueURL(in: folder, base: defaultBaseName(), ext: format.fileExtension)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    func write(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        let type: Preferences.ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
        guard let data = encode(image, scale: scale, as: type) else { throw OutputError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    func encode(_ image: CGImage, scale: CGFloat, as format: Preferences.ImageFormat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = prefs.jpegQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    func defaultBaseName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Xnap \(f.string(from: date))"
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

    /// The folder screenshots are saved to. Custom folders are remembered with a
    /// security-scoped bookmark so the sandboxed app can keep writing there.
    var saveFolder: URL {
        guard let bookmark = prefs.saveFolderBookmark else { return defaultFolder }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? defaultFolder
    }

    func setSaveFolder(_ url: URL?) {
        prefs.saveFolderBookmark = url.flatMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    func withSaveFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = saveFolder
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw OutputError.folderUnavailable(folder.path)
        }
        return try body(folder)
    }

    func revealSaveFolder() {
        _ = try? withSaveFolder { NSWorkspace.shared.open($0) }
    }

    /// Writes a temporary PNG, used for dragging a capture into other apps.
    func temporaryFile(for image: CGImage, scale: CGFloat) -> URL? {
        guard let data = encode(image, scale: scale, as: .png) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(defaultBaseName()).appendingPathExtension("png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}

/// Supplies TIFF data to the pasteboard only when requested.
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private var image: CGImage?
    private let scale: CGFloat
    private static var live: Set<LazyTIFFProvider> = []

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init()
        LazyTIFFProvider.live.insert(self)
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let image, type == .tiff else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = image.pointSize(scale: scale)
        if let data = rep.tiffRepresentation(using: .lzw, factor: 0) { item.setData(data, forType: .tiff) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        image = nil
        LazyTIFFProvider.live.remove(self)
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
