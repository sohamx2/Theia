import Foundation

private struct SubcategoryPromptTemplate {
    let action: SuggestedPromptAction
    let text: String
}

enum WebResearchMode: Equatable {
    case disabled
    case requiredForFreshness

    var allowsSearch: Bool { self != .disabled }
}

struct WebResearchRequirement: Equatable {
    let mode: WebResearchMode
    let title: String
    let message: String
}

struct IntentPromptSuggestionService {
    let modelName: String

    private let localModels: PromptSuggestionModelServing
    private let webSearch: WebSearchProviding?
    private let fieldAgentContextService = FieldAgentContextService()
    private let templateStore: PromptTemplateStore?

    init() {
        let configuration = LocalModelConfiguration.current
        modelName = configuration.qwenModel
        localModels = OllamaLocalModelClient(baseURL: configuration.baseURL)
        templateStore = PromptTemplateStore()
        webSearch = DuckDuckGoWebSearchService()
    }

    init(
        modelName: String,
        localModels: PromptSuggestionModelServing,
        webSearch: WebSearchProviding? = nil,
        templateStore: PromptTemplateStore? = nil
    ) {
        self.modelName = modelName
        self.localModels = localModels
        self.webSearch = webSearch
        self.templateStore = templateStore
    }

    func generate(
        for report: ScreenContextReport,
        webResearchMode: WebResearchMode = .disabled
    ) async throws -> IntentPromptGeneration {
        let preparedContext = try preparePromptContext(for: report)
        let subject = preparedContext.subject
        let agentContext = preparedContext.agentContext
        let actions = preparedContext.requests.map(\.action)
        let json = preparedContext.payloadJSON
        var prompts = preparedContext.fallbackPrompts

        var generationMessages: [String] = []
        var diagnostics: [PromptStageDiagnostic] = []
        var modelErrors: [String] = []
        let freshnessActions = Set(freshnessDependentActions(for: report))
        if webResearchMode == .disabled, !freshnessActions.isEmpty {
            return IntentPromptGeneration(
                model: modelName,
                prompts: prompts,
                error: "The visible content is newer than Qwen's knowledge window or requests current information. Live web search was not allowed, so Theia skipped Qwen's factual answer generation and kept offline prompt fallbacks.",
                diagnostics: [],
                agentContext: agentContext
            )
        }
        let baseExpansionRequests = preparedContext.requests
        var expansionRequests: [PromptExpansionRequest] = []
        for request in baseExpansionRequests {
            guard let webSearch,
                  webResearchMode.allowsSearch,
                  freshnessActions.contains(request.action)
            else {
                expansionRequests.append(request)
                continue
            }

            let searchStartedAt = Date()
            let query = webResearchQuery(for: request, mode: webResearchMode)
            do {
                let response = try await webSearch.search(query: query, limit: 3)
                expansionRequests.append(
                    PromptExpansionRequest(
                        action: request.action,
                        mainPrompt: request.mainPrompt,
                        subject: request.subject,
                        contextHint: request.contextHint,
                        agentContext: request.agentContext,
                        webSearchResults: compactWebSearchResults(response.results)
                    )
                )
                diagnostics.append(webResearchDiagnostic(response, action: request.action))
            } catch {
                expansionRequests.append(request)
                diagnostics.append(
                    webResearchFailureDiagnostic(
                        action: request.action,
                        query: query,
                        startedAt: searchStartedAt,
                        error: error
                    )
                )
            }
        }
        var expansionOptions: [SuggestedPromptAction: [SuggestedSearchOption]] = [:]

        // A single structured call amortizes the shared screen context and model
        // prompt across all visible actions. Invalid groups fall back to the three
        // deterministic template choices instead of invoking a second model pass.
        do {
            let expansionResult = try await localModels.expandPromptChoices(
                model: modelName,
                requests: Array(expansionRequests.prefix(4)),
                analysisJSON: json
            )
            for expansion in expansionResult.expansions {
                expansionOptions[expansion.action] = expansion.searchOptions
            }
            diagnostics.append(
                expansionResult.diagnostic.addingRejections(
                    expansionSemanticRejections(
                        actions: actions,
                        expansionOptions: expansionOptions,
                        category: report.intent.category,
                        subject: subject,
                        agentContext: agentContext
                    )
                )
            )
        } catch {
            if let failure = error as? PromptModelCallFailure {
                diagnostics.append(failure.diagnostic)
            }
            modelErrors.append(error.localizedDescription)
        }

        let unresolvedExpansions = unresolvedActions(
            actions,
            expansionOptions: expansionOptions,
            category: report.intent.category,
            subject: subject,
            agentContext: agentContext
        )
        prompts = applyingExpansions(
            expansionOptions,
            to: prompts,
            category: report.intent.category,
            subject: subject,
            agentContext: agentContext
        )
        if !unresolvedExpansions.isEmpty {
            var message = "Qwen did not provide three concrete researched choices for: \(unresolvedExpansions.map(\.rawValue).joined(separator: ", ")). Theia kept safe deterministic choices where available."
            if let error = modelErrors.last {
                message += " \(error)"
            }
            generationMessages.append(message)
        }

        return IntentPromptGeneration(
            model: modelName,
            prompts: prompts,
            error: generationMessages.isEmpty
                ? nil
                : generationMessages.joined(separator: " "),
            diagnostics: diagnostics,
            agentContext: agentContext
        )
    }

    /// Known categories use their deterministic cards immediately. Qwen is
    /// deferred until the user expands a path, keeping obvious tasks fast while
    /// preserving the richer model answer on demand.
    func generateFastTemplates(for report: ScreenContextReport) throws -> IntentPromptGeneration {
        let prepared = try preparePromptContext(for: report)
        return IntentPromptGeneration(
            model: "Theia Templates",
            prompts: prepared.fallbackPrompts,
            error: nil,
            diagnostics: [],
            agentContext: prepared.agentContext
        )
    }

    /// Last-resort UI if the vision model is unavailable for `Other`. This is a
    /// single open-ended Qwen request, never a category action preset.
    func generateUntemplatedOtherFallback(
        for report: ScreenContextReport
    ) -> IntentPromptGeneration {
        let subject = primarySubject(in: report)
        let agentContext = fieldAgentContextService.context(for: report, subject: subject)
        let request = "Inspect this screenshot, understand what I'm doing, provide useful information about what's happening on the screen, and give me predictive next-step actions."
        let prompt = IntentPromptSuggestion(
            text: request,
            action: .generalAssistance,
            confidence: report.intent.confidence,
            rationale: "Open-ended fallback for an undefined screen activity.",
            evidence: Array(report.importantText.prefix(4).map(\.text)),
            searchOptions: [
                SuggestedSearchOption(
                    title: "Understand This Screen",
                    query: "\(subject) explain visible screen context and result"
                ),
                SuggestedSearchOption(
                    title: "Useful Information",
                    query: "\(subject) useful information about current screen"
                ),
                SuggestedSearchOption(
                    title: "Predict Next Steps",
                    query: "\(subject) predict useful next steps"
                )
            ]
        )
        return IntentPromptGeneration(
            model: modelName,
            prompts: [prompt],
            error: "Qwen3-VL could not complete the screenshot response, so this open-ended Qwen path is available instead.",
            diagnostics: [],
            agentContext: agentContext
        )
    }

