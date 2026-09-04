import Foundation

struct WebsiteEvaluationScenario: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let applicationName: String
    let bundleIdentifier: String
    let windowTitle: String?
    let websites: [String]
    let ocrText: String
    let expectedCategory: String
    let expectedSubject: String?
}

struct WebsiteEvaluationFailureSample: Codable, Equatable {
    let id: String
    let websiteType: String
    let variant: Int
    let expectedCategory: String
    let observedCategory: String?
    let expectedSubject: String?
    let observedSubject: String?
    let reasons: [String]
}

struct WebsiteTypeEvaluationSummary: Codable, Equatable {
    let id: String
    let label: String
    let expectedCategory: String
    let total: Int
    let passed: Int
    let passRate: Double
    let categoryReady: Int
    let subjectReady: Int
    let reportJSONReady: Int
    let actionableJSONReady: Int
    let qwenPayloadReady: Int
    let promptContractReady: Int
    let validatorContractReady: Int
    let failureReasons: [String: Int]
}

struct WebsiteEvaluationMetrics: Codable, Equatable {
    let total: Int
    let passed: Int
    let failed: Int
    let passRate: Double
    let categoryReady: Int
    let categoryRate: Double
    let subjectReady: Int
    let subjectRate: Double
    let reportJSONReady: Int
    let reportJSONRate: Double
    let actionableJSONReady: Int
    let actionableJSONRate: Double
    let qwenPayloadReady: Int
    let qwenPayloadRate: Double
    let promptContractReady: Int
    let promptContractRate: Double
    let validatorContractReady: Int
    let validatorContractRate: Double
}

struct WebsiteEvaluationPerformance: Codable, Equatable {
    let workers: Int
    let elapsedSeconds: Double
    let evaluationsPerSecond: Double
    let averageMillisecondsPerEvaluation: Double
}

struct WebsiteEvaluationReport: Codable, Equatable {
    let schemaVersion: String
    let generatedAt: Date
    let evaluationKind: String
    let modelName: String
    let websiteTypeCount: Int
    let requestedCases: Int
    let minimumPassRate: Double
    let passed: Bool
    let metrics: WebsiteEvaluationMetrics
    let performance: WebsiteEvaluationPerformance
    let failureReasons: [String: Int]
    let websiteTypes: [WebsiteTypeEvaluationSummary]
    let failureSamples: [WebsiteEvaluationFailureSample]
    let limitations: [String]
}

private struct CaseOutcome {
    let id: String
    let scenario: WebsiteEvaluationScenario
    let variant: Int
    let observedCategory: String?
    let observedSubject: String?
    let categoryReady: Bool
    let subjectReady: Bool
    let reportJSONReady: Bool
    let actionableJSONReady: Bool
    let qwenPayloadReady: Bool
    let promptContractReady: Bool
    let validatorContractReady: Bool
    let reasons: [String]

    var passed: Bool { reasons.isEmpty }
}

private struct TypeCounters {
    let id: String
    let label: String
    let expectedCategory: String
    var total = 0
    var passed = 0
    var categoryReady = 0
    var subjectReady = 0
    var reportJSONReady = 0
    var actionableJSONReady = 0
    var qwenPayloadReady = 0
    var promptContractReady = 0
    var validatorContractReady = 0
    var failureReasons: [String: Int] = [:]

    mutating func record(_ outcome: CaseOutcome) {
        total += 1
        if outcome.passed { passed += 1 }
        if outcome.categoryReady { categoryReady += 1 }
        if outcome.subjectReady { subjectReady += 1 }
        if outcome.reportJSONReady { reportJSONReady += 1 }
        if outcome.actionableJSONReady { actionableJSONReady += 1 }
        if outcome.qwenPayloadReady { qwenPayloadReady += 1 }
        if outcome.promptContractReady { promptContractReady += 1 }
        if outcome.validatorContractReady { validatorContractReady += 1 }
        for reason in outcome.reasons { failureReasons[reason, default: 0] += 1 }
    }

    mutating func merge(_ other: TypeCounters) {
        total += other.total
        passed += other.passed
        categoryReady += other.categoryReady
        subjectReady += other.subjectReady
        reportJSONReady += other.reportJSONReady
        actionableJSONReady += other.actionableJSONReady
        qwenPayloadReady += other.qwenPayloadReady
        promptContractReady += other.promptContractReady
        validatorContractReady += other.validatorContractReady
        for (reason, count) in other.failureReasons {
            failureReasons[reason, default: 0] += count
        }
    }

    func summary() -> WebsiteTypeEvaluationSummary {
        WebsiteTypeEvaluationSummary(
            id: id,
            label: label,
            expectedCategory: expectedCategory,
            total: total,
            passed: passed,
            passRate: rate(passed, total),
            categoryReady: categoryReady,
            subjectReady: subjectReady,
            reportJSONReady: reportJSONReady,
            actionableJSONReady: actionableJSONReady,
            qwenPayloadReady: qwenPayloadReady,
            promptContractReady: promptContractReady,
            validatorContractReady: validatorContractReady,
            failureReasons: failureReasons
        )
    }
}

private struct EvaluationAccumulator {
    var total = 0
    var passed = 0
    var categoryReady = 0
    var subjectReady = 0
    var reportJSONReady = 0
    var actionableJSONReady = 0
    var qwenPayloadReady = 0
    var promptContractReady = 0
    var validatorContractReady = 0
    var failureReasons: [String: Int] = [:]
    var typeCounters: [String: TypeCounters] = [:]
    var failureSamples: [WebsiteEvaluationFailureSample] = []
    let sampleLimit: Int

    mutating func record(_ outcome: CaseOutcome) {
        total += 1
        if outcome.passed { passed += 1 }
        if outcome.categoryReady { categoryReady += 1 }
        if outcome.subjectReady { subjectReady += 1 }
        if outcome.reportJSONReady { reportJSONReady += 1 }
        if outcome.actionableJSONReady { actionableJSONReady += 1 }
        if outcome.qwenPayloadReady { qwenPayloadReady += 1 }
        if outcome.promptContractReady { promptContractReady += 1 }
        if outcome.validatorContractReady { validatorContractReady += 1 }
        for reason in outcome.reasons { failureReasons[reason, default: 0] += 1 }

        var counters = typeCounters[outcome.scenario.id] ?? TypeCounters(
            id: outcome.scenario.id,
            label: outcome.scenario.label,
            expectedCategory: outcome.scenario.expectedCategory
        )
        counters.record(outcome)
        typeCounters[outcome.scenario.id] = counters

        if !outcome.passed && failureSamples.count < sampleLimit {
            failureSamples.append(
                WebsiteEvaluationFailureSample(
                    id: outcome.id,
                    websiteType: outcome.scenario.id,
                    variant: outcome.variant,
                    expectedCategory: outcome.scenario.expectedCategory,
                    observedCategory: outcome.observedCategory,
                    expectedSubject: outcome.scenario.expectedSubject,
                    observedSubject: outcome.observedSubject,
                    reasons: outcome.reasons
                )
            )
        }
    }

    mutating func merge(_ other: EvaluationAccumulator) {
        total += other.total
        passed += other.passed
        categoryReady += other.categoryReady
        subjectReady += other.subjectReady
        reportJSONReady += other.reportJSONReady
        actionableJSONReady += other.actionableJSONReady
        qwenPayloadReady += other.qwenPayloadReady
        promptContractReady += other.promptContractReady
        validatorContractReady += other.validatorContractReady
        for (reason, count) in other.failureReasons {
            failureReasons[reason, default: 0] += count
        }
        for (id, otherCounters) in other.typeCounters {
            if var counters = typeCounters[id] {
                counters.merge(otherCounters)
                typeCounters[id] = counters
            } else {
                typeCounters[id] = otherCounters
            }
        }
        let remaining = max(0, sampleLimit - failureSamples.count)
        failureSamples.append(contentsOf: other.failureSamples.prefix(remaining))
    }
}

@main
struct WebsiteEvaluationRegression {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let inputPath = value(for: "--input", in: arguments) ?? "Tests/WebsiteEvaluationSuite.json"
        let outputPath = value(for: "--output", in: arguments)
        let modelName = value(for: "--model", in: arguments) ?? "deterministic-qwen-readiness-contract"
        let requestedCount = max(1, Int(value(for: "--count", in: arguments) ?? "50") ?? 50)
        let minimumPassRate = min(1, max(0, Double(value(for: "--minimum-pass-rate", in: arguments) ?? "0.99") ?? 0.99))
        let requestedWorkers = Int(value(for: "--workers", in: arguments) ?? "")
        let workers = max(1, min(requestedCount, requestedWorkers ?? min(8, ProcessInfo.processInfo.activeProcessorCount)))
        let sampleLimit = max(0, Int(value(for: "--failure-samples", in: arguments) ?? "200") ?? 200)

