import CoreGraphics
import Foundation

/// A tightly packed 32-bit pixel buffer in sRGB.
///
/// Layout is BGRA in memory (premultiplied alpha, little-endian ARGB32), which is
/// what ScreenCaptureKit delivers for `kCVPixelFormatType_32BGRA`. Row 0 is the top row.
public struct Bitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public internal(set) var pixels: [UInt8]

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    public static let bitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height * 4,
                     "pixel buffer does not match \(width)x\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// Copies rows out of a strided buffer (e.g. a locked `CVPixelBuffer`).
    public init(width: Int, height: Int, bytesPerRow sourceStride: Int, base: UnsafeRawPointer) {
        let stride = width * 4
        var buffer = [UInt8](repeating: 0, count: stride * height)
        buffer.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            if sourceStride == stride {
                memcpy(dstBase, base, stride * height)
            } else {
                for y in 0..<height {
                    memcpy(dstBase + y * stride, base + y * sourceStride, stride)
                }
            }
        }
        self.init(width: width, height: height, pixels: buffer)
    }

    /// Renders any `CGImage` into sRGB BGRA.
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Bitmap.colorSpace, bitmapInfo: Bitmap.bitmapInfo) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: Bitmap.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// A copy of a horizontal band of rows.
    public func rows(_ range: Range<Int>) -> Bitmap {
        precondition(range.lowerBound >= 0 && range.upperBound <= height)
        let slice = pixels[(range.lowerBound * bytesPerRow)..<(range.upperBound * bytesPerRow)]
        return Bitmap(width: width, height: range.count, pixels: Array(slice))
    }

    /// Vertically concatenates bitmaps that share a width.
    public static func stack(_ parts: [Bitmap]) -> Bitmap? {
        guard let width = parts.first?.width, parts.allSatisfy({ $0.width == width }) else { return nil }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(parts.reduce(0) { $0 + $1.pixels.count })
        for part in parts { pixels.append(contentsOf: part.pixels) }
        return Bitmap(width: width, height: pixels.count / max(1, width * 4), pixels: pixels)
    }

    /// Vertically concatenates bitmaps straight into a `CGImage`, releasing each part as it
    /// is copied.
    ///
    /// Going through `stack` and then `makeCGImage` would hold three copies of the result at
    /// once — the parts, the concatenated bitmap and the `Data` the image is built from. A tall
    /// scrolling capture is hundreds of megabytes, so the image is assembled in a single buffer
    /// that the provider takes ownership of, and `parts` is emptied along the way.
    public static func stackedImage(consuming parts: inout [Bitmap]) -> CGImage? {
        guard let width = parts.first?.width, width > 0,
              parts.allSatisfy({ $0.width == width }) else { return nil }
        let height = parts.reduce(0) { $0 + $1.height }
        let bytesPerRow = width * 4
        let total = bytesPerRow * height
        guard height > 0, let buffer = malloc(total) else { return nil }

        var offset = 0
        for index in parts.indices {
            parts[index].pixels.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(buffer + offset, base, src.count) }
            }
            offset += parts[index].pixels.count
            parts[index] = Bitmap(width: 0, height: 0) // free this part now, not at the end
        }
        parts.removeAll()

        // The provider owns `buffer` from here on, including if the image fails to build.
        guard let provider = CGDataProvider(dataInfo: buffer, data: buffer, size: total,
                                            releaseData: { pointer, _, _ in free(pointer) }) else {
            free(buffer)
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: Bitmap.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