    func preparePromptContext(for report: ScreenContextReport) throws -> PreparedPromptContext {
        let subject = primarySubject(in: report)
        let agentContext = fieldAgentContextService.context(
            for: report,
            subject: subject
        )
        let templates = promptTemplates(for: report, subject: subject)
        let payload = PromptGenerationPayload(
            report: report,
            subject: subject,
            agentContext: agentContext
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let prompts = makeSuggestions(
            templates: templates,
            category: report.intent.category,
            subject: subject,
            confidence: report.intent.confidence,
            agentContext: agentContext
        )
        let requests = prompts.map {
            PromptExpansionRequest(
                action: $0.action,
                mainPrompt: modelQuestion(
                    for: $0.action,
                    subject: subject,
                    agentContext: agentContext,
                    visiblePrompt: $0.text
                ),
                subject: subject,
                contextHint: sourceContextHint(agentContext),
                agentContext: agentContext
            )
        }
        return PreparedPromptContext(
            subject: subject,
            agentContext: agentContext,
            payloadJSON: json,
            requests: requests,
            fallbackPrompts: prompts
        )
    }

    func validationRejections(
        for choices: [SuggestedPromptAction: [SuggestedSearchOption]],
        report: ScreenContextReport
    ) -> [PromptValidationRejection] {
        let subject = primarySubject(in: report)
        let agentContext = fieldAgentContextService.context(for: report, subject: subject)
        return expansionSemanticRejections(
            actions: expectedActions(for: report.intent),
            expansionOptions: choices,
            category: report.intent.category,
            subject: subject,
            agentContext: agentContext
        )
    }

    func webResearchRequirement(for report: ScreenContextReport) -> WebResearchRequirement? {
        guard let freshness = report.temporalFreshness,
              freshness.requiresLiveWebSearch,
              let trigger = freshness.trigger,
              !freshnessDependentActions(for: report).isEmpty
        else { return nil }

        return WebResearchRequirement(
            mode: .requiredForFreshness,
            title: "Allow Live Web Search?",
            message: "The requested next step needs current information outside Qwen's local knowledge window. Allow Theia to perform a live web search?\n\nRule: \(trigger.rule)\nSignal: \(trigger.signal)\nMatched: \(trigger.matchingLine)"
        )
    }

    private func webResearchQuery(
        for request: PromptExpansionRequest,
        mode: WebResearchMode
    ) -> String {
        let action = request.action.rawValue.replacingOccurrences(of: "_", with: " ")
        let freshness = mode == .requiredForFreshness ? " current verified information" : ""
        return String("\(request.mainPrompt) \(action)\(freshness)".prefix(240))
    }

    private func freshnessDependentActions(
        for report: ScreenContextReport
    ) -> [SuggestedPromptAction] {
        guard let freshness = report.temporalFreshness,
              freshness.requiresLiveWebSearch,
              let trigger = freshness.trigger
        else { return [] }

        return expectedActions(for: report.intent).filter { action in
            actionRequiresCurrentFacts(
                action,
                category: report.intent.category,
                triggerRule: trigger.rule
            )
        }
    }

    private func actionRequiresCurrentFacts(
        _ action: SuggestedPromptAction,
        category: IntentCategory,
        triggerRule: String
    ) -> Bool {
        if action == .learnPrerequisite || action == .learnNextTopic || action == .exploreApplications {
            return false
        }
        if triggerRule == "post_cutoff_year" {
            switch category {
            case .shopping, .travel, .news, .finance, .health, .realEstate,
                 .careers, .governmentLegal, .sportsFitness:
                return true
            case .learning, .coding, .productivity, .entertainment, .food, .social, .other:
                return false
            }
        }
        return true
    }

    private func compactWebSearchResults(
        _ results: [WebSearchResult]
    ) -> [WebSearchResult] {
        results.prefix(3).enumerated().map { index, result in
            WebSearchResult(
                rank: index + 1,
                title: String(result.title.prefix(100)),
                snippet: String(result.snippet.prefix(180)),
                sourceHost: result.sourceHost,
                url: result.url
            )
        }
    }

    private func webResearchDiagnostic(
        _ response: WebSearchResponse,
        action: SuggestedPromptAction
    ) -> PromptStageDiagnostic {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rawJSON = (try? encoder.encode(response.results))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sources = Array(Set(response.results.map(\.sourceHost))).sorted()
        return PromptStageDiagnostic(
            stage: .webResearch,
            requestedActions: [action],
            startedAt: response.startedAt,
            durationMilliseconds: response.durationMilliseconds,
            timeoutSeconds: 12,
            timedOut: false,
            succeeded: true,
            requestPrompt: response.query,
            rawResponse: rawJSON,
            decodedItems: [
                PromptDiagnosticItem(
                    index: 0,
                    action: action.rawValue,
                    target: nil,
                    rationale: "Bounded HTTPS search evidence supplied to Qwen.",
                    evidence: sources,
                    searchOptions: [],
                    rawJSON: rawJSON
                )
            ],
            rejections: [],
            errorType: nil,
            errorMessage: nil
        )
    }

    private func webResearchFailureDiagnostic(
        action: SuggestedPromptAction,
        query: String,
        startedAt: Date,
        error: Error
    ) -> PromptStageDiagnostic {
        let timedOut = (error as? URLError)?.code == .timedOut
        return PromptStageDiagnostic(
            stage: .webResearch,
            requestedActions: [action],
            startedAt: startedAt,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            timeoutSeconds: 12,
            timedOut: timedOut,
            succeeded: false,
            requestPrompt: query,
            rawResponse: nil,
            decodedItems: [],
            rejections: [],
            errorType: String(describing: type(of: error)),
            errorMessage: error.localizedDescription
        )
    }

    func expectedActions(for category: IntentCategory) -> [SuggestedPromptAction] {
        switch category {
        case .learning:
            return [.learnPrerequisite, .findLearningMaterial, .learnNextTopic, .exploreApplications]
        case .shopping:
            return [.compareAlternatives, .findComplementary, .findIndependentReviews, .generalAssistance]
        case .travel:
            return [.exploreDestination, .discoverRestaurants, .planItinerary, .generalAssistance]
        case .coding:
            return [.codingAssistance, .debugIssue, .testSolution, .findImplementationExamples]
        case .productivity:
            return [.productivityNextStep, .summarizeWork, .improveWorkflow, .generalAssistance]
        case .entertainment:
            return [.discoverMedia, .findIndependentReviews, .discoverSimilar, .generalAssistance]
        case .news:
            return [.generalAssistance, .findIndependentReviews, .discoverSimilar]
        case .finance, .health, .governmentLegal:
            return [.generalAssistance, .findIndependentReviews, .discoverSimilar]
        case .food:
            return [.discoverRestaurants, .findIndependentReviews, .generalAssistance]
        case .realEstate, .careers:
            return [.compareAlternatives, .findIndependentReviews, .generalAssistance]
        case .social, .sportsFitness:
            return [.discoverSimilar, .findIndependentReviews, .generalAssistance]
        case .other:
            return [.generalAssistance]
        }
    }

    func expectedActions(for intent: IntentClassification) -> [SuggestedPromptAction] {
        if let customCategoryID = intent.customCategoryID,
           let category = templateStore?.customCategory(id: customCategoryID) {
            return category.templates.map(\.action)
        }
        guard let subcategory = intent.subcategory else {
            return expectedActions(for: intent.category)
        }
        if let promptSet = templateStore?.builtInPromptSet(for: subcategory) {
            return promptSet.map(\.action)
        }
        return subcategoryPromptTemplates(
            for: subcategory,
            subject: "the current subject"
        ).map(\.action)
    }

    /// Exposed internally so the deterministic regression can verify that all
    /// taxonomy leaves have complete, subject-grounded templates.
    func templateSuggestions(
        for subcategory: IntentSubcategory,
        subject: String,
        confidence: Double = 1
    ) -> [IntentPromptSuggestion] {
        makeSuggestions(
            templates: subcategoryPromptTemplates(for: subcategory, subject: subject),
            category: subcategory.parent,
            subject: subject,
            confidence: confidence
        )
    }

    func builtInTemplateDefinitions() -> [BuiltInPromptTemplateDefinition] {
        IntentSubcategory.allCases.flatMap { subcategory in
            subcategoryPromptTemplates(for: subcategory, subject: "{subject}").map {
                BuiltInPromptTemplateDefinition(
                    subcategory: subcategory,
                    action: $0.action,
                    defaultText: $0.text
                )
            }
        }
    }

    private func concreteExpansionOptions(
        _ options: [SuggestedSearchOption],
        for action: SuggestedPromptAction,
        category: IntentCategory,
        subject: String,
        agentContext: FieldAgentContext? = nil
    ) -> [SuggestedSearchOption] {
        let genericTitles: Set<String> = [
            "application", "applications", "casestudies", "conceptoverview",
            "examples", "learnmore", "nexttopic", "overview", "recommendations",
            "usecase", "usecases"
        ]
        var seenTitles = Set<String>()
        var seenQueries = Set<String>()

        let accepted = options.compactMap { rawOption -> SuggestedSearchOption? in
            let option = canonicalizedOption(rawOption, for: action, subject: subject)
            let titleKey = ContentPhrasePolicy.compactKey(option.title)
            let queryKey = ContentPhrasePolicy.compactKey(option.query)
            let subjectKey = ContentPhrasePolicy.compactKey(subject)
            guard titleKey.count >= 4,
                  queryKey.count >= 4,
                  titleKey != subjectKey,
                  !genericTitles.contains(titleKey),
                  seenTitles.insert(titleKey).inserted,
                  seenQueries.insert(queryKey).inserted,
                  isUsefulExternalSearch(option, category: category)
            else { return nil }

            let titleTokens = Set(ContentPhrasePolicy.words(in: option.title).filter { $0.count > 2 })
            let queryTokens = Set(ContentPhrasePolicy.words(in: option.query).filter { $0.count > 2 })
            let subjectTokens = Set(ContentPhrasePolicy.words(in: subject).filter { $0.count > 2 })
            let novelTitleTokens = titleTokens.subtracting(subjectTokens)
            guard !titleTokens.isEmpty && !titleTokens.isDisjoint(with: queryTokens) else {
                return nil
            }
            guard !novelTitleTokens.isEmpty else { return nil }

            if action == .findComplementary {
                let genericComplementTerms: Set<String> = [
                    "addon", "addons", "accessories", "accessory", "compatible",
                    "essential", "product", "products"
                ]
                guard !novelTitleTokens.isSubset(of: genericComplementTerms) else {
                    return nil
                }
            }

            if action == .learnPrerequisite {
                let lowerTitle = option.title.lowercased()
                let genericPrerequisiteLabels = [
                    "prerequisite", "prerequisites", "foundations", "foundation",
                    "introduction", "overview", "guide", "tutorial"
                ]
                guard !titleKey.contains(subjectKey),
                      !genericPrerequisiteLabels.contains(where: lowerTitle.contains),
                      !option.query.contains(" | "),
                      !option.query.contains(" - "),
                      !subjectTokens.isDisjoint(with: queryTokens)
                else { return nil }

                if agentContext?.assumptions.contains(where: {
                    $0.localizedCaseInsensitiveContains("mathematical foundations") &&
                        $0.localizedCaseInsensitiveContains("already understood")
                }) == true {
                    let broadFoundations: Set<String> = [
                        "linearalgebra", "calculus", "differentialcalculus",
                        "integralcalculus", "probability", "probabilitytheory",
                        "basicstatistics", "mathematics"
                    ]
                    guard !broadFoundations.contains(titleKey) else { return nil }
                }
            }

            // Comparison titles must be direct answer names rather than generic
            // search strategies. Model numbers are allowed when the verification
            // query ties them to either the subject or that named answer.
            if action == .compareAlternatives {
                guard !titleKey.contains(subjectKey) else { return nil }
                let lowerTitle = option.title.lowercased()
                let genericComparisonLabels = [
                    "alternative", "comparison", "price tier", "same subtype",
                    "same use case", "similar specifications"
                ]
                guard !genericComparisonLabels.contains(where: lowerTitle.contains) else {
                    return nil
                }

                guard !subjectTokens.isDisjoint(with: queryTokens) else { return nil }

                // Model numbers are legitimate direct-answer names. Reject only
                // numbers introduced in the query that appear in neither the
                // grounded subject nor the answer title.
                let allowedNumbers = numericTokens(in: subject + " " + option.title)
                let queryNumbers = numericTokens(in: option.query)
                guard queryNumbers.isSubset(of: allowedNumbers) else { return nil }
            }
            return option
        }
        return Array(accepted.prefix(3))
    }

    private func canonicalizedOption(
        _ option: SuggestedSearchOption,
        for action: SuggestedPromptAction,
        subject: String
    ) -> SuggestedSearchOption {
        guard action == .compareAlternatives else { return option }
        let separators = #"\s+(?:vs\.?|versus|compared\s+to)\s+"#
        guard let regex = try? NSRegularExpression(
            pattern: separators,
            options: [.caseInsensitive]
        ) else { return option }
        let range = NSRange(option.title.startIndex..<option.title.endIndex, in: option.title)
        guard let match = regex.firstMatch(in: option.title, range: range),
              let separatorRange = Range(match.range, in: option.title)
        else { return option }
        let parts = [
            String(option.title[..<separatorRange.lowerBound]),
            String(option.title[separatorRange.upperBound...])
        ]

        let subjectTokens = Set(ContentPhrasePolicy.words(in: subject))
        let rankedParts = parts.map { part -> (String, Int) in
            let tokens = Set(ContentPhrasePolicy.words(in: part))
            return (part, tokens.intersection(subjectTokens).count)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.count < rhs.0.count
        }
        guard let answer = rankedParts.first?.0.trimmingCharacters(in: .whitespacesAndNewlines),
              answer.count >= 3
        else { return option }
        return SuggestedSearchOption(title: answer, query: option.query)
    }

    private func unresolvedActions(
        _ actions: [SuggestedPromptAction],
        expansionOptions: [SuggestedPromptAction: [SuggestedSearchOption]],
        category: IntentCategory,
        subject: String,
        agentContext: FieldAgentContext? = nil
    ) -> [SuggestedPromptAction] {
        actions.filter { action in
            concreteExpansionOptions(
                expansionOptions[action] ?? [],
                for: action,
                category: category,
                subject: subject,
                agentContext: agentContext
            ).count != 3
        }
    }

    private func expansionSemanticRejections(
        actions: [SuggestedPromptAction],
        expansionOptions: [SuggestedPromptAction: [SuggestedSearchOption]],
        category: IntentCategory,
        subject: String,
        agentContext: FieldAgentContext? = nil
    ) -> [PromptValidationRejection] {
        actions.compactMap { action in
            let rawOptions = expansionOptions[action] ?? []
            let accepted = concreteExpansionOptions(
                rawOptions,
                for: action,
                category: category,
                subject: subject,
                agentContext: agentContext
            )
            guard accepted.count != 3 else { return nil }
            let value = rawOptions.map { "\($0.title) => \($0.query)" }
                .joined(separator: " | ")
            return PromptValidationRejection(
                action: action.rawValue,
                field: "choices",
                value: value.isEmpty ? nil : value,
                reason: "Only \(accepted.count) of \(rawOptions.count) choices passed semantic specificity, uniqueness, and external-search validation; exactly 3 are required."
            )
        }
    }

    private func applyingExpansions(
        _ expansions: [SuggestedPromptAction: [SuggestedSearchOption]],
        to prompts: [IntentPromptSuggestion],
        category: IntentCategory,
        subject: String,
        agentContext: FieldAgentContext? = nil
    ) -> [IntentPromptSuggestion] {
        prompts.map { prompt in
            let choices = concreteExpansionOptions(
                expansions[prompt.action] ?? [],
                for: prompt.action,
                category: category,
                subject: subject,
                agentContext: agentContext
            )
            guard choices.count == 3 else { return prompt }
            return IntentPromptSuggestion(
                text: prompt.text,
                action: prompt.action,
                confidence: prompt.confidence,
                rationale: prompt.rationale,
                evidence: prompt.evidence,
                searchOptions: choices
            )
        }
    }

    private func numericTokens(in value: String) -> Set<String> {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let regex = try? NSRegularExpression(pattern: #"\b\d+(?:[.,]\d+)?\b"#) else {
            return []
        }
        return Set(regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return value[swiftRange].replacingOccurrences(of: ",", with: "")
        })
    }

