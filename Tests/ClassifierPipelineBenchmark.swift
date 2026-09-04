import AppKit
import Foundation
import ImageIO

private struct BenchmarkScenario: Decodable {
    let id: String
    let label: String
    let applicationName: String
    let bundleIdentifier: String
    let windowTitle: String?
    let websites: [String]
    let ocrText: String
    let expectedCategory: String
    let expectedSubcategory: String?
    let expectedSubject: String?
    let screenshotPath: String?
}

private struct SelectedBenchmarkCase {
    let scenario: BenchmarkScenario
    let variant: Int

    var id: String { "\(scenario.id)_v\(variant + 1)" }
}

private struct BenchmarkCaseResult: Codable {
    let id: String
    let websiteType: String
    let expectedCategory: String
    let observedCategory: String
    let expectedSubcategory: String?
    let observedSubcategory: String?
    let expectedSubject: String?
    let observedSubject: String?
    let classificationMethod: ClassificationMethod
    let parentCategoryCorrect: Bool
    let subcategoryCorrect: Bool
    let subjectCorrect: Bool
    let classificationCorrect: Bool
    let classificationMilliseconds: Double
    var promptMilliseconds: Double?
    var promptSuccessful: Bool?
    var endToEndCorrect: Bool?
    var promptError: String?
}

private struct BenchmarkArchitectureResult: Codable {
    let mode: IntentClassificationMode
    let classificationCaseCount: Int
    let promptCaseCount: Int
    let classificationCorrect: Int
    let classificationAccuracy: Double
    let parentCategoryCorrect: Int
    let parentCategoryAccuracy: Double
    let subcategoryCaseCount: Int
    let subcategoryCorrect: Int
    let subcategoryAccuracy: Double
    let subjectCaseCount: Int
    let subjectCorrect: Int
    let subjectAccuracy: Double
    let promptSuccessful: Int
    let promptSuccessRate: Double
    let endToEndCorrect: Int
    let endToEndAccuracy: Double
    let averageClassificationMilliseconds: Double
    let p50ClassificationMilliseconds: Double
    let p95ClassificationMilliseconds: Double
    let classificationThroughputCasesPerSecond: Double
    let averagePromptMilliseconds: Double
    let p50PromptMilliseconds: Double
    let p95PromptMilliseconds: Double
    let averageEndToEndMilliseconds: Double
    let p50EndToEndMilliseconds: Double
    let p95EndToEndMilliseconds: Double
    let endToEndThroughputCasesPerSecond: Double
    let classificationMethodCounts: [String: Int]
    let cases: [BenchmarkCaseResult]
}

private struct ClassifierBenchmarkReport: Codable {
    let schemaVersion: String
    let generatedAt: Date
    let model: String
    let bertModel: String
    let classificationCaseCount: Int
    let promptCaseCount: Int
    let warmModel: Bool
    let sequentialExecution: Bool
    let heldOutRealScreenshotCorpus: Bool
    let minimumParentCategoryAccuracy: Double
    let minimumPromptSuccessRate: Double
    let replacementEligible: Bool
    let accuracyDefinition: String
    let promptSuccessDefinition: String
    let environment: [String: String]
    let architectures: [BenchmarkArchitectureResult]
    let notes: [String]
}

private struct PipelineBreakdown {
    let mode: IntentClassificationMode
    let classificationAccuracy: Double
    let promptSuccessRate: Double
    let endToEndAccuracy: Double
}

