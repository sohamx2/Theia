import AppKit
import Foundation
import ImageIO

private struct BenchmarkPrompt: Codable {
    let action: String
    let question: String
    let choices: [SuggestedSearchOption]
}

private struct BenchmarkPipelineResult: Codable {
    let rank: Int
    let name: String
    let model: String
    let subject: String
    let category: String
    let subcategory: String?
    let summary: String
    let prompts: [BenchmarkPrompt]
    let validStructuredPrompts: Bool
    let groundingScore: Double
    let contractScore: Double
    let focusScore: Double
    let qualityScore: Double
    let latencyScore: Double
    let overallScore: Double
    let totalMilliseconds: Int
    let stageMilliseconds: [String: Int]
    let warnings: [String]
}

private struct CurrentScreenBenchmarkReport: Codable {
    let schemaVersion: String
    let generatedAt: Date
    let screenshotPath: String
    let qualityWeight: Double
    let latencyWeight: Double
    let pipelines: [BenchmarkPipelineResult]
    let limitations: [String]
}

private struct RawPipelineResult {
    let name: String
    let model: String
    let subject: String
    let category: IntentCategory
    let subcategory: IntentSubcategory?
    let summary: String
    let prompts: [IntentPromptSuggestion]
    let validStructuredPrompts: Bool
    let totalMilliseconds: Int
    let stageMilliseconds: [String: Int]
    let warnings: [String]
}

private struct QualityScores {
    let grounding: Double
    let contract: Double
    let focus: Double
    var total: Double { grounding + contract + focus }
}