    private func makeSuggestions(
        templates: [SubcategoryPromptTemplate],
        category: IntentCategory,
        subject: String,
        confidence: Double,
        agentContext: FieldAgentContext? = nil
    ) -> [IntentPromptSuggestion] {
        return templates.map { template in
            return IntentPromptSuggestion(
                text: template.text,
                action: template.action,
                confidence: min(1, max(0, confidence)),
                rationale: fallbackRationale(for: template.action),
                evidence: [subject],
                searchOptions: fallbackSearchOptions(
                    for: template.action,
                    subject: subject,
                    category: category,
                    agentContext: agentContext
                )
            )
        }
    }

    private func modelQuestion(
        for action: SuggestedPromptAction,
        subject: String,
        agentContext: FieldAgentContext,
        visiblePrompt: String
    ) -> String {
        guard action == .learnPrerequisite else {
            return visiblePrompt
        }

        let assumptions = agentContext.assumptions.joined(separator: " ")
        let nearby = agentContext.nearbyConcepts.isEmpty
            ? "No nearby concepts were reliably extracted."
            : "Nearby and previously visible concepts: \(agentContext.nearbyConcepts.joined(separator: ", "))."
        return "The user is \(agentContext.userStage.lowercased()) Work as a \(agentContext.specialistRole). \(assumptions) What are the three most important prerequisite topics within \(agentContext.field) that should be understood immediately before learning \(subject)? \(nearby) Return only specific topic names, not broad entry-level foundations, articles, books, websites, tutorials, or restatements of \(subject)."
    }

