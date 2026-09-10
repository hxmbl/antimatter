import AppKit
import Vision

/// Screenshot → text: on-device Vision OCR, never uploaded.
nonisolated enum ImageText {
    static func recognize(_ image: NSImage) async throws -> String? {
        guard let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}