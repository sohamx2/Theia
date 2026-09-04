import Foundation

@main
struct InternetAccessRoutingRegression {
    static func main() async throws {
        let models = RoutingModels()
        let webSearch = RoutingWebSearch()
        let service = IntentPromptSuggestionService(
            modelName: "routing-test",
            localModels: models,
            webSearch: webSearch
        )
        let report = postCutoffReport(category: .shopping, subject: "Aurora Phone 2026")

        let requirement = service.webResearchRequirement(for: report)
        try require(requirement?.mode == .requiredForFreshness, "Post-cutoff shopping actions must use the freshness research route.")
        try require(requirement?.message.contains("Rule: post_cutoff_year") == true, "Consent must expose the exact freshness rule.")
        try require(requirement?.message.contains("Matched: Aurora Phone 2026 release guide") == true, "Consent must expose the matched source line.")

        let offline = try await service.generate(for: report, webResearchMode: .disabled)
        try require(models.callCount == 0, "The offline post-cutoff route must skip Qwen instead of wasting generation time.")
        try require(webSearch.queries.isEmpty, "The offline route must never perform a network request.")
        try require(offline.error?.contains("skipped Qwen") == true, "The offline fallback must explain why current answers were not generated.")
        try require(!offline.prompts.isEmpty, "The offline route must retain safe deterministic prompt fallbacks.")

        _ = try await service.generate(for: report, webResearchMode: .requiredForFreshness)
        try require(!webSearch.queries.isEmpty, "The allowed freshness route must perform live search.")
        try require(
            webSearch.queries.count == service.expectedActions(for: .shopping).count,
            "Each freshness-dependent action must receive one bounded search without a repair search."
        )
        try require(models.callCount > 0, "Qwen should run only after current web evidence has been prepared.")

        let localReport = postCutoffReport(category: .learning, subject: "Aurora Model 2026")
        try require(
            service.webResearchRequirement(for: localReport) == nil,
            "A future year on stable learning content must not request internet permission."
        )
        let callsBeforeLocal = models.callCount
        let searchesBeforeLocal = webSearch.queries.count
        _ = try await service.generate(for: localReport, webResearchMode: .disabled)
        try require(models.callCount == callsBeforeLocal + 1, "Stable post-cutoff learning content must still reach local Qwen.")
        try require(webSearch.queries.count == searchesBeforeLocal, "Stable learning content must not perform live search.")

        print("Internet access routing regression passed.")
    }

    private static func postCutoffReport(
        category: IntentCategory,
        subject: String
    ) -> ScreenContextReport {
        let freshness = TemporalFreshnessService().assess(
            text: ["\(subject) release guide"],
            category: category,
            analyzedAt: Date()
        )
        return ScreenContextReport(
            schemaVersion: "5.1",
            generatedAt: Date(),
            sourceContext: .empty,
            intent: IntentClassification(
                category: category,
                subcategory: nil,
                confidence: 0.98,
                identifiedSubject: subject,
                evidence: [subject]
            ),
            importantText: [
                SalientText(
                    text: subject,
                    category: .heading,
                    salienceScore: 0.99,
                    ocrConfidence: 0.99,
                    reasons: ["heading"],
                    boundingBox: NormalizedBoundingBox(x: 0.1, y: 0.8, width: 0.7, height: 0.1)
                )
            ],
            entities: ExtractedEntities(
                products: [],
                topics: [subject],
                places: [],
                dates: ["2026"],
                brandsAndSites: [],
                prices: [],
                sizes: []
            ),
            categories: [],
            cleanedSegments: ["\(subject) release guide"],
            statistics: AnalysisStatistics(
                ocrLineCount: 1,
                cleanedSegmentCount: 1,
                importantTextCount: 1,
                discardedLineCount: 0
            ),
            promptGeneration: nil,
            temporalFreshness: freshness
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RoutingRegressionError.failure(message) }
    }
}

private final class RoutingModels: PromptSuggestionModelServing {
    private(set) var callCount = 0

    func expandPromptChoices(
        model: String,
        requests: [PromptExpansionRequest],
        analysisJSON: String
    ) async throws -> PromptExpansionModelResult {
        callCount += 1
        throw RoutingRegressionError.expectedModelFailure
    }
}

private final class RoutingWebSearch: WebSearchProviding {
    private(set) var queries: [String] = []

    func search(query: String, limit: Int) async throws -> WebSearchResponse {
        queries.append(query)
        return WebSearchResponse(
            query: query,
            results: [
                WebSearchResult(
                    rank: 1,
                    title: "Current source",
                    snippet: "Current verified information for Aurora Model 2026.",
                    sourceHost: "example.com",
                    url: "https://example.com/aurora-2026-\(queries.count)"
                )
            ],
            startedAt: Date(),
            durationMilliseconds: 1
        )
    }
}

private enum RoutingRegressionError: Error {
    case failure(String)
    case expectedModelFailure
}