    private func sourceContextHint(_ agentContext: FieldAgentContext) -> String {
        "The visible source is a \(agentContext.sourceKind). Adopt the role \(agentContext.specialistRole), stay inside \(agentContext.field), and respect this user stage: \(agentContext.userStage) \(ExperienceFocus.current.promptHint)"
    }

    private func promptTemplates(
        for report: ScreenContextReport,
        subject: String
    ) -> [SubcategoryPromptTemplate] {
        let intent = report.intent
        if let customCategoryID = intent.customCategoryID,
           let category = templateStore?.customCategory(id: customCategoryID) {
            return category.templates.map {
                SubcategoryPromptTemplate(
                    action: $0.action,
                    text: resolvedTemplate($0.text, subject: subject)
                )
            }
        }
        if isBinaryTreeTraversalProblem(report) {
            return [
                SubcategoryPromptTemplate(
                    action: .codingAssistance,
                    text: "How do binary trees organize parent, child, and subtree relationships?"
                ),
                SubcategoryPromptTemplate(
                    action: .findLearningMaterial,
                    text: "How does preorder traversal visit a binary tree?"
                ),
                SubcategoryPromptTemplate(
                    action: .generalAssistance,
                    text: "How does inorder traversal visit a binary tree?"
                ),
                SubcategoryPromptTemplate(
                    action: .findImplementationExamples,
                    text: "How do preorder and inorder traversals reconstruct \(subject)?"
                )
            ]
        }
        if let subcategory = intent.subcategory {
            if let promptSet = templateStore?.builtInPromptSet(for: subcategory) {
                return promptSet.map {
                    SubcategoryPromptTemplate(
                        action: $0.action,
                        text: resolvedTemplate($0.text, subject: subject)
                    )
                }
            }
            return subcategoryPromptTemplates(for: subcategory, subject: subject).map { template in
                guard let override = templateStore?.overrideText(
                    for: subcategory,
                    action: template.action
                ) else { return template }
                return SubcategoryPromptTemplate(
                    action: template.action,
                    text: resolvedTemplate(override, subject: subject)
                )
            }
        }
        return expectedActions(for: intent.category).map {
            SubcategoryPromptTemplate(
                action: $0,
                text: templateText(for: $0, subject: subject, category: intent.category)
            )
        }
    }

    private func isBinaryTreeTraversalProblem(_ report: ScreenContextReport) -> Bool {
        guard report.intent.category == .coding || report.intent.category == .learning else {
            return false
        }
        let content = (
            report.cleanedSegments +
            report.importantText.map(\.text) +
            [report.intent.identifiedSubject, report.sourceContext.windowTitle].compactMap { $0 }
        ).joined(separator: " ").lowercased()
        return content.contains("binary tree") &&
            content.contains("preorder") &&
            content.contains("inorder")
    }

    private func resolvedTemplate(_ template: String, subject: String) -> String {
        template.replacingOccurrences(
            of: "{subject}",
            with: subject,
            options: [.caseInsensitive]
        )
    }