        let scenarios = try loadScenarios(from: URL(fileURLWithPath: inputPath))
        guard scenarios.count == 50 else {
            throw EvaluationFailure("The million-case suite must contain exactly 50 website types; found \(scenarios.count).")
        }

        let startedAt = Date()
        var aggregate = EvaluationAccumulator(sampleLimit: sampleLimit)
        await withTaskGroup(of: EvaluationAccumulator.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    await evaluateWorker(
                        worker: worker,
                        workerCount: workers,
                        requestedCount: requestedCount,
                        scenarios: scenarios,
                        sampleLimit: sampleLimit
                    )
                }
            }
            for await partial in group { aggregate.merge(partial) }
        }

        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        let metrics = WebsiteEvaluationMetrics(
            total: aggregate.total,
            passed: aggregate.passed,
            failed: aggregate.total - aggregate.passed,
            passRate: rate(aggregate.passed, aggregate.total),
            categoryReady: aggregate.categoryReady,
            categoryRate: rate(aggregate.categoryReady, aggregate.total),
            subjectReady: aggregate.subjectReady,
            subjectRate: rate(aggregate.subjectReady, aggregate.total),
            reportJSONReady: aggregate.reportJSONReady,
            reportJSONRate: rate(aggregate.reportJSONReady, aggregate.total),
            actionableJSONReady: aggregate.actionableJSONReady,
            actionableJSONRate: rate(aggregate.actionableJSONReady, aggregate.total),
            qwenPayloadReady: aggregate.qwenPayloadReady,
            qwenPayloadRate: rate(aggregate.qwenPayloadReady, aggregate.total),
            promptContractReady: aggregate.promptContractReady,
            promptContractRate: rate(aggregate.promptContractReady, aggregate.total),
            validatorContractReady: aggregate.validatorContractReady,
            validatorContractRate: rate(aggregate.validatorContractReady, aggregate.total)
        )
        let report = WebsiteEvaluationReport(
            schemaVersion: "2.0",
            generatedAt: Date(),
            evaluationKind: "synthetic-variant-matrix",
            modelName: modelName,
            websiteTypeCount: scenarios.count,
            requestedCases: requestedCount,
            minimumPassRate: minimumPassRate,
            passed: metrics.passRate >= minimumPassRate,
            metrics: metrics,
            performance: WebsiteEvaluationPerformance(
                workers: workers,
                elapsedSeconds: rounded(elapsed),
                evaluationsPerSecond: rounded(Double(aggregate.total) / elapsed),
                averageMillisecondsPerEvaluation: rounded(elapsed * 1_000 / Double(aggregate.total))
            ),
            failureReasons: aggregate.failureReasons,
            websiteTypes: aggregate.typeCounters.values.map { $0.summary() }.sorted { $0.id < $1.id },
            failureSamples: aggregate.failureSamples.sorted { $0.id < $1.id },
            limitations: [
                "Cases are deterministic OCR and active-URL variants, not one million live page downloads.",
                "Ground-truth parent labels follow the current 15-category taxonomy, including real_estate for Zillow listings and health for PubMed medical research.",
                "Qwen payload and semantic-validator contracts run on every case; actual qwen3:4b inference does not run one million times.",
                "Live search availability, OCR capture quality, and model nondeterminism require separate sampled end-to-end tests."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        if let outputPath {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }

        print("Website matrix finished: \(aggregate.passed)/\(aggregate.total) fully ready.")
        print("Actionable JSON: \(aggregate.actionableJSONReady)/\(aggregate.total).")
        print("Qwen payload: \(aggregate.qwenPayloadReady)/\(aggregate.total).")
        print("Prompt contract: \(aggregate.promptContractReady)/\(aggregate.total).")
        print("Validator contract: \(aggregate.validatorContractReady)/\(aggregate.total).")
        print("Throughput: \(report.performance.evaluationsPerSecond) cases/s with \(workers) workers.")
        print("Pass threshold: \(minimumPassRate); passed: \(report.passed).")
    }

    private static func evaluateWorker(
        worker: Int,
        workerCount: Int,
        requestedCount: Int,
        scenarios: [WebsiteEvaluationScenario],
        sampleLimit: Int
    ) async -> EvaluationAccumulator {
        let analysis = ContextAnalysisService()
        let intentService = makeIntentService()
        let promptService = IntentPromptSuggestionService(
            modelName: "contract",
            localModels: DisabledPromptModels()
        )
        let jsonService = AnalysisJSONService()
        var accumulator = EvaluationAccumulator(sampleLimit: sampleLimit)

        for index in stride(from: worker, to: requestedCount, by: workerCount) {
            let scenario = scenarios[index % scenarios.count]
            let variant = index / scenarios.count
            let outcome = await evaluate(
                scenario: scenario,
                variant: variant,
                analysis: analysis,
                intentService: intentService,
                promptService: promptService,
                jsonService: jsonService
            )
            accumulator.record(outcome)
        }
        return accumulator
    }

    private static func evaluate(
        scenario: WebsiteEvaluationScenario,
        variant: Int,
        analysis: ContextAnalysisService,
        intentService: IntentClassificationService,
        promptService: IntentPromptSuggestionService,
        jsonService: AnalysisJSONService
    ) async -> CaseOutcome {
        let id = "\(scenario.id)_\(variant + 1)"
        let sourceContext = variantSourceContext(scenario, variant: variant)
        let report = await analysis.analyze(
            variantDocument(scenario, variant: variant),
            sourceContext: sourceContext,
            intentClassifier: intentService
        )
        let observedCategory = report.intent.category.rawValue
        let observedSubject = report.intent.identifiedSubject
        let categoryReady = observedCategory == scenario.expectedCategory
        let subjectReady = scenario.expectedSubject == nil || observedSubject == scenario.expectedSubject

        var reasons: [String] = []
        if !categoryReady { reasons.append("category_mismatch") }
        if !subjectReady { reasons.append("subject_mismatch") }

        var reportJSONReady = false
        do {
            let reportJSON = try jsonService.encode(report)
            if let data = reportJSON.data(using: .utf8),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["schemaVersion"] as? String == report.schemaVersion,
               object["intent"] is [String: Any],
               object["sourceContext"] is [String: Any],
               object["importantText"] is [[String: Any]],
               object["entities"] is [String: Any] {
                reportJSONReady = true
            }
        } catch {}
        if !reportJSONReady { reasons.append("report_json_invalid") }

        let concreteSubject = observedSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actionableJSONReady = reportJSONReady &&
            report.schemaVersion == "5.1" &&
            !report.sourceContext.websites.isEmpty &&
            !concreteSubject.isEmpty &&
            concreteSubject != "this topic" &&
            !report.importantText.isEmpty &&
            !report.cleanedSegments.isEmpty &&
            report.statistics.importantTextCount == report.importantText.count
        if !actionableJSONReady { reasons.append("report_not_actionable") }

        var qwenPayloadReady = false
        var promptContractReady = false
        var validatorContractReady = false
        do {
            let prepared = try promptService.preparePromptContext(for: report)
            if let data = prepared.payloadJSON.data(using: .utf8),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["subject"] as? String == prepared.subject,
               object["intent"] is [String: Any],
               object["sourceContext"] is [String: Any],
               object["importantText"] is [[String: Any]],
               object["entities"] is [String: Any] {
                qwenPayloadReady = true
            }

            let expectedActions = promptService.expectedActions(for: report.intent)
            let requestActions = prepared.requests.map(\.action)
            let promptActions = prepared.fallbackPrompts.map(\.action)
            let subjectKey = ContentPhrasePolicy.compactKey(prepared.subject)
            promptContractReady = !subjectKey.isEmpty &&
                requestActions == expectedActions &&
                promptActions == expectedActions &&
                Set(requestActions).count == requestActions.count &&
                prepared.requests.allSatisfy {
                    ContentPhrasePolicy.compactKey($0.subject) == subjectKey &&
                        ContentPhrasePolicy.compactKey($0.mainPrompt).contains(subjectKey)
                } &&
                prepared.fallbackPrompts.allSatisfy {
                    !$0.text.isEmpty && !$0.rationale.isEmpty &&
                        $0.searchOptions.count == 3 &&
                        Set($0.searchOptions.map { ContentPhrasePolicy.compactKey($0.query) }).count == 3
                }

            let choices = idealContractChoices(for: prepared.requests)
            validatorContractReady = promptService.validationRejections(
                for: choices,
                report: report
            ).isEmpty
        } catch {}
        if !qwenPayloadReady { reasons.append("qwen_payload_invalid") }
        if !promptContractReady { reasons.append("prompt_contract_invalid") }
        if !validatorContractReady { reasons.append("validator_contract_rejection") }

        return CaseOutcome(
            id: id,
            scenario: scenario,
            variant: variant,
            observedCategory: observedCategory,
            observedSubject: observedSubject,
            categoryReady: categoryReady,
            subjectReady: subjectReady,
            reportJSONReady: reportJSONReady,
            actionableJSONReady: actionableJSONReady,
            qwenPayloadReady: qwenPayloadReady,
            promptContractReady: promptContractReady,
            validatorContractReady: validatorContractReady,
            reasons: reasons
        )
    }

    private static func idealContractChoices(
        for requests: [PromptExpansionRequest]
    ) -> [SuggestedPromptAction: [SuggestedSearchOption]] {
        let suffixes = ["Alpha", "Beta", "Gamma"]
        return Dictionary(uniqueKeysWithValues: requests.map { request in
            let action = request.action.rawValue.replacingOccurrences(of: "_", with: " ")
            let options = suffixes.map { suffix in
                let title = "Candidate \(suffix)"
                return SuggestedSearchOption(
                    title: title,
                    query: "\(request.subject) \(title) \(action)"
                )
            }
            return (request.action, options)
        })
    }

    private static func variantDocument(
        _ scenario: WebsiteEvaluationScenario,
        variant: Int
    ) -> OCRDocument {
        var lines = scenario.ocrText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let heading = lines.first else { return OCRDocument(lines: []) }
        var body = Array(lines.dropFirst())
        if !body.isEmpty {
            let shift = variant % body.count
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
        lines = [heading] + body + noiseSets[variant % noiseSets.count]

        return OCRDocument(
            lines: lines.enumerated().map { index, line in
                let confidenceStep = Double((variant + index) % 8) * 0.01
                return OCRTextLine(
                    text: line,
                    confidence: 0.92 + confidenceStep,
                    boundingBox: NormalizedBoundingBox(
                        x: 0.04 + Double((variant + index) % 4) * 0.01,
                        y: max(0.05, 0.92 - Double(index) * 0.09),
                        width: index == 0 ? 0.72 : 0.64,
                        height: index == 0 ? 0.052 : 0.03
                    )
                )
            }
        )
    }

    private static func variantSourceContext(
        _ scenario: WebsiteEvaluationScenario,
        variant: Int
    ) -> ScreenSourceContext {
        let browsers = [
            ("Safari", "com.apple.Safari"),
            ("Chrome", "com.google.Chrome"),
            ("Microsoft Edge", "com.microsoft.edgemac")
        ]
        let browser = browsers[variant % browsers.count]
        let host = scenario.websites.first ?? ""
        let website: String
        switch variant % 4 {
        case 1: website = host.hasPrefix("www.") ? host : "www.\(host)"
        case 2: website = host.hasPrefix("m.") ? host : "m.\(host)"
        default: website = host
        }
        let baseTitle = scenario.windowTitle
        let title: String?
        switch variant % 5 {
        case 1: title = baseTitle.map { "\($0) - Safari" }
        case 2: title = baseTitle.map { "\($0) - Google Chrome" }
        case 3: title = baseTitle.map { "\($0) | \(host)" }
        default: title = baseTitle
        }
        return ScreenSourceContext(
            applicationName: browser.0,
            bundleIdentifier: browser.1,
            windowTitle: title,
            websites: website.isEmpty ? [] : [website]
        )
    }

    private static func makeIntentService() -> IntentClassificationService {
        IntentClassificationService(
            configuration: LocalModelConfiguration(
                baseURL: URL(string: "http://theia-evaluation.invalid")!,
                bertModel: "disabled",
                qwenModel: "disabled",
                ruleAcceptanceThreshold: 0.90,
                bertAcceptanceThreshold: 0.90,
                memoryLearningThreshold: 0.90
            ),
            localModels: DisabledLocalModels(),
            memoryStore: nil
        )
    }

    private static func loadScenarios(from url: URL) throws -> [WebsiteEvaluationScenario] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([WebsiteEvaluationScenario].self, from: data)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

private func rate(_ count: Int, _ total: Int) -> Double {
    guard total > 0 else { return 0 }
    return rounded(Double(count) / Double(total))
}

private func rounded(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

private struct EvaluationFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct DisabledLocalModels: LocalModelServing {
    func embeddings(model: String, inputs: [String]) async throws -> [[Double]] {
        throw LocalModelError.invalidResponse
    }

    func qwenClassification(model: String, prompt: String) async throws -> QwenClassificationOutput {
        throw LocalModelError.invalidClassification
    }
}

private struct DisabledPromptModels: PromptSuggestionModelServing {
    func expandPromptChoices(
        model: String,
        requests: [PromptExpansionRequest],
        analysisJSON: String
    ) async throws -> PromptExpansionModelResult {
        throw LocalModelError.invalidPromptExpansion
    }
}
