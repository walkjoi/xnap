import CoreGraphics
import Vision

/// On-device text recognition (Vision). Nothing leaves the Mac.
enum TextRecognizer {
    static func recognize(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return format(request.results ?? [])
        }.value
    }

    /// Groups observations into lines (top to bottom), words left to right.
    private static func format(_ observations: [VNRecognizedTextObservation]) -> String {
        let items = observations.compactMap { obs -> (box: CGRect, text: String)? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, text)
        }.sorted { $0.box.midY > $1.box.midY }

        var lines: [[(box: CGRect, text: String)]] = []
        for item in items {
            if let last = lines.last?.first,
               abs(last.box.midY - item.box.midY) < min(last.box.height, item.box.height) * 0.5 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