    private func subcategoryPromptTemplates(
        for subcategory: IntentSubcategory,
        subject: String
    ) -> [SubcategoryPromptTemplate] {
        func prompt(
            _ action: SuggestedPromptAction,
            _ text: String
        ) -> SubcategoryPromptTemplate {
            SubcategoryPromptTemplate(action: action, text: text)
        }

        switch subcategory {
        case .clothingFashion:
            return [
                prompt(.compareAlternatives, "Which comparable styles or brands to \(subject) fit the same occasion and budget?"),
                prompt(.findComplementary, "Which shoes, layers, or accessories pair well with \(subject)?"),
                prompt(.findIndependentReviews, "Which sizing, fabric-quality, and long-term wear reviews for \(subject) should you check?"),
                prompt(.generalAssistance, "Which fit, material, care, and return-policy details matter before choosing \(subject)?")
            ]
        case .electronicsAppliances:
            return [
                prompt(.compareAlternatives, "Which alternatives to \(subject) are you looking for?"),
                prompt(.findComplementary, "Which compatible accessories, services, or add-ons are useful with \(subject)?"),
                prompt(.findIndependentReviews, "Which reliability, performance, and long-term ownership reviews for \(subject) should you examine?"),
                prompt(.generalAssistance, "Which specifications, compatibility, energy-use, and warranty details matter for \(subject)?")
            ]
        case .vehiclesParts:
            return [
                prompt(.compareAlternatives, "Which vehicles or parts directly comparable to \(subject) should you evaluate?"),
                prompt(.findComplementary, "Which compatible parts, safety gear, or accessories are useful with \(subject)?"),
                prompt(.findIndependentReviews, "Which reliability, safety, performance, and ownership reviews for \(subject) should you examine?"),
                prompt(.generalAssistance, "Which fitment, running-cost, maintenance, and warranty details matter for \(subject)?")
            ]

        case .flightsTransport:
            return [
                prompt(.findFlights, "Which routes, airports, or fare strategies are best for \(subject)?"),
                prompt(.compareAlternatives, "Which flight or ground-transport options for \(subject) should you compare?"),
                prompt(.planItinerary, "How should transfers, timing, and connections be organized for \(subject)?"),
                prompt(.generalAssistance, "Which baggage, visa, delay, and booking constraints matter for \(subject)?")
            ]
        case .hotelsStays:
            return [
                prompt(.compareAlternatives, "Which stays comparable to \(subject) offer the best location, amenities, and value?"),
                prompt(.findIndependentReviews, "Which recent guest reviews and recurring issues for \(subject) should you check?"),
                prompt(.exploreDestination, "Which activities and notable sights are best near \(subject)?"),
                prompt(.discoverRestaurants, "Which of the best restaurants are near \(subject)?")
            ]
        case .destinationsActivities:
            return [
                prompt(.exploreDestination, "Which landmarks, neighborhoods, and local experiences should you explore for \(subject)?"),
                prompt(.planItinerary, "Which practical day-by-day itineraries work best for \(subject)?"),
                prompt(.discoverRestaurants, "Which local dishes, markets, and dining areas should you try during \(subject)?"),
                prompt(.generalAssistance, "Which timing, transport, safety, and booking details should you plan for \(subject)?")
            ]

        case .coursesTutorials:
            return [
                prompt(.learnPrerequisite, "Would you like to learn about prerequisites to \(subject)?"),
                prompt(.findLearningMaterial, "Which courses, tutorials, or practice resources best explain \(subject)?"),
                prompt(.learnNextTopic, "Which topic should you learn after \(subject)?"),
                prompt(.exploreApplications, "Which projects or real-world applications help reinforce \(subject)?")
            ]
        case .academicResearch:
            return [
                prompt(.learnPrerequisite, "Would you like to learn about prerequisites to \(subject)?"),
                prompt(.findLearningMaterial, "Which surveys, seminal papers, or replication resources best contextualize \(subject)?"),
                prompt(.exploreApplications, "Which experiments, datasets, or applied studies demonstrate \(subject)?"),
                prompt(.generalAssistance, "Which assumptions, limitations, and unresolved questions should you investigate about \(subject)?")
            ]
        case .referenceMaterials:
            return [
                prompt(.learnPrerequisite, "Would you like to learn about prerequisites to \(subject)?"),
                prompt(.findLearningMaterial, "Which explanations, visualizations, or worked examples would help you understand \(subject)?"),
                prompt(.learnNextTopic, "Which topic should you study after \(subject)?"),
                prompt(.exploreApplications, "Which real-world applications demonstrate \(subject)?")
            ]

        case .programmingDebugging:
            return [
                prompt(.codingAssistance, "Which concepts or implementation approaches would clarify \(subject)?"),
                prompt(.debugIssue, "Which likely causes and debugging steps should you try for \(subject)?"),
                prompt(.testSolution, "Which tests and edge cases would verify a solution for \(subject)?"),
                prompt(.findImplementationExamples, "Which minimal examples or official references demonstrate \(subject)?")
            ]
        case .APIsTechnicalDocs:
            return [
                prompt(.codingAssistance, "Which API concepts, parameters, or lifecycle details should you understand for \(subject)?"),
                prompt(.findImplementationExamples, "Which official documentation and implementation examples best demonstrate \(subject)?"),
                prompt(.testSolution, "Which requests, responses, errors, and edge cases should you test for \(subject)?"),
                prompt(.compareAlternatives, "Which APIs or technical approaches comparable to \(subject) should you evaluate?")
            ]
        case .toolsPackages:
            return [
                prompt(.compareAlternatives, "Which tools or packages comparable to \(subject) should you evaluate?"),
                prompt(.findImplementationExamples, "Which setup guides and production examples best demonstrate \(subject)?"),
                prompt(.testSolution, "Which compatibility, performance, and upgrade tests should you run for \(subject)?"),
                prompt(.generalAssistance, "Which maintenance, licensing, security, and ecosystem tradeoffs matter for \(subject)?")
            ]

        case .projectManagement:
            return [
                prompt(.productivityNextStep, "Which concrete milestone, owner, or next action should follow \(subject)?"),
                prompt(.summarizeWork, "Which decisions, blockers, and commitments should be captured from \(subject)?"),
                prompt(.improveWorkflow, "Which planning or tracking workflow would make \(subject) more effective?"),
                prompt(.generalAssistance, "Which risks, dependencies, and success measures should be clarified for \(subject)?")
            ]
        case .documentsCollaboration:
            return [
                prompt(.summarizeWork, "Which key points, decisions, and open questions should be summarized from \(subject)?"),
                prompt(.improveWorkflow, "Which review, versioning, and collaboration workflow would improve \(subject)?"),
                prompt(.productivityNextStep, "Which concrete revision or follow-up action should come next for \(subject)?"),
                prompt(.generalAssistance, "Which evidence, structure, or stakeholder input is still missing from \(subject)?")
            ]
        case .personalOrganization:
            return [
                prompt(.productivityNextStep, "Which prioritized next action should you take for \(subject)?"),
                prompt(.improveWorkflow, "Which routine, tool, or organization method would simplify \(subject)?"),
                prompt(.summarizeWork, "Which commitments, deadlines, and dependencies should be extracted from \(subject)?"),
                prompt(.generalAssistance, "Which tasks related to \(subject) can be scheduled, delegated, or removed?")
            ]

        case .music:
            return [
                prompt(.discoverMedia, "Which artists, albums, or performances related to \(subject) should you hear next?"),
                prompt(.discoverSimilar, "Which music with a similar sound, era, or influence to \(subject) should you explore?"),
                prompt(.findIndependentReviews, "Which critical reviews or listener perspectives best explain \(subject)?"),
                prompt(.generalAssistance, "Which background, themes, production details, or influences deepen an understanding of \(subject)?")
            ]
        case .moviesTelevision:
            return [
                prompt(.discoverMedia, "Which films, series, or episodes related to \(subject) should you watch next?"),
                prompt(.discoverSimilar, "Which titles with similar themes, style, or creators to \(subject) should you explore?"),
                prompt(.findIndependentReviews, "Which critic and audience perspectives best contextualize \(subject)?"),
                prompt(.generalAssistance, "Which plot context, themes, creators, or production details deepen an understanding of \(subject)?")
            ]
        case .gamesBooks:
            return [
                prompt(.discoverMedia, "Which games or books related to \(subject) should you try next?"),
                prompt(.discoverSimilar, "Which works with similar mechanics, themes, or style to \(subject) should you explore?"),
                prompt(.findIndependentReviews, "Which independent reviews and community perspectives best assess \(subject)?"),
                prompt(.generalAssistance, "Which mechanics, themes, difficulty, or reading context should you understand about \(subject)?")
            ]

        case .generalNews:
            return [
                prompt(.summarizeWork, "Which verified developments and timeline should be summarized for \(subject)?"),
                prompt(.findIndependentReviews, "Which independent reports and primary sources should be checked for \(subject)?"),
                prompt(.discoverSimilar, "Which related stories or earlier events provide context for \(subject)?"),
                prompt(.generalAssistance, "Which claims, affected groups, and unresolved facts should you investigate about \(subject)?")
            ]
        case .businessTechnology:
            return [
                prompt(.summarizeWork, "Which verified announcements, metrics, and timeline should be summarized for \(subject)?"),
                prompt(.findIndependentReviews, "Which independent technical or market analyses should be checked for \(subject)?"),
                prompt(.discoverSimilar, "Which companies, technologies, or prior events are most relevant to \(subject)?"),
                prompt(.generalAssistance, "Which competitive, financial, technical, and user impacts should you investigate for \(subject)?")
            ]
        case .politicsWorldEvents:
            return [
                prompt(.summarizeWork, "Which verified events, decisions, and timeline should be summarized for \(subject)?"),
                prompt(.findIndependentReviews, "Which primary sources and independent international coverage should be checked for \(subject)?"),
                prompt(.discoverSimilar, "Which historical events, policies, or regional developments contextualize \(subject)?"),
                prompt(.generalAssistance, "Which stakeholders, disputed claims, and likely consequences should you investigate for \(subject)?")
            ]

        case .bankingPayments:
            return [
                prompt(.compareAlternatives, "Which banking or payment options comparable to \(subject) should you compare?"),
                prompt(.findIndependentReviews, "Which reliability, service, security, and complaint evidence should you check for \(subject)?"),
                prompt(.generalAssistance, "Which fees, limits, protections, eligibility, and settlement details matter for \(subject)?"),
                prompt(.discoverSimilar, "Which related accounts, payment methods, or services could complement \(subject)?")
            ]
        case .investingMarkets:
            return [
                prompt(.summarizeWork, "Which thesis, catalysts, valuation signals, and risks should be summarized for \(subject)?"),
                prompt(.findIndependentReviews, "Which filings, data sources, and independent analyses should be checked for \(subject)?"),
                prompt(.generalAssistance, "Which downside scenarios, assumptions, fees, and time-horizon factors matter for \(subject)?"),
                prompt(.discoverSimilar, "Which comparable assets, sectors, or market indicators provide context for \(subject)?")
            ]
        case .personalFinanceInsurance:
            return [
                prompt(.compareAlternatives, "Which financial or insurance options comparable to \(subject) should you compare?"),
                prompt(.generalAssistance, "Which costs, exclusions, tax effects, risks, and eligibility rules matter for \(subject)?"),
                prompt(.findIndependentReviews, "Which regulator guidance and independent consumer evidence should you check for \(subject)?"),
                prompt(.productivityNextStep, "Which documents, calculations, and decision steps should come next for \(subject)?")
            ]

        case .generalHealth:
            return [
                prompt(.generalAssistance, "Which symptoms, risk factors, and evidence-based care options should you understand about \(subject)?"),
                prompt(.findLearningMaterial, "Which trusted clinical guides or patient resources best explain \(subject)?"),
                prompt(.findIndependentReviews, "Which guideline recommendations and quality-of-evidence findings should you check for \(subject)?"),
                prompt(.productivityNextStep, "Which questions and observations should you prepare for a clinician about \(subject)?")
            ]
        case .fitnessNutrition:
            return [
                prompt(.generalAssistance, "Which evidence-based training or nutrition principles apply to \(subject)?"),
                prompt(.compareAlternatives, "Which training or nutrition approaches comparable to \(subject) should you evaluate?"),
                prompt(.findLearningMaterial, "Which reputable guides and demonstrations best explain \(subject)?"),
                prompt(.productivityNextStep, "Which safe, measurable progression plan should you build for \(subject)?")
            ]
        case .medicalResearchCare:
            return [
                prompt(.findLearningMaterial, "Which clinical guidelines, systematic reviews, or trials best explain \(subject)?"),
                prompt(.findIndependentReviews, "Which evidence-quality, safety, and outcome assessments should you check for \(subject)?"),
                prompt(.summarizeWork, "Which findings, limitations, and patient-relevant outcomes should be summarized for \(subject)?"),
                prompt(.generalAssistance, "Which alternatives, contraindications, and clinician questions matter for \(subject)?")
            ]

        case .recipesCooking:
            return [
                prompt(.generalAssistance, "Which ingredients, techniques, temperatures, and timing are essential for \(subject)?"),
                prompt(.discoverSimilar, "Which related recipes or regional variations of \(subject) should you try?"),
                prompt(.findComplementary, "Which sides, sauces, drinks, or garnishes pair well with \(subject)?"),
                prompt(.findLearningMaterial, "Which demonstrations or troubleshooting guides would help you make \(subject)?")
            ]
        case .restaurantsReviews:
            return [
                prompt(.discoverRestaurants, "Which restaurants comparable to \(subject) fit the same cuisine, location, and budget?"),
                prompt(.findIndependentReviews, "Which recent diner reviews and recurring quality signals should you check for \(subject)?"),
                prompt(.compareAlternatives, "Which dining alternatives to \(subject) should you compare?"),
                prompt(.generalAssistance, "Which signature dishes, reservation, dietary, and total-cost details matter for \(subject)?")
            ]
        case .groceryDelivery:
            return [
                prompt(.compareAlternatives, "Which grocery or delivery options comparable to \(subject) offer better value and availability?"),
                prompt(.findIndependentReviews, "Which freshness, substitution, delivery, and support reviews should you check for \(subject)?"),
                prompt(.findComplementary, "Which ingredients or household items commonly pair with \(subject)?"),
                prompt(.generalAssistance, "Which unit-price, nutrition, storage, fee, and return details matter for \(subject)?")
            ]

        case .buyingSelling:
            return [
                prompt(.compareAlternatives, "Which properties or sale strategies comparable to \(subject) should you evaluate?"),
                prompt(.findIndependentReviews, "Which market data, inspection evidence, and neighborhood sources should you check for \(subject)?"),
                prompt(.generalAssistance, "Which financing, legal, condition, and total-cost risks matter for \(subject)?"),
                prompt(.productivityNextStep, "Which due-diligence documents and negotiation steps should come next for \(subject)?")
            ]
        case .rentals:
            return [
                prompt(.compareAlternatives, "Which rentals comparable to \(subject) should you evaluate for location, condition, and total cost?"),
                prompt(.findIndependentReviews, "Which landlord, building, neighborhood, and management evidence should you check for \(subject)?"),
                prompt(.generalAssistance, "Which lease terms, deposits, utilities, commute, and tenant protections matter for \(subject)?"),
                prompt(.productivityNextStep, "Which viewing questions, documents, and application steps should come next for \(subject)?")
            ]
        case .homeImprovement:
            return [
                prompt(.compareAlternatives, "Which materials, designs, or contractors comparable to \(subject) should you evaluate?"),
                prompt(.findImplementationExamples, "Which plans, demonstrations, or code-compliant examples best explain \(subject)?"),
                prompt(.findIndependentReviews, "Which durability, safety, and contractor-quality evidence should you check for \(subject)?"),
                prompt(.generalAssistance, "Which budget, permit, sequence, maintenance, and safety details matter for \(subject)?")
            ]

        case .jobSearching:
            return [
                prompt(.compareAlternatives, "Which roles or employers comparable to \(subject) should you evaluate?"),
                prompt(.productivityNextStep, "Which tailored application, networking, or follow-up step should come next for \(subject)?"),
                prompt(.findIndependentReviews, "Which salary, culture, stability, and employee evidence should you check for \(subject)?"),
                prompt(.generalAssistance, "Which requirements, transferable skills, and application risks matter for \(subject)?")
            ]
        case .resumesInterviews:
            return [
                prompt(.productivityNextStep, "Which concrete resume revision or interview-preparation step should come next for \(subject)?"),
                prompt(.improveWorkflow, "Which review and practice workflow would improve \(subject)?"),
                prompt(.findLearningMaterial, "Which examples, question banks, or scoring rubrics best support \(subject)?"),
                prompt(.generalAssistance, "Which evidence, achievements, gaps, and likely questions should be addressed for \(subject)?")
            ]
        case .professionalDevelopment:
            return [
                prompt(.learnNextTopic, "Which skill or responsibility should you develop after \(subject)?"),
                prompt(.findLearningMaterial, "Which courses, mentors, communities, or projects best support \(subject)?"),
                prompt(.compareAlternatives, "Which certifications or development paths comparable to \(subject) should you evaluate?"),
                prompt(.productivityNextStep, "Which measurable development milestone should come next for \(subject)?")
            ]

        case .discussionForums:
            return [
                prompt(.summarizeWork, "Which consensus, disagreements, and evidence should be summarized from \(subject)?"),
                prompt(.discoverSimilar, "Which related discussions or expert communities provide context for \(subject)?"),
                prompt(.findIndependentReviews, "Which claims in \(subject) should be cross-checked against independent sources?"),
                prompt(.generalAssistance, "Which unanswered questions and practical takeaways should you investigate from \(subject)?")
            ]
        case .socialNetworks:
            return [
                prompt(.discoverSimilar, "Which accounts, communities, or conversations related to \(subject) are worth exploring?"),
                prompt(.improveWorkflow, "Which posting, filtering, privacy, or engagement workflow would improve \(subject)?"),
                prompt(.findIndependentReviews, "Which claims, trends, or recommendations around \(subject) should be independently verified?"),
                prompt(.generalAssistance, "Which context, safety, privacy, and credibility signals matter for \(subject)?")
            ]
        case .creatorCommunities:
            return [
                prompt(.discoverSimilar, "Which creators, communities, or collaborations related to \(subject) should you explore?"),
                prompt(.improveWorkflow, "Which publishing, feedback, or audience workflow would improve \(subject)?"),
                prompt(.findIndependentReviews, "Which platform, monetization, and community experiences should you check for \(subject)?"),
                prompt(.generalAssistance, "Which audience, rights, moderation, and sustainability tradeoffs matter for \(subject)?")
            ]

        case .governmentServices:
            return [
                prompt(.productivityNextStep, "Which eligibility check, document, or application step should come next for \(subject)?"),
                prompt(.findImplementationExamples, "Which official instructions and completed examples best explain \(subject)?"),
                prompt(.findIndependentReviews, "Which official notices and reputable public guidance should you verify for \(subject)?"),
                prompt(.generalAssistance, "Which deadlines, fees, identity requirements, and appeal paths matter for \(subject)?")
            ]
        case .legalInformation:
            return [
                prompt(.findLearningMaterial, "Which statutes, official guidance, or plain-language resources best explain \(subject)?"),
                prompt(.summarizeWork, "Which duties, rights, exceptions, and deadlines should be summarized for \(subject)?"),
                prompt(.findIndependentReviews, "Which authoritative interpretations and jurisdiction-specific sources should you check for \(subject)?"),
                prompt(.generalAssistance, "Which facts, jurisdiction, documents, and professional-advice questions matter for \(subject)?")
            ]
        case .formsRegulations:
            return [
                prompt(.productivityNextStep, "Which field, attachment, submission, or compliance step should come next for \(subject)?"),
                prompt(.findImplementationExamples, "Which official instructions and valid examples best demonstrate \(subject)?"),
                prompt(.summarizeWork, "Which requirements, exceptions, deadlines, and penalties should be summarized for \(subject)?"),
                prompt(.generalAssistance, "Which jurisdiction, version, evidence, and filing details must be verified for \(subject)?")
            ]

        case .sportsNewsTeams:
            return [
                prompt(.summarizeWork, "Which results, standings, roster changes, and context should be summarized for \(subject)?"),
                prompt(.discoverSimilar, "Which related teams, players, competitions, or upcoming events matter to \(subject)?"),
                prompt(.findIndependentReviews, "Which reliable reports and statistical analyses should you check for \(subject)?"),
                prompt(.generalAssistance, "Which tactics, form, injuries, and schedule factors should you investigate for \(subject)?")
            ]
        case .trainingWorkouts:
            return [
                prompt(.generalAssistance, "Which technique, load, recovery, and safety principles apply to \(subject)?"),
                prompt(.findLearningMaterial, "Which reputable demonstrations and coaching guides best explain \(subject)?"),
                prompt(.productivityNextStep, "Which measurable progression and recovery plan should come next for \(subject)?"),
                prompt(.compareAlternatives, "Which training approaches comparable to \(subject) should you evaluate?")
            ]
        case .equipmentEvents:
            return [
                prompt(.compareAlternatives, "Which equipment or events comparable to \(subject) should you evaluate?"),
                prompt(.findIndependentReviews, "Which performance, durability, safety, or attendee reviews should you check for \(subject)?"),
                prompt(.planItinerary, "Which timing, travel, registration, or event-day plan works best for \(subject)?"),
                prompt(.generalAssistance, "Which fit, rules, cost, logistics, and safety details matter for \(subject)?")
            ]
        }
    }