@main
struct CurrentScreenVisionBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard let screenshotPath = value(for: "--screenshot", in: arguments) else {
            throw BenchmarkFailure("Pass --screenshot with a PNG or JPEG path.")
        }
        let outputPath = value(for: "--output", in: arguments)
            ?? "BenchmarkResults/current-screen-qwen3-vl-comparison.json"
        let baselineModel = value(for: "--baseline-model", in: arguments) ?? "qwen3:4b"
        let visionModel = value(for: "--vision-model", in: arguments)
            ?? "qwen3-vl:4b-instruct"
        let expectedTerms = values(for: "--expected-term", in: arguments)
        let distractorTerms = values(for: "--distractor-term", in: arguments)
        let baseURL = URL(string: value(for: "--base-url", in: arguments)
            ?? "http://127.0.0.1:11434")!
        let sourceContext = ScreenSourceContext(
            applicationName: value(for: "--application", in: arguments) ?? "Safari",
            bundleIdentifier: value(for: "--bundle-id", in: arguments) ?? "com.apple.Safari",
            windowTitle: value(for: "--window-title", in: arguments),
            websites: values(for: "--website", in: arguments)
        )

        let screenshotURL = URL(fileURLWithPath: screenshotPath)
        let imageData = try Data(contentsOf: screenshotURL)
        guard let source = CGImageSourceCreateWithURL(screenshotURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BenchmarkFailure("Could not decode screenshot: \(screenshotPath)")
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        let frame = CapturedFrame(cgImage: cgImage, image: image)
        let runtime = OllamaRuntimeManager(baseURL: baseURL)
        defer { runtime.shutdown() }

        let visionOnly = arguments.contains("--vision-only")
        let visionPromptMode: QwenVisionPromptMode
        if arguments.contains("--other-fallback") {
            visionPromptMode = .otherFallback
        } else if arguments.contains("--activity-next-steps") {
            visionPromptMode = .activityNextSteps
        } else {
            visionPromptMode = .contractValidated
        }
        var rawResults: [RawPipelineResult] = []
        if !visionOnly {
            print("Running current Theia OCR pipeline with \(baselineModel)...")
            let baseline = await runBaseline(
                frame: frame,
                sourceContext: sourceContext,
                model: baselineModel,
                baseURL: baseURL,
                runtime: runtime
            )
            rawResults.append(baseline)
            await runtime.unload(model: baselineModel)
        }
        print("Running direct vision pipeline with \(visionModel)...")
        let visionStartedAt = Date()
        let vision: RawPipelineResult
        do {
            vision = try await runVision(
                imageData: imageData,
                sourceContext: sourceContext,
                model: visionModel,
                baseURL: baseURL,
                runtime: runtime,
                promptMode: visionPromptMode
            )
        } catch {
            vision = RawPipelineResult(
                name: "Qwen3-VL direct vision",
                model: visionModel,
                subject: "Unknown",
                category: .other,
                subcategory: nil,
                summary: "",
                prompts: [],
                validStructuredPrompts: false,
                totalMilliseconds: elapsed(visionStartedAt),
                stageMilliseconds: [:],
                warnings: [error.localizedDescription]
            )
        }
        rawResults.append(vision)
        let fastest = max(1, rawResults.map(\.totalMilliseconds).min() ?? 1)
        let scored = rawResults.map { raw -> (RawPipelineResult, QualityScores, Double, Double) in
            let quality = qualityScores(
                raw,
                expectedTerms: expectedTerms,
                distractorTerms: distractorTerms
            )
            let latency = 20 * Double(fastest) / Double(max(1, raw.totalMilliseconds))
            let overall = quality.total * 0.8 + latency
            return (raw, quality, latency, overall)
        }
        let ordered = scored.sorted {
            if $0.3 == $1.3 { return $0.0.totalMilliseconds < $1.0.totalMilliseconds }
            return $0.3 > $1.3
        }
        let pipelines = ordered.enumerated().map { index, item in
            let raw = item.0
            let quality = item.1
            return BenchmarkPipelineResult(
                rank: index + 1,
                name: raw.name,
                model: raw.model,
                subject: raw.subject,
                category: raw.category.rawValue,
                subcategory: raw.subcategory?.rawValue,
                summary: raw.summary,
                prompts: raw.prompts.map {
                    BenchmarkPrompt(
                        action: $0.action.rawValue,
                        question: $0.text,
                        choices: $0.searchOptions
                    )
                },
                validStructuredPrompts: raw.validStructuredPrompts,
                groundingScore: rounded(quality.grounding),
                contractScore: rounded(quality.contract),
                focusScore: rounded(quality.focus),
                qualityScore: rounded(quality.total),
                latencyScore: rounded(item.2),
                overallScore: rounded(item.3),
                totalMilliseconds: raw.totalMilliseconds,
                stageMilliseconds: raw.stageMilliseconds,
                warnings: raw.warnings
            )
        }
        let report = CurrentScreenBenchmarkReport(
            schemaVersion: "1.0",
            generatedAt: Date(),
            screenshotPath: screenshotPath,
            qualityWeight: 0.8,
            latencyWeight: 0.2,
            pipelines: pipelines,
            limitations: [
                "This is one exploratory screen, not a replacement-eligibility corpus.",
                "Quality uses explicit grounding, output-contract, and distractor-focus checks supplied on the command line.",
                "Latency is one cold end-to-end run per pipeline and includes model switching."
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let reportData = try encoder.encode(report)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try reportData.write(to: outputURL, options: .atomic)

        for pipeline in pipelines {
            print(
                "#\(pipeline.rank) \(pipeline.name): overall \(pipeline.overallScore), " +
                "quality \(pipeline.qualityScore), \(pipeline.totalMilliseconds) ms"
            )
            print("  \(pipeline.category) | \(pipeline.subject)")
            for prompt in pipeline.prompts {
                print("  - [\(prompt.action)] \(prompt.question)")
            }
            for warning in pipeline.warnings {
                print("  warning: \(warning)")
            }
        }
        print("Wrote \(outputPath)")
    }

    private static func runBaseline(
        frame: CapturedFrame,
        sourceContext: ScreenSourceContext,
        model: String,
        baseURL: URL,
        runtime: OllamaRuntimeManager
    ) async -> RawPipelineResult {
        let totalStartedAt = Date()
        let ocrStartedAt = Date()
        let document: OCRDocument
        do {
            document = try await OCRService().recognizeText(in: frame)
        } catch {
            return RawPipelineResult(
                name: "Current Theia (OCR cascade)",
                model: model,
                subject: "Unknown",
                category: .other,
                subcategory: nil,
                summary: "",
                prompts: [],
                validStructuredPrompts: false,
                totalMilliseconds: elapsed(totalStartedAt),
                stageMilliseconds: ["ocr": elapsed(ocrStartedAt)],
                warnings: [error.localizedDescription]
            )
        }
        let ocrMilliseconds = elapsed(ocrStartedAt)
        let configuration = LocalModelConfiguration(
            baseURL: baseURL,
            bertModel: "all-minilm",
            qwenModel: model,
            ruleAcceptanceThreshold: 0.90,
            bertAcceptanceThreshold: 0.90,
            memoryLearningThreshold: 0.90
        )
        let models = OllamaLocalModelClient(baseURL: baseURL, runtimeManager: runtime)
        let classifier = IntentClassificationService(
            configuration: configuration,
            localModels: models,
            memoryStore: nil,
            mode: .cascade
        )
        let analysisStartedAt = Date()
        let report = await ContextAnalysisService().analyze(
            document,
            sourceContext: sourceContext,
            intentClassifier: classifier
        )
        let analysisMilliseconds = elapsed(analysisStartedAt)
        let promptStartedAt = Date()
        let generation: IntentPromptGeneration
        do {
            generation = try await IntentPromptSuggestionService(
                modelName: model,
                localModels: models,
                webSearch: nil
            ).generate(for: report)
        } catch {
            return RawPipelineResult(
                name: "Current Theia (OCR cascade)",
                model: model,
                subject: report.intent.identifiedSubject ?? "Unknown",
                category: report.intent.category,
                subcategory: report.intent.subcategory,
                summary: report.importantText.prefix(4).map(\.text).joined(separator: " "),
                prompts: [],
                validStructuredPrompts: false,
                totalMilliseconds: elapsed(totalStartedAt),
                stageMilliseconds: [
                    "ocr": ocrMilliseconds,
                    "analysis": analysisMilliseconds,
                    "prompt_generation": elapsed(promptStartedAt)
                ],
                warnings: [error.localizedDescription]
            )
        }
        let promptMilliseconds = elapsed(promptStartedAt)
        let valid = generation.error == nil && promptContractIsValid(generation.prompts)
        return RawPipelineResult(
            name: "Current Theia (OCR cascade)",
            model: model,
            subject: report.intent.identifiedSubject ?? "Unknown",
            category: report.intent.category,
            subcategory: report.intent.subcategory,
            summary: report.importantText.prefix(6).map(\.text).joined(separator: " "),
            prompts: generation.prompts,
            validStructuredPrompts: valid,
            totalMilliseconds: elapsed(totalStartedAt),
            stageMilliseconds: [
                "ocr": ocrMilliseconds,
                "analysis": analysisMilliseconds,
                "prompt_generation": promptMilliseconds
            ],
            warnings: [generation.error].compactMap { $0 }
        )
    }

    private static func runVision(
        imageData: Data,
        sourceContext: ScreenSourceContext,
        model: String,
        baseURL: URL,
        runtime: OllamaRuntimeManager,
        promptMode: QwenVisionPromptMode
    ) async throws -> RawPipelineResult {
        let startedAt = Date()
        let result = try await QwenVisionPromptService(
            modelName: model,
            baseURL: baseURL,
            runtimeManager: runtime
        ).analyzeAndGeneratePrompts(
            pngData: imageData,
            sourceContext: sourceContext,
            mode: promptMode
        )
        return RawPipelineResult(
            name: "Qwen3-VL direct vision",
            model: model,
            subject: result.subject,
            category: result.category,
            subcategory: result.subcategory,
            summary: result.screenSummary,
            prompts: result.prompts,
            validStructuredPrompts: promptContractIsValid(result.prompts),
            totalMilliseconds: elapsed(startedAt),
            stageMilliseconds: [
                "model_load": result.diagnostic.modelLoadMilliseconds ?? 0,
                "prompt_evaluation": result.diagnostic.promptEvaluationMilliseconds ?? 0,
                "generation": result.diagnostic.generationMilliseconds ?? 0
            ],
            warnings: []
        )
    }

    private static func qualityScores(
        _ result: RawPipelineResult,
        expectedTerms: [String],
        distractorTerms: [String]
    ) -> QualityScores {
        let text = outputText(result)
        let normalizedExpected = expectedTerms.map { $0.lowercased() }
        let subjectText = result.subject.lowercased()
        let summaryText = result.summary.lowercased()
        let promptText = result.prompts.flatMap { prompt in
            [prompt.text] + prompt.searchOptions.flatMap { [$0.title, $0.query] }
        }.joined(separator: " ").lowercased()
        let subjectMatched = normalizedExpected.contains { subjectText.contains($0) }
        let summaryMatched = normalizedExpected.contains { summaryText.contains($0) }
        let promptMatches = normalizedExpected.filter { promptText.contains($0) }
        let grounding: Double
        if normalizedExpected.isEmpty {
            grounding = 20
        } else {
            let promptCoverage = Double(promptMatches.count) / Double(normalizedExpected.count)
            grounding = (subjectMatched ? 15 : 0) +
                (summaryMatched ? 5 : 0) +
                20 * promptCoverage
        }

        let prompts = result.prompts
        let uniqueActions = prompts.count == 4 &&
            Set(prompts.map { $0.action.rawValue }).count == prompts.count
        let uniqueQuestions = prompts.count == 4 &&
            Set(prompts.map { $0.text.lowercased() }).count == prompts.count
        let choicesValid = prompts.count == 4 && prompts.allSatisfy { $0.searchOptions.count == 3 }
        let allQueries = prompts.flatMap(\.searchOptions).map { $0.query.lowercased() }
        let queriesUnique = allQueries.count == 12 && Set(allQueries).count == allQueries.count
        let urlsAbsent = allQueries.count == 12 &&
            allQueries.allSatisfy { URL(string: $0)?.scheme == nil }
        let semanticsValid = prompts.count == 4 && prompts.allSatisfy {
            questionMatchesAction($0.text, action: $0.action)
        }
        let contract = (result.validStructuredPrompts ? 8.0 : 0) +
            (uniqueActions && uniqueQuestions ? 8 : 0) +
            (choicesValid ? 8 : 0) +
            (queriesUnique && urlsAbsent ? 8 : 0) +
            (semanticsValid ? 8 : 0)

        let leaked = distractorTerms.map { $0.lowercased() }.filter { text.contains($0) }
        let focus: Double
        if distractorTerms.isEmpty {
            focus = 10
        } else {
            focus = max(0, 20 * (1 - Double(leaked.count) / Double(distractorTerms.count)))
        }
        return QualityScores(
            grounding: min(40, grounding),
            contract: min(40, contract),
            focus: min(20, focus)
        )
    }

    private static func outputText(_ result: RawPipelineResult) -> String {
        ([result.subject, result.summary] + result.prompts.flatMap { prompt in
            [prompt.text, prompt.rationale] + prompt.evidence +
                prompt.searchOptions.flatMap { [$0.title, $0.query] }
        }).joined(separator: " ").lowercased()
    }

    private static func promptContractIsValid(_ prompts: [IntentPromptSuggestion]) -> Bool {
        guard prompts.count == 4,
              Set(prompts.map { $0.action.rawValue }).count == 4,
              Set(prompts.map { $0.text.lowercased() }).count == 4
        else { return false }
        return prompts.allSatisfy { prompt in
            let queries = prompt.searchOptions.map { $0.query.lowercased() }
            return prompt.searchOptions.count == 3 &&
                Set(queries).count == 3 &&
                queries.allSatisfy { URL(string: $0)?.scheme == nil }
        }
    }

    private static func questionMatchesAction(
        _ question: String,
        action: SuggestedPromptAction
    ) -> Bool {
        let value = question.lowercased()
        let terms: [String]
        switch action {
        case .discoverSimilar: terms = ["similar", "like this", "related"]
        case .findComplementary: terms = ["complement", "related", "companion"]
        case .exploreStyling: terms = ["style", "outfit", "wear"]
        case .compareAlternatives: terms = ["compare", "alternative", "versus"]
        case .findIndependentReviews: terms = ["independent", "review", "verify"]
        case .learnPrerequisite: terms = ["prerequisite", "foundation", "before"]
        case .findLearningMaterial: terms = ["course", "tutorial", "resource", "learn"]
        case .exploreApplications: terms = ["application", "use case", "used"]
        case .learnNextTopic: terms = ["next topic", "learn next", "continue"]
        case .findFlights: terms = ["flight", "fly"]
        case .discoverRestaurants: terms = ["restaurant", "eat", "dining"]
        case .exploreDestination: terms = ["destination", "visit", "place"]
        case .planItinerary: terms = ["itinerary", "trip plan", "schedule"]
        case .codingAssistance: terms = ["code", "implement", "program"]
        case .debugIssue: terms = ["debug", "error", "issue", "fix"]
        case .testSolution: terms = ["test", "verify solution"]
        case .findImplementationExamples: terms = ["example", "implementation"]
        case .productivityNextStep: terms = ["next step", "do next", "priority"]
        case .summarizeWork: terms = ["summary", "summarize", "recap"]
        case .improveWorkflow: terms = ["workflow", "process", "efficient"]
        case .discoverMedia: terms = ["media", "video", "image", "music", "movie", "book"]
        case .generalAssistance: return true
        }
        return terms.contains { value.contains($0) }
    }

    private static func elapsed(_ startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func values(for flag: String, in arguments: [String]) -> [String] {
        arguments.enumerated().compactMap { index, value in
            guard value == flag, index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
    }
}

private struct BenchmarkFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