@main
struct ClassifierPipelineBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let inputPath = value(for: "--input", in: arguments)
            ?? "Tests/WebsiteEvaluationSuite.json"
        let outputPath = value(for: "--output", in: arguments)
            ?? "BenchmarkResults/classifier-pipeline-benchmark.json"
        let svgPath = value(for: "--svg", in: arguments)
            ?? "BenchmarkResults/classifier-speed-accuracy.svg"

        if let reportPath = value(for: "--render-report", in: arguments) {
            let reportData = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(ClassifierBenchmarkReport.self, from: reportData)
            try write(Data(renderSVG(report).utf8), to: svgPath)
            print("Wrote \(svgPath)")
            return
        }

        let model = value(for: "--model", in: arguments) ?? "qwen3:4b"
        let bertModel = value(for: "--bert-model", in: arguments) ?? "all-minilm"
        let requestedClassificationCases = max(
            2,
            Int(value(for: "--classification-cases", in: arguments) ?? "12") ?? 12
        )
        let requestedPromptCases = max(
            1,
            Int(value(for: "--prompt-cases", in: arguments) ?? "3") ?? 3
        )
        let minimumParentAccuracy = min(
            1,
            max(0, Double(value(for: "--minimum-parent-accuracy", in: arguments) ?? "0.99") ?? 0.99)
        )
        let minimumPromptSuccess = min(
            1,
            max(0, Double(value(for: "--minimum-prompt-success", in: arguments) ?? "0.99") ?? 0.99)
        )
        let heldOutRequested = arguments.contains("--held-out-real-screenshots")
        let enforceReplacementGate = arguments.contains("--enforce-replacement-gate")

        let scenarios = try loadScenarios(from: URL(fileURLWithPath: inputPath))
        let selectedCases = stratifiedCases(
            from: scenarios,
            count: min(requestedClassificationCases, scenarios.count)
        )
        let promptCases = Array(selectedCases.prefix(min(requestedPromptCases, selectedCases.count)))
        guard let warmupCase = selectedCases.first else {
            throw BenchmarkFailure("No benchmark scenarios were loaded.")
        }
        var documentsByID: [String: OCRDocument] = [:]
        for selected in selectedCases {
            documentsByID[selected.id] = try await document(for: selected)
        }
        let realScreenshotCorpus = heldOutRequested && selectedCases.allSatisfy {
            $0.scenario.screenshotPath?.isEmpty == false
        }

        let configuration = LocalModelConfiguration(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            bertModel: bertModel,
            qwenModel: model,
            ruleAcceptanceThreshold: 0.90,
            bertAcceptanceThreshold: 0.90,
            memoryLearningThreshold: 0.90
        )
        let localModels = OllamaLocalModelClient(baseURL: configuration.baseURL)
        let analysis = ContextAnalysisService()

        print("Warming \(model) with one unmeasured Qwen-only classification...")
        let warmupClassifier = IntentClassificationService(
            configuration: configuration,
            localModels: localModels,
            memoryStore: nil,
            mode: .qwenOnly
        )
        _ = await analysis.analyze(
            documentsByID[warmupCase.id] ?? OCRDocument(lines: []),
            sourceContext: sourceContext(for: warmupCase),
            intentClassifier: warmupClassifier
        )

        var architectureResults: [BenchmarkArchitectureResult] = []
        for mode in [IntentClassificationMode.cascade, .qwenOnly] {
            print("Benchmarking \(mode.rawValue)...")
            let result = await benchmark(
                mode: mode,
                selectedCases: selectedCases,
                promptCases: promptCases,
                documentsByID: documentsByID,
                configuration: configuration,
                localModels: localModels,
                analysis: analysis
            )
            architectureResults.append(result)
            printSummary(result)
        }
        let gatedArchitecture = architectureResults.first { $0.mode == .cascade }
        let replacementEligible = realScreenshotCorpus &&
            gatedArchitecture?.promptCaseCount == promptCases.count &&
            (gatedArchitecture?.parentCategoryAccuracy ?? 0) >= minimumParentAccuracy &&
            (gatedArchitecture?.promptSuccessRate ?? 0) >= minimumPromptSuccess

        let report = ClassifierBenchmarkReport(
            schemaVersion: "2.0",
            generatedAt: Date(),
            model: model,
            bertModel: bertModel,
            classificationCaseCount: selectedCases.count,
            promptCaseCount: promptCases.count,
            warmModel: true,
            sequentialExecution: true,
            heldOutRealScreenshotCorpus: realScreenshotCorpus,
            minimumParentCategoryAccuracy: minimumParentAccuracy,
            minimumPromptSuccessRate: minimumPromptSuccess,
            replacementEligible: replacementEligible,
            accuracyDefinition: "Parent category, optional exact subcategory, and optional exact grounded subject are reported separately; combined accuracy requires every labeled field.",
            promptSuccessDefinition: "No generation warning, expected unique action keys, and exactly three accepted choices per prompt.",
            environment: [
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": String(ProcessInfo.processInfo.processorCount),
                "activeProcessorCount": String(ProcessInfo.processInfo.activeProcessorCount)
            ],
            architectures: architectureResults,
            notes: [
                "The cascade may stop at rules, BERT, or Qwen; qwen_only skips rules and BERT.",
                "Both architectures use the same Qwen model and prompt-generation implementation.",
                "Web search is disabled so the timing comparison isolates local classification and prompt inference.",
                "Up to four prompt actions share one structured Qwen request; deterministic fallbacks do not count as accepted model JSON.",
                "Replacement eligibility requires a held-out corpus backed by real screenshotPath values.",
                "Synthetic OCR cases remain useful regressions but can never authorize a replacement model."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try write(data, to: outputPath)
        try write(Data(renderSVG(report).utf8), to: svgPath)
        print("Wrote \(outputPath)")
        print("Wrote \(svgPath)")
        print("Replacement gate: \(replacementEligible ? "passed" : "not passed")")
        if enforceReplacementGate && !replacementEligible {
            throw BenchmarkFailure(
                "Replacement gate failed: require a held-out real-screenshot corpus with at least \(percent(minimumParentAccuracy)) parent-category accuracy and \(percent(minimumPromptSuccess)) valid prompt JSON."
            )
        }
    }

    private static func benchmark(
        mode: IntentClassificationMode,
        selectedCases: [SelectedBenchmarkCase],
        promptCases: [SelectedBenchmarkCase],
        documentsByID: [String: OCRDocument],
        configuration: LocalModelConfiguration,
        localModels: OllamaLocalModelClient,
        analysis: ContextAnalysisService
    ) async -> BenchmarkArchitectureResult {
        let classifier = IntentClassificationService(
            configuration: configuration,
            localModels: localModels,
            memoryStore: nil,
            mode: mode
        )
        let promptService = IntentPromptSuggestionService(
            modelName: configuration.qwenModel,
            localModels: localModels,
            webSearch: nil
        )
        var reportsByID: [String: ScreenContextReport] = [:]
        var results: [BenchmarkCaseResult] = []

        for selected in selectedCases {
            let startedAt = Date()
            let report = await analysis.analyze(
                documentsByID[selected.id] ?? OCRDocument(lines: []),
                sourceContext: sourceContext(for: selected),
                intentClassifier: classifier
            )
            let duration = Date().timeIntervalSince(startedAt) * 1_000
            reportsByID[selected.id] = report
            let categoryCorrect = report.intent.category.rawValue == selected.scenario.expectedCategory
            let subcategoryCorrect = selected.scenario.expectedSubcategory == nil ||
                report.intent.subcategory?.rawValue == selected.scenario.expectedSubcategory
            let subjectCorrect = selected.scenario.expectedSubject == nil ||
                report.intent.identifiedSubject == selected.scenario.expectedSubject
            results.append(
                BenchmarkCaseResult(
                    id: selected.id,
                    websiteType: selected.scenario.id,
                    expectedCategory: selected.scenario.expectedCategory,
                    observedCategory: report.intent.category.rawValue,
                    expectedSubcategory: selected.scenario.expectedSubcategory,
                    observedSubcategory: report.intent.subcategory?.rawValue,
                    expectedSubject: selected.scenario.expectedSubject,
                    observedSubject: report.intent.identifiedSubject,
                    classificationMethod: report.intent.method,
                    parentCategoryCorrect: categoryCorrect,
                    subcategoryCorrect: subcategoryCorrect,
                    subjectCorrect: subjectCorrect,
                    classificationCorrect: categoryCorrect && subcategoryCorrect && subjectCorrect,
                    classificationMilliseconds: rounded(duration),
                    promptMilliseconds: nil,
                    promptSuccessful: nil,
                    endToEndCorrect: nil,
                    promptError: nil
                )
            )
        }

        let eligiblePromptCases = selectedCases.filter { selected in
            guard let report = reportsByID[selected.id] else { return false }
            return promptService.webResearchRequirement(for: report) == nil
        }.prefix(promptCases.count)
        for selected in eligiblePromptCases {
            guard let report = reportsByID[selected.id],
                  let index = results.firstIndex(where: { $0.id == selected.id })
            else { continue }

            let startedAt = Date()
            do {
                let generation = try await promptService.generate(for: report)
                let duration = Date().timeIntervalSince(startedAt) * 1_000
                let expectedActions = promptService.expectedActions(for: report.intent)
                let promptSuccessful = generation.error == nil &&
                    generation.prompts.map(\.action) == expectedActions &&
                    Set(generation.prompts.map(\.action)).count == expectedActions.count &&
                    generation.prompts.allSatisfy { $0.searchOptions.count == 3 }
                results[index].promptMilliseconds = rounded(duration)
                results[index].promptSuccessful = promptSuccessful
                results[index].endToEndCorrect = results[index].classificationCorrect && promptSuccessful
                results[index].promptError = generation.error
            } catch {
                let duration = Date().timeIntervalSince(startedAt) * 1_000
                results[index].promptMilliseconds = rounded(duration)
                results[index].promptSuccessful = false
                results[index].endToEndCorrect = false
                results[index].promptError = error.localizedDescription
            }
        }

        let classificationDurations = results.map(\.classificationMilliseconds)
        let promptResults = results.filter { $0.promptMilliseconds != nil }
        let promptDurations = promptResults.compactMap(\.promptMilliseconds)
        let endToEndDurations = promptResults.compactMap { result -> Double? in
            guard let prompt = result.promptMilliseconds else { return nil }
            return result.classificationMilliseconds + prompt
        }
        let classificationCorrect = results.filter(\.classificationCorrect).count
        let parentCategoryCorrect = results.filter(\.parentCategoryCorrect).count
        let subcategoryResults = results.filter { $0.expectedSubcategory != nil }
        let subcategoryCorrect = subcategoryResults.filter(\.subcategoryCorrect).count
        let subjectResults = results.filter { $0.expectedSubject != nil }
        let subjectCorrect = subjectResults.filter(\.subjectCorrect).count
        let promptSuccessful = promptResults.filter { $0.promptSuccessful == true }.count
        let endToEndCorrect = promptResults.filter { $0.endToEndCorrect == true }.count
        let averageClassification = average(classificationDurations)
        let averagePrompt = average(promptDurations)
        let averageEndToEnd = average(endToEndDurations)
        let methodCounts = Dictionary(
            grouping: results,
            by: { $0.classificationMethod.rawValue }
        ).mapValues(\.count)

        return BenchmarkArchitectureResult(
            mode: mode,
            classificationCaseCount: results.count,
            promptCaseCount: promptResults.count,
            classificationCorrect: classificationCorrect,
            classificationAccuracy: rate(classificationCorrect, results.count),
            parentCategoryCorrect: parentCategoryCorrect,
            parentCategoryAccuracy: rate(parentCategoryCorrect, results.count),
            subcategoryCaseCount: subcategoryResults.count,
            subcategoryCorrect: subcategoryCorrect,
            subcategoryAccuracy: rate(subcategoryCorrect, subcategoryResults.count),
            subjectCaseCount: subjectResults.count,
            subjectCorrect: subjectCorrect,
            subjectAccuracy: rate(subjectCorrect, subjectResults.count),
            promptSuccessful: promptSuccessful,
            promptSuccessRate: rate(promptSuccessful, promptResults.count),
            endToEndCorrect: endToEndCorrect,
            endToEndAccuracy: rate(endToEndCorrect, promptResults.count),
            averageClassificationMilliseconds: rounded(averageClassification),
            p50ClassificationMilliseconds: rounded(percentile(classificationDurations, 0.50)),
            p95ClassificationMilliseconds: rounded(percentile(classificationDurations, 0.95)),
            classificationThroughputCasesPerSecond: rounded(1_000 / max(averageClassification, 0.001)),
            averagePromptMilliseconds: rounded(averagePrompt),
            p50PromptMilliseconds: rounded(percentile(promptDurations, 0.50)),
            p95PromptMilliseconds: rounded(percentile(promptDurations, 0.95)),
            averageEndToEndMilliseconds: rounded(averageEndToEnd),
            p50EndToEndMilliseconds: rounded(percentile(endToEndDurations, 0.50)),
            p95EndToEndMilliseconds: rounded(percentile(endToEndDurations, 0.95)),
            endToEndThroughputCasesPerSecond: rounded(1_000 / max(averageEndToEnd, 0.001)),
            classificationMethodCounts: methodCounts,
            cases: results
        )
    }

    private static func printSummary(_ result: BenchmarkArchitectureResult) {
        print(
            "  parent category: \(percent(result.parentCategoryAccuracy)); " +
            "combined labeled fields: \(percent(result.classificationAccuracy)), " +
            "\(result.p50ClassificationMilliseconds) ms p50 / \(result.p95ClassificationMilliseconds) ms p95, " +
            "\(result.classificationThroughputCasesPerSecond) cases/s"
        )
        print(
            "  prompt acceptance: \(percent(result.promptSuccessRate)), " +
            "\(result.p50PromptMilliseconds) ms p50 / \(result.p95PromptMilliseconds) ms p95"
        )
        print(
            "  end-to-end: \(percent(result.endToEndAccuracy)), " +
            "\(result.p50EndToEndMilliseconds) ms p50 / \(result.p95EndToEndMilliseconds) ms p95"
        )
    }

    private static func stratifiedCases(
        from scenarios: [BenchmarkScenario],
        count: Int
    ) -> [SelectedBenchmarkCase] {
        let categoryOrder = scenarios.reduce(into: [String]()) { order, scenario in
            if !order.contains(scenario.expectedCategory) {
                order.append(scenario.expectedCategory)
            }
        }
        let buckets = Dictionary(grouping: scenarios, by: \.expectedCategory)
        var offsets = Dictionary(uniqueKeysWithValues: categoryOrder.map { ($0, 0) })
        var selected: [SelectedBenchmarkCase] = []

        while selected.count < count {
            var added = false
            for category in categoryOrder where selected.count < count {
                let offset = offsets[category, default: 0]
                guard let bucket = buckets[category], offset < bucket.count else { continue }
                selected.append(
                    SelectedBenchmarkCase(
                        scenario: bucket[offset],
                        variant: selected.count % 7
                    )
                )
                offsets[category] = offset + 1
                added = true
            }
            if !added { break }
        }
        return selected
    }

    private static func document(for selected: SelectedBenchmarkCase) async throws -> OCRDocument {
        if let screenshotPath = selected.scenario.screenshotPath,
           !screenshotPath.isEmpty {
            let screenshotURL = URL(fileURLWithPath: screenshotPath)
            guard let imageSource = CGImageSourceCreateWithURL(screenshotURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            else {
                throw BenchmarkFailure("Could not load screenshot for \(selected.id): \(screenshotPath)")
            }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            return try await OCRService().recognizeText(
                in: CapturedFrame(cgImage: cgImage, image: image)
            )
        }

        var lines = selected.scenario.ocrText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let heading = lines.first else { return OCRDocument(lines: []) }
        var body = Array(lines.dropFirst())
        if !body.isEmpty {
            let shift = selected.variant % body.count
            body = Array(body[shift...]) + Array(body[..<shift])
        }
        let noiseSets = [
            [String](),
            ["Menu", "Sign in"],
            ["Sponsored", "Advertisement"],
            ["Cookie settings", "Privacy"],
            ["Home", "Search"],
            ["Notifications", "Profile"],
            ["Help", "Contact"]
        ]
        lines = [heading] + body + noiseSets[selected.variant % noiseSets.count]

        return OCRDocument(
            lines: lines.enumerated().map { index, line in
                OCRTextLine(
                    text: line,
                    confidence: 0.92 + Double((selected.variant + index) % 8) * 0.01,
                    boundingBox: NormalizedBoundingBox(
                        x: 0.04 + Double((selected.variant + index) % 4) * 0.01,
                        y: max(0.05, 0.92 - Double(index) * 0.09),
                        width: index == 0 ? 0.72 : 0.64,
                        height: index == 0 ? 0.052 : 0.03
                    )
                )
            }
        )
    }

    private static func sourceContext(for selected: SelectedBenchmarkCase) -> ScreenSourceContext {
        let browsers = [
            ("Safari", "com.apple.Safari"),
            ("Chrome", "com.google.Chrome"),
            ("Microsoft Edge", "com.microsoft.edgemac")
        ]
        let browser = browsers[selected.variant % browsers.count]
        let host = selected.scenario.websites.first ?? ""
        let website: String
        switch selected.variant % 4 {
        case 1: website = host.hasPrefix("www.") ? host : "www.\(host)"
        case 2: website = host.hasPrefix("m.") ? host : "m.\(host)"
        default: website = host
        }
        let title: String?
        switch selected.variant % 5 {
        case 1: title = selected.scenario.windowTitle.map { "\($0) - Safari" }
        case 2: title = selected.scenario.windowTitle.map { "\($0) - Google Chrome" }
        case 3: title = selected.scenario.windowTitle.map { "\($0) | \(host)" }
        default: title = selected.scenario.windowTitle
        }
        return ScreenSourceContext(
            applicationName: browser.0,
            bundleIdentifier: browser.1,
            windowTitle: title,
            websites: website.isEmpty ? [] : [website]
        )
    }

    private static func renderSVG(_ report: ClassifierBenchmarkReport) -> String {
        let width = 1_200.0
        let height = 720.0
        let panels = [
            (
                title: "Classification only",
                subtitle: "Exact category + subject",
                x: 70.0,
                values: report.architectures.map {
                    ($0.mode, $0.classificationThroughputCasesPerSecond, $0.classificationAccuracy)
                },
                breakdowns: []
            ),
            (
                title: "Pipeline outcomes",
                subtitle: "Combined point requires classification + accepted prompts",
                x: 635.0,
                values: report.architectures.map {
                    ($0.mode, $0.endToEndThroughputCasesPerSecond, $0.endToEndAccuracy)
                },
                breakdowns: report.architectures.map {
                    PipelineBreakdown(
                        mode: $0.mode,
                        classificationAccuracy: $0.classificationAccuracy,
                        promptSuccessRate: $0.promptSuccessRate,
                        endToEndAccuracy: $0.endToEndAccuracy
                    )
                }
            )
        ]
        var body = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width))" height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))">
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#f7f1e4"/>
              <stop offset="1" stop-color="#e8f2ee"/>
            </linearGradient>
            <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
              <feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#173c3b" flood-opacity="0.12"/>
            </filter>
          </defs>
          <rect width="1200" height="720" fill="url(#bg)"/>
          <text x="70" y="70" font-family="Georgia, serif" font-size="34" font-weight="700" fill="#102f2e">Theia speed vs accuracy</text>
          <text x="70" y="102" font-family="Avenir Next, sans-serif" font-size="16" fill="#4c625e">\(escape(report.model)) | warm, sequential local benchmark | \(report.classificationCaseCount) classification cases, \(report.promptCaseCount) prompt cases</text>
        """

        for panel in panels {
            body += renderPanel(
                title: panel.title,
                subtitle: panel.subtitle,
                originX: panel.x,
                values: panel.values,
                breakdowns: panel.breakdowns
            )
        }

        body += """
          <circle cx="76" cy="674" r="7" fill="#087f78"/><text x="92" y="680" font-family="Avenir Next, sans-serif" font-size="15" fill="#284744">Rule / BERT / Qwen cascade</text>
          <circle cx="330" cy="674" r="7" fill="#e56b2f"/><text x="346" y="680" font-family="Avenir Next, sans-serif" font-size="15" fill="#284744">Qwen-only classification</text>
          <text x="1130" y="680" text-anchor="end" font-family="Avenir Next, sans-serif" font-size="13" fill="#63746f">Higher and farther right is better</text>
        </svg>
        """
        return body
    }

    private static func renderPanel(
        title: String,
        subtitle: String,
        originX: Double,
        values: [(IntentClassificationMode, Double, Double)],
        breakdowns: [PipelineBreakdown] = []
    ) -> String {
        let panelWidth = 500.0
        let panelY = 135.0
        let panelHeight = 490.0
        let plotX = originX + 70
        let plotY = panelY + 105
        let plotWidth = 390.0
        let plotHeight = 315.0
        let speeds = values.map { max($0.1, 0.0001) }
        let logs = speeds.map { log10($0) }
        let rawMin = logs.min() ?? -3
        let rawMax = logs.max() ?? 3
        let padding = max(0.35, (rawMax - rawMin) * 0.18)
        let minLog = rawMin - padding
        let maxLog = rawMax + padding
        func x(_ speed: Double) -> Double {
            plotX + ((log10(max(speed, 0.0001)) - minLog) / max(0.001, maxLog - minLog)) * plotWidth
        }
        func y(_ accuracy: Double) -> Double {
            plotY + (1 - min(1, max(0, accuracy))) * plotHeight
        }

        var svg = """
          <g filter="url(#shadow)"><rect x="\(originX)" y="\(panelY)" width="\(panelWidth)" height="\(panelHeight)" rx="24" fill="#fffdf7"/></g>
          <text x="\(originX + 28)" y="\(panelY + 42)" font-family="Georgia, serif" font-size="24" font-weight="700" fill="#163b39">\(escape(title))</text>
          <text x="\(originX + 28)" y="\(panelY + 69)" font-family="Avenir Next, sans-serif" font-size="14" fill="#687973">\(escape(subtitle))</text>
        """
        for tick in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let tickY = y(tick)
            svg += "<line x1=\"\(plotX)\" y1=\"\(tickY)\" x2=\"\(plotX + plotWidth)\" y2=\"\(tickY)\" stroke=\"#d9e2dd\" stroke-width=\"1\"/>"
            svg += "<text x=\"\(plotX - 12)\" y=\"\(tickY + 5)\" text-anchor=\"end\" font-family=\"Avenir Next, sans-serif\" font-size=\"12\" fill=\"#71817c\">\(Int(tick * 100))%</text>"
        }
        svg += "<line x1=\"\(plotX)\" y1=\"\(plotY + plotHeight)\" x2=\"\(plotX + plotWidth)\" y2=\"\(plotY + plotHeight)\" stroke=\"#49635f\" stroke-width=\"1.5\"/>"
        svg += "<text x=\"\(plotX + plotWidth / 2)\" y=\"\(plotY + plotHeight + 48)\" text-anchor=\"middle\" font-family=\"Avenir Next, sans-serif\" font-size=\"13\" fill=\"#526964\">Throughput, cases/second (log scale)</text>"
        svg += "<text x=\"\(plotX)\" y=\"\(plotY + plotHeight + 23)\" text-anchor=\"start\" font-family=\"Avenir Next, sans-serif\" font-size=\"11\" fill=\"#71817c\">\(formatSpeed(pow(10, minLog)))</text>"
        svg += "<text x=\"\(plotX + plotWidth)\" y=\"\(plotY + plotHeight + 23)\" text-anchor=\"end\" font-family=\"Avenir Next, sans-serif\" font-size=\"11\" fill=\"#71817c\">\(formatSpeed(pow(10, maxLog)))</text>"

        for value in values {
            let color = value.0 == .cascade ? "#087f78" : "#e56b2f"
            let pointX = x(value.1)
            let pointY = y(value.2)
            let anchor = pointX > plotX + plotWidth * 0.67 ? "end" : "start"
            let labelX = pointX > plotX + plotWidth * 0.67 ? pointX - 13 : pointX + 13
            svg += "<circle cx=\"\(pointX)\" cy=\"\(pointY)\" r=\"10\" fill=\"\(color)\" stroke=\"#fffdf7\" stroke-width=\"4\"/>"
            svg += "<text x=\"\(labelX)\" y=\"\(pointY - 17)\" text-anchor=\"\(anchor)\" font-family=\"Avenir Next, sans-serif\" font-size=\"13\" font-weight=\"700\" fill=\"\(color)\">\(value.0 == .cascade ? "Cascade" : "Qwen only")</text>"
            let metricPrefix = breakdowns.isEmpty ? "" : "Both "
            svg += "<text x=\"\(labelX)\" y=\"\(pointY + 2)\" text-anchor=\"\(anchor)\" font-family=\"Avenir Next, sans-serif\" font-size=\"12\" fill=\"#425b56\">\(metricPrefix)\(percent(value.2)) at \(formatSpeed(value.1))/s</text>"
            if let breakdown = breakdowns.first(where: { $0.mode == value.0 }) {
                svg += "<text x=\"\(labelX)\" y=\"\(pointY + 21)\" text-anchor=\"\(anchor)\" font-family=\"Avenir Next, sans-serif\" font-size=\"11\" fill=\"#687973\">Class \(percent(breakdown.classificationAccuracy)) · Prompts \(percent(breakdown.promptSuccessRate))</text>"
            }
        }
        return svg
    }

    private static func loadScenarios(from url: URL) throws -> [BenchmarkScenario] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([BenchmarkScenario].self, from: data)
    }

    private static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    private static func rate(_ count: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return rounded(Double(count) / Double(total))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func formatSpeed(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        if value >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.3f", value)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct BenchmarkFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