    private func templateText(
        for action: SuggestedPromptAction,
        subject: String,
        category: IntentCategory
    ) -> String {
        switch action {
        case .learnPrerequisite:
            return "Would you like to learn about prerequisites to \(subject)?"
        case .findLearningMaterial:
            return "Would you like material to help understand \(subject)?"
        case .learnNextTopic:
            return "Which topic would you like to learn after \(subject)?"
        case .exploreApplications:
            return "Which applications of \(subject) would you like to explore?"
        case .findComplementary:
            return "Which compatible products or accessories for \(subject) would you like to explore?"
        case .exploreStyling:
            return "Would you like visual style or configuration ideas for \(subject)?"
        case .compareAlternatives:
            return "Which alternatives to \(subject) would you like to compare?"
        case .findIndependentReviews:
            return "Would you like independent reviews and buying advice for \(subject)?"
        case .exploreDestination:
            return "Would you like to discover notable places around \(subject)?"
        case .discoverRestaurants:
            return "Would you like to find restaurants and local favorites around \(subject)?"
        case .planItinerary:
            return "Would you like itinerary ideas for \(subject)?"
        case .codingAssistance:
            return "Would you like to understand \(subject) more deeply?"
        case .debugIssue:
            return "Would you like to explore debugging approaches for \(subject)?"
        case .testSolution:
            return "Would you like testing strategies for \(subject)?"
        case .findImplementationExamples:
            return "Would you like documentation and implementation examples for \(subject)?"
        case .productivityNextStep:
            return "Would you like to research the next step for \(subject)?"
        case .summarizeWork:
            return "Would you like supporting material for summarizing \(subject)?"
        case .improveWorkflow:
            return "Would you like to explore better workflows for \(subject)?"
        case .discoverMedia:
            return "Would you like to discover related works to \(subject)?"
        case .discoverSimilar:
            return "Which products similar to \(subject) would you like to compare?"
        case .findFlights:
            return "Would you like to compare flights for \(subject)?"
        case .generalAssistance:
            if category == .shopping {
                return "Which product-specific buying considerations for \(subject) would you like to research?"
            }
            return "Would you like to explore useful next steps for \(subject)?"
        }
    }

