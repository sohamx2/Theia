import Foundation
import Vision

struct OCRService {
    func recognizeText(in frame: CapturedFrame) async throws -> OCRDocument {
        let cgImage = frame.cgImage

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<OCRDocument, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? [])
                        .compactMap { observation -> OCRTextLine? in
                            guard let candidate = observation.topCandidates(1).first else {
                                return nil
                            }

                            let box = observation.boundingBox
                            return OCRTextLine(
                                text: candidate.string,
                                confidence: Double(candidate.confidence),
                                boundingBox: NormalizedBoundingBox(
                                    x: box.origin.x,
                                    y: box.origin.y,
                                    width: box.width,
                                    height: box.height
                                )
                            )
                        }
                        .sorted { left, right in
                            let rowTolerance = max(left.boundingBox.height, right.boundingBox.height) * 0.5
                            if abs(left.boundingBox.centerY - right.boundingBox.centerY) > rowTolerance {
                                return left.boundingBox.centerY > right.boundingBox.centerY
                            }
                            return left.boundingBox.x < right.boundingBox.x
                        }

                    continuation.resume(returning: OCRDocument(lines: lines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ScreenVisualArtifactAssessment: Equatable {
    let shouldUseQwenVision: Bool
    let evidence: [String]
}

/// Uses Apple's on-device saliency model as a cheap router. It does not try to
/// understand a chart or image itself; it only decides when the screenshot has
/// a substantial visual region that OCR cannot represent and Qwen3-VL should
/// inspect the pixels.
struct ScreenVisualArtifactDetectionService {
    func assess(
        frame: CapturedFrame,
        report: ScreenContextReport
    ) async -> ScreenVisualArtifactAssessment {
        let salientRegions = (try? await detectSalientRegions(in: frame.cgImage)) ?? []
        return ScreenVisualArtifactRoutingPolicy.assess(
            report: report,
            salientRegions: salientRegions
        )
    }

    private func detectSalientRegions(
        in image: CGImage
    ) async throws -> [NormalizedBoundingBox] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[NormalizedBoundingBox], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNGenerateObjectnessBasedSaliencyImageRequest()
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                    let regions = (request.results ?? []).flatMap { observation in
                        observation.salientObjects ?? []
                    }.map { object in
                        let box = object.boundingBox
                        return NormalizedBoundingBox(
                            x: box.origin.x,
                            y: box.origin.y,
                            width: box.width,
                            height: box.height
                        )
                    }
                    continuation.resume(returning: regions)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ScreenVisualArtifactRoutingPolicy {
    private static let visualPhrases = [
        "diagram", "flowchart", "chart", "graph", "plot", "map", "figure",
        "schematic", "architecture", "infographic", "illustration", "image",
        "photo", "screenshot", "canvas", "contrast ratio", "color palette",
        "colour palette", "waveform", "timeline", "dashboard"
    ]

    static func assess(
        report: ScreenContextReport,
        salientRegions: [NormalizedBoundingBox]
    ) -> ScreenVisualArtifactAssessment {
        let contentText = (
            report.importantText
                .filter { $0.category != .action && $0.category != .brandOrSite }
                .map(\.text) + [report.sourceContext.windowTitle].compactMap { $0 }
        ).joined(separator: " ").lowercased()
        let cue = visualPhrases.first { phrase in
            contentText.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
                options: .regularExpression
            ) != nil
        }

        let isBrowser = [report.sourceContext.applicationName, report.sourceContext.bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .contains { identity in
                ["safari", "chrome", "firefox", "edge", "brave", "arc"]
                    .contains { identity.contains($0) }
            }
        let contentTop = isBrowser ? 0.90 : 0.97
        let candidates = salientRegions.filter { box in
            let area = box.width * box.height
            guard area >= 0.035,
                  box.centerY < contentTop,
                  box.centerY > 0.07,
                  box.centerX > 0.10,
                  box.centerX < 0.90
            else { return false }

            let textCoverage = report.importantText.reduce(0.0) { total, item in
                total + intersectionArea(box, item.boundingBox)
            } / max(area, 0.001)
            return textCoverage < 0.42
        }

        let largestArea = candidates.map { $0.width * $0.height }.max() ?? 0
        var evidence: [String] = []
        if let cue { evidence.append("visual cue: \(cue)") }
        if largestArea >= 0.07 {
            evidence.append("large salient non-text region")
        } else if candidates.count >= 2 {
            evidence.append("multiple salient non-text regions")
        }
        return ScreenVisualArtifactAssessment(
            shouldUseQwenVision: cue != nil || largestArea >= 0.07 || candidates.count >= 2,
            evidence: evidence
        )
    }

    private static func intersectionArea(
        _ lhs: NormalizedBoundingBox,
        _ rhs: NormalizedBoundingBox
    ) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        return width * height
    }
}
