import Foundation

struct PromptSummaryService {
    let modelName: String

    private let localModels: PromptSummaryModelServing
    private let webSearch: WebSearchProviding?

    init() {
        let configuration = LocalModelConfiguration.current
        modelName = configuration.qwenModel
        localModels = OllamaLocalModelClient(baseURL: configuration.baseURL)
        webSearch = DuckDuckGoWebSearchService()
    }

    init(
        modelName: String,
        localModels: PromptSummaryModelServing,
        webSearch: WebSearchProviding? = nil
    ) {
        self.modelName = modelName
        self.localModels = localModels
        self.webSearch = webSearch
    }

    func summarize(
        option: SuggestedSearchOption,
        for prompt: IntentPromptSuggestion,
        report: ScreenContextReport,
        useLiveSearch: Bool = false,
        resultLimit: Int = 8
    ) async throws -> PromptSummaryResult {
        let answerShape = prompt.action.answerShape(
            parentPrompt: prompt.text,
            option: option
        )
        let namedResultCount = answerShape == .namedList
            ? max(5, min(resultLimit, 10))
            : 0
        let sourceLimit = answerShape == .namedList
            ? max(1, min(resultLimit, 10))
            : max(1, min(resultLimit, 3))
        let subject = prompt.evidence.first(where: ContentPhrasePolicy.isViableEntity)
            ?? report.intent.identifiedSubject?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? option.title
        let visibleContext = report.importantText.sorted {
            let left = ContentPhrasePolicy.contextPrecedence(
                for: $0.text,
                category: $0.category
            )
            let right = ContentPhrasePolicy.contextPrecedence(
                for: $1.text,
                category: $1.category
            )
            if left != right { return left > right }
            return $0.salienceScore > $1.salienceScore
        }.prefix(10).map(\.text)

        let webResults: [WebSearchResult]
        if useLiveSearch, let webSearch {
            if let response = try? await webSearch.search(
                query: option.query,
                limit: sourceLimit
            ) {
                webResults = Array(response.results.prefix(sourceLimit))
            } else {
                webResults = []
            }
        } else {
            webResults = []
        }

        let localSummary = try await localModels.summarizePrompt(
            model: modelName,
            request: PromptSummaryRequest(
                subject: subject,
                parentPrompt: prompt.text,
                option: option,
                category: report.intent.category,
                visibleContext: visibleContext,
                webSearchResults: webResults,
                responseStyle: ResponseStyle.current,
                requestedNamedResultCount: namedResultCount,
                answerShape: answerShape
            )
        )
        let safeTitle = QwenVisibleOutputSanitizer.sanitize(localSummary.title)
        let safeSummary = QwenVisibleOutputSanitizer.sanitize(localSummary.summary)
        let safeKeyPoints = localSummary.keyPoints.compactMap { point -> String? in
            let cleaned = QwenVisibleOutputSanitizer.sanitize(point)
            return cleaned.isEmpty || QwenVisibleOutputSanitizer.containsMetaNarration(cleaned)
                ? nil
                : cleaned
        }
        let safeNamedRecommendations = localSummary.namedRecommendations.compactMap { name -> String? in
            let cleaned = QwenVisibleOutputSanitizer.sanitize(name)
            return cleaned.isEmpty || QwenVisibleOutputSanitizer.containsMetaNarration(cleaned)
                ? nil
                : cleaned
        }
        guard !safeTitle.isEmpty,
              !QwenVisibleOutputSanitizer.containsMetaNarration(safeTitle),
              !QwenVisibleOutputSanitizer.containsMetaNarration(safeSummary)
        else { throw LocalModelError.invalidSummary }
        let displayedWebResults: [WebSearchResult]
        if namedResultCount > 0, !safeNamedRecommendations.isEmpty {
            displayedWebResults = await linkedNamedResults(
                safeNamedRecommendations,
                subject: subject,
                useLiveSearch: useLiveSearch,
                limit: namedResultCount
            )
        } else {
            displayedWebResults = webResults
        }
        return PromptSummaryResult(
            title: safeTitle,
            summary: safeSummary,
            keyPoints: safeKeyPoints,
            model: localSummary.model,
            query: option.query,
            webResults: displayedWebResults,
            isLiveWebGrounded: useLiveSearch && !displayedWebResults.isEmpty,
            namedRecommendations: safeNamedRecommendations,
            answerShape: answerShape
        )
    }

    private func linkedNamedResults(
        _ names: [String],
        subject: String,
        useLiveSearch: Bool,
        limit: Int
    ) async -> [WebSearchResult] {
        let requestedNames = Array(names.prefix(max(1, min(limit, 10))))
        guard useLiveSearch, let webSearch else {
            return requestedNames.enumerated().compactMap { index, name in
                let query = "\(name) \(subject)"
                guard let url = SearchEngine.current.searchURL(for: query) else { return nil }
                return WebSearchResult(
                    rank: index + 1,
                    title: name,
                    snippet: "Open this individual recommendation in Safari.",
                    sourceHost: url.host ?? "search",
                    url: url.absoluteString
                )
            }
        }

        return await withTaskGroup(
            of: (Int, String, WebSearchResult?).self,
            returning: [WebSearchResult].self
        ) { group in
            for (index, name) in requestedNames.enumerated() {
                group.addTask {
                    let query = String("\"\(name)\" official website \(subject)".prefix(220))
                    let response = try? await webSearch.search(query: query, limit: 3)
                    let result = response?.results.max {
                        directResultScore($0, named: name) < directResultScore($1, named: name)
                    }
                    return (index, name, result)
                }
            }

            var resolved: [(Int, WebSearchResult)] = []
            for await (index, name, result) in group {
                if let result {
                    resolved.append((
                        index,
                        WebSearchResult(
                            rank: index + 1,
                            title: name,
                            snippet: result.snippet,
                            sourceHost: result.sourceHost,
                            url: result.url
                        )
                    ))
                } else if let url = SearchEngine.current.searchURL(for: "\(name) \(subject)") {
                    resolved.append((
                        index,
                        WebSearchResult(
                            rank: index + 1,
                            title: name,
                            snippet: "Open this individual recommendation in Safari.",
                            sourceHost: url.host ?? "search",
                            url: url.absoluteString
                        )
                    ))
                }
            }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func directResultScore(_ result: WebSearchResult, named name: String) -> Double {
        let nameTokens = Set(ContentPhrasePolicy.words(in: name).map(ContentPhrasePolicy.compactKey))
        let titleTokens = Set(ContentPhrasePolicy.words(in: result.title).map(ContentPhrasePolicy.compactKey))
        let shared = nameTokens.intersection(titleTokens).count
        var score = Double(shared) / Double(max(1, nameTokens.count))
        let lowerTitle = result.title.lowercased()
        if ["top 10", "best alternatives", "list of", "roundup"].contains(where: lowerTitle.contains) {
            score -= 0.8
        }
        let hostKey = ContentPhrasePolicy.compactKey(result.sourceHost)
        if nameTokens.contains(where: { $0.count >= 4 && hostKey.contains($0) }) {
            score += 0.4
        }
        return score
    }
}