    private func isUsefulExternalSearch(
        _ option: SuggestedSearchOption,
        category: IntentCategory
    ) -> Bool {
        let query = option.query.lowercased()
        guard query.count >= 3,
              !query.hasPrefix("http://"),
              !query.hasPrefix("https://")
        else { return false }

        guard category == .shopping else { return true }
        let pageLocalActions = [
            "available sizes", "different sizes", "select size", "size chart",
            "available colors", "colour options", "add to cart", "buy now",
            "change quantity", "product details", "delivery options", "select variant",
            "choose configuration", "request quote", "book test ride", "write review"
        ]
        return !pageLocalActions.contains { query.contains($0) }
    }

    private func fallbackSearchOptions(
        for action: SuggestedPromptAction,
        subject: String,
        category: IntentCategory,
        agentContext: FieldAgentContext? = nil
    ) -> [SuggestedSearchOption] {
        switch action {
        case .learnPrerequisite:
            let topics = prerequisiteFallbackTopics(
                subject: subject,
                agentContext: agentContext
            )
            return topics.map {
                SuggestedSearchOption(
                    title: $0,
                    query: "\(subject) \($0) prerequisite"
                )
            }
        case .findLearningMaterial:
            return searches([("Beginner-friendly guide", "\(subject) beginner friendly guide"),
                             ("Visual tutorial", "\(subject) visual tutorial"),
                             ("Practice material", "\(subject) exercises with solutions")])
        case .learnNextTopic:
            return searches([("Next concept", "\(subject) next concepts learning roadmap"),
                             ("Advanced guide", "\(subject) advanced follow-up guide"),
                             ("Skill progression", "what to learn after \(subject)")])
        case .exploreApplications:
            return searches([("Real-world projects", "\(subject) real world project examples"),
                             ("Industry applications", "\(subject) industry applications"),
                             ("Applied case studies", "\(subject) applied case studies")])
        case .discoverSimilar:
            return searches([("Similar products", "products similar to \(subject)"),
                             ("Same-category alternatives", "best alternatives to \(subject) in the same category"),
                             ("Comparable models", "\(subject) comparable models comparison")])
        case .findComplementary:
            return searches([("Compatible accessories", "best compatible accessories for \(subject)"),
                             ("Essential add-ons", "essential add-ons for \(subject)"),
                             ("Compatibility guide", "\(subject) accessory compatibility buying guide")])
        case .exploreStyling:
            return searches([("Visual configurations", "\(subject) visual configuration ideas"),
                             ("Customization examples", "\(subject) customization examples"),
                             ("Design inspiration", "\(subject) design inspiration")])
        case .compareAlternatives:
            return searches([("Same-subtype alternatives", "\(subject) same subtype alternatives"),
                             ("Similar price tier", "\(subject) alternatives in the same price range"),
                             ("Same-use-case options", "\(subject) alternatives for the same use case and specifications")])
        case .findIndependentReviews:
            return searches([("Independent reviews", "\(subject) independent reviews"),
                             ("Long-term experience", "\(subject) long term review"),
                             ("Expert comparison", "\(subject) expert comparison")])
        case .discoverRestaurants:
            return searches([("Top nearby restaurants", "best restaurants near \(subject)"),
                             ("Local favorites", "local favorite restaurants near \(subject)"),
                             ("Special-occasion dining", "best special occasion restaurants near \(subject)")])
        case .exploreDestination:
            return searches([("Top nearby sights", "best sights and attractions near \(subject)"),
                             ("Local activities", "best local activities near \(subject)"),
                             ("Neighborhood guide", "what to do in the neighborhood around \(subject)")])
        case .codingAssistance:
            return searches([("Core idea", "\(subject) core concept explained"),
                             ("Step-by-step example", "\(subject) step by step worked example"),
                             ("Key invariants", "\(subject) key invariants and reasoning")])
        case .findImplementationExamples:
            return searches([("Annotated solution", "\(subject) annotated implementation"),
                             ("Recursive walkthrough", "\(subject) recursive walkthrough"),
                             ("Complexity analysis", "\(subject) time and space complexity")])
        case .generalAssistance where category == .shopping:
            return searches([("Buying guide", "\(subject) product specific buying guide"),
                             ("Long-term costs", "\(subject) long term costs and maintenance"),
                             ("Requirements and compatibility", "\(subject) requirements compatibility checklist")])
        default:
            return searches([("Overview", "\(subject) overview"),
                             ("Examples", "\(subject) examples"),
                             ("Practical guide", "\(subject) practical guide")])
        }
    }

    private func prerequisiteFallbackTopics(
        subject: String,
        agentContext: FieldAgentContext?
    ) -> [String] {
        guard let agentContext else {
            return ["Core Terminology", "Foundational Concepts", "Worked Examples"]
        }

        let broadFoundations: Set<String> = [
            "linearalgebra", "calculus", "differentialcalculus",
            "probability", "probabilitytheory", "basicstatistics"
        ]
        let fieldDefaults: [String]
        if agentContext.field.localizedCaseInsensitiveContains("machine learning") ||
            agentContext.field.localizedCaseInsensitiveContains("deep learning") {
            fieldDefaults = ["Supervised Learning", "Model Training", "Gradient Descent"]
        } else if agentContext.field.localizedCaseInsensitiveContains("computer science") {
            fieldDefaults = ["Data Structures", "Algorithmic Complexity", "Problem Decomposition"]
        } else {
            fieldDefaults = ["Core Terminology", "Foundational Concepts", "Worked Examples"]
        }

        let subjectKey = ContentPhrasePolicy.compactKey(subject)
        var seen = Set<String>()
        let values = (agentContext.nearbyConcepts + fieldDefaults).filter { value in
            let key = ContentPhrasePolicy.compactKey(value)
            guard key.count >= 4,
                  key != subjectKey,
                  !key.contains(subjectKey),
                  !subjectKey.contains(key),
                  !broadFoundations.contains(key),
                  seen.insert(key).inserted
            else { return false }
            return true
        }
        return Array(values.prefix(3))
    }

    private func searches(_ values: [(String, String)]) -> [SuggestedSearchOption] {
        values.map { SuggestedSearchOption(title: $0.0, query: $0.1) }
    }

    private func fallbackRationale(for action: SuggestedPromptAction) -> String {
        "This extends the current task with external information instead of repeating an action already available on the page."
    }

    func primarySubject(in report: ScreenContextReport) -> String {
        let rawModelSubject = report.intent.identifiedSubject.flatMap {
            $0.replacingOccurrences(
                of: #"^\s*\d+(?:\.\d+)*[.)]?\s+"#,
                with: "",
                options: .regularExpression
            )
        }
        let modelSubject = rawModelSubject?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let visibleTopic = (report.intent.category == .learning || report.intent.category == .coding)
            ? report.entities.topics
                .filter(ContentPhrasePolicy.isViableEntity)
                .max {
                    entitySubjectScore($0, report: report) <
                        entitySubjectScore($1, report: report)
                }
            : nil
        let documentTitleKeys = Set(
            report.importantText
                .filter { $0.category == .documentTitle }
                .map { ContentPhrasePolicy.compactKey($0.text) }
        )
        let modelSubjectKey = ContentPhrasePolicy.compactKey(modelSubject ?? "")
        let isDocumentReader = ["preview", "books", "adobe acrobat", "pdf expert"].contains { token in
            report.sourceContext.applicationName?.lowercased().contains(token) == true ||
                report.sourceContext.bundleIdentifier?.lowercased().contains(token) == true
        }
        let shouldPreferVisibleTopic = visibleTopic != nil && (
            ContentPhrasePolicy.isLikelyDocumentFilename(
                modelSubject ?? "",
                windowTitle: report.sourceContext.windowTitle
            ) || (isDocumentReader && documentTitleKeys.contains(modelSubjectKey))
        )
        if let modelSubject,
           !modelSubject.isEmpty,
           ContentPhrasePolicy.isViableEntity(modelSubject),
           !ContentPhrasePolicy.isLikelyBodyText(modelSubject),
           !shouldPreferVisibleTopic {
            return String(modelSubject.prefix(100))
        }

        let candidates: [String]
        switch report.intent.category {
        case .learning:
            candidates = report.entities.topics
        case .shopping:
            candidates = report.entities.products
        case .travel:
            candidates = report.entities.places
        case .coding:
            candidates = report.entities.topics
        case .entertainment, .productivity, .news, .finance, .health, .food,
             .realEstate, .careers, .social, .governmentLegal, .sportsFitness, .other:
            candidates = []
        }

        let entity = candidates
            .filter(ContentPhrasePolicy.isViableEntity)
            .max {
                entitySubjectScore($0, report: report) <
                    entitySubjectScore($1, report: report)
            }
        let visibleContent = report.importantText
            .filter {
                $0.category != .documentTitle &&
                    $0.category != .brandOrSite &&
                    $0.category != .action &&
                    $0.category != .price &&
                    $0.category != .size &&
                    $0.category != .date &&
                    ContentPhrasePolicy.isViableEntity($0.text)
            }
            .sorted { subjectScore($0) > subjectScore($1) }
            .first?
            .text
        let windowTitle = ContentPhrasePolicy.contentFromWindowTitle(
            report.sourceContext.windowTitle,
            websites: report.sourceContext.websites
        )
        let value = visibleTopic ?? entity ?? visibleContent ?? windowTitle ?? "this topic"
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? "this topic" : String(cleaned.prefix(100))
    }

    private func entitySubjectScore(_ candidate: String, report: ScreenContextReport) -> Double {
        let key = ContentPhrasePolicy.compactKey(candidate)
        var score = 0.0
        if let windowTitle = report.sourceContext.windowTitle,
           !key.isEmpty,
           ContentPhrasePolicy.compactKey(windowTitle).contains(key) {
            score += 2.0
        }
        if let item = report.importantText.first(where: {
            ContentPhrasePolicy.compactKey($0.text) == key
        }) {
            score += item.salienceScore
            score += Double(ContentPhrasePolicy.contextPrecedence(
                for: item.text,
                category: item.category
            )) / 100
        }
        let wordCount = ContentPhrasePolicy.words(in: candidate).count
        if wordCount >= 2 && wordCount <= 10 { score += 0.2 }
        return score
    }

    private func subjectScore(_ item: SalientText) -> Double {
        var score = item.salienceScore
        score += Double(item.category.contextPrecedence) / 100
        let wordCount = ContentPhrasePolicy.words(in: item.text).count
        if wordCount >= 2 && wordCount <= 12 { score += 0.15 }
        return score
    }

}

private struct PromptGenerationPayload: Encodable {
    struct IntentSummary: Encodable {
        let category: IntentCategory
        let subcategory: IntentSubcategory?
        let confidence: Double
        let method: ClassificationMethod
        let evidence: [String]
    }

    struct ImportantTextSummary: Encodable {
        let text: String
        let category: SalienceCategory
        let role: String
        let precedence: Int
    }

    let subject: String
    let agentContext: FieldAgentContext
    let sourceContext: ScreenSourceContext
    let intent: IntentSummary
    let importantText: [ImportantTextSummary]
    let entities: ExtractedEntities
    let temporalFreshness: TemporalFreshnessAssessment?

    init(
        report: ScreenContextReport,
        subject: String,
        agentContext: FieldAgentContext
    ) {
        self.subject = subject
        self.agentContext = agentContext
        sourceContext = report.sourceContext
        temporalFreshness = report.temporalFreshness
        intent = IntentSummary(
            category: report.intent.category,
            subcategory: report.intent.subcategory,
            confidence: report.intent.confidence,
            method: report.intent.method,
            evidence: Array(report.intent.evidence.prefix(6))
        )
        importantText = report.importantText.sorted {
            let leftPrecedence = ContentPhrasePolicy.contextPrecedence(
                for: $0.text,
                category: $0.category
            )
            let rightPrecedence = ContentPhrasePolicy.contextPrecedence(
                for: $1.text,
                category: $1.category
            )
            if leftPrecedence != rightPrecedence {
                return leftPrecedence > rightPrecedence
            }
            return $0.salienceScore > $1.salienceScore
        }.prefix(6).map {
            let precedence = ContentPhrasePolicy.contextPrecedence(
                for: $0.text,
                category: $0.category
            )
            return ImportantTextSummary(
                text: $0.text,
                category: $0.category,
                role: ContentPhrasePolicy.contextRole(for: $0.text, category: $0.category),
                precedence: precedence
            )
        }
        entities = ExtractedEntities(
            products: Array(report.entities.products.prefix(3)),
            topics: Array(report.entities.topics.prefix(3)),
            places: Array(report.entities.places.prefix(3)),
            dates: Array(report.entities.dates.prefix(3)),
            brandsAndSites: Array(report.entities.brandsAndSites.prefix(3)),
            prices: Array(report.entities.prices.prefix(3)),
            sizes: Array(report.entities.sizes.prefix(3))
        )
    }
}
