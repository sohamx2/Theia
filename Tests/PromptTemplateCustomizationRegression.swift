import Foundation

@main
struct PromptTemplateCustomizationRegression {
    static func main() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-template-regression-\(UUID().uuidString).json")
        let store = PromptTemplateStore(fileURL: fileURL)
        let models = TemplateRegressionModels()
        let service = IntentPromptSuggestionService(
            modelName: "test-qwen",
            localModels: models,
            templateStore: store
        )

        try require(
            service.builtInTemplateDefinitions().count == IntentSubcategory.allCases.count * 4,
            "Every built-in taxonomy leaf must expose four editable templates."
        )

        let override = "Which advanced guides should you use to master {subject}?"
        try store.saveOverride(
            subcategory: .coursesTutorials,
            action: .findLearningMaterial,
            text: override
        )
        let builtInReport = report(
            intent: IntentClassification(
                category: .learning,
                subcategory: .coursesTutorials,
                confidence: 0.97,
                identifiedSubject: "Neural Networks",
                evidence: ["course"]
            )
        )
        let builtInContext = try service.preparePromptContext(for: builtInReport)
        try require(
            builtInContext.fallbackPrompts.contains {
                $0.action == .findLearningMaterial &&
                    $0.text == "Which advanced guides should you use to master Neural Networks?"
            },
            "A built-in override must be substituted into prompt preparation."
        )

        let jobDefaults = service.builtInTemplateDefinitions().filter {
            $0.subcategory == .jobSearching
        }
        let immutableJobDefaults = store.defaultBuiltInPromptSet(from: jobDefaults)
        var jobPrompts = store.effectiveBuiltInPromptSet(
            for: .jobSearching,
            defaults: jobDefaults
        )
        let usedActions = Set(jobPrompts.map(\.action))
        let replacementAction = SuggestedPromptAction.allCases.first {
            !usedActions.contains($0)
        }!
        jobPrompts[0].title = "Interview Questions"
        jobPrompts[0].action = replacementAction
        jobPrompts[0].text = "Which interview questions should you prepare for when pursuing {subject}?"
        try store.saveBuiltInPromptSet(subcategory: .jobSearching, templates: jobPrompts)
        try require(
            store.builtInPromptSet(for: .jobSearching)?.first?.displayTitle == "Interview Questions",
            "A built-in prompt must support an arbitrary user-facing name."
        )
        try require(
            defaultContract(store.defaultBuiltInPromptSet(from: jobDefaults)) ==
                defaultContract(immutableJobDefaults),
            "Editing a prompt must not mutate the separately held default template list."
        )

        let jobIntent = IntentClassification(
            category: .careers,
            subcategory: .jobSearching,
            confidence: 0.98,
            identifiedSubject: "iOS engineering roles",
            evidence: ["job search"]
        )
        let jobContext = try service.preparePromptContext(for: report(intent: jobIntent))
        try require(
            jobContext.fallbackPrompts.contains {
                $0.action == replacementAction &&
                    $0.text == "Which interview questions should you prepare for when pursuing iOS engineering roles?"
            },
            "A renamed category prompt must drive the next analysis."
        )

        try store.resetBuiltInPrompt(
            subcategory: .jobSearching,
            promptID: jobPrompts[0].id,
            defaults: jobDefaults
        )
        let restoredPrompt = store.effectiveBuiltInPromptSet(
            for: .jobSearching,
            defaults: jobDefaults
        ).first
        try require(
            restoredPrompt?.defaultIdentifier == immutableJobDefaults.first?.defaultIdentifier &&
                restoredPrompt?.action == immutableJobDefaults.first?.action &&
                restoredPrompt?.text == immutableJobDefaults.first?.text,
            "An individual built-in prompt must restore its original default definition."
        )

        do {
            var tooMany = jobPrompts
            tooMany.append(
                CustomPromptTemplate(
                    title: "Fifth Prompt",
                    action: SuggestedPromptAction.allCases.first {
                        !Set(tooMany.map(\.action)).contains($0)
                    }!,
                    text: "Which other path should you explore for {subject}?"
                )
            )
            try store.saveBuiltInPromptSet(subcategory: .jobSearching, templates: tooMany)
            throw TemplateRegressionError.failure("A fifth category prompt must be rejected.")
        } catch PromptTemplateStoreError.tooManyTemplates {
            // Expected: Theia's runtime contract supports at most four prompt actions.
        }

        try store.saveBuiltInPromptSet(
            subcategory: .jobSearching,
            templates: Array(jobPrompts.dropLast())
        )
        try require(
            store.builtInPromptSet(for: .jobSearching)?.count == 3,
            "A built-in prompt must be deletable while at least one remains."
        )

        let customCategory = CustomIntentCategory(
            name: "Astrophotography",
            categoryDescription: "Planning and editing photographs of the night sky.",
            keywords: ["astrophotography", "star tracker"],
            parentBehavior: .learning,
            templates: [
                CustomPromptTemplate(
                    action: .findLearningMaterial,
                    text: "Which field guides would help you improve {subject}?"
                )
            ]
        )
        try store.saveCustomCategory(customCategory)

        try store.resetAllBuiltInPromptSets()
        let resetSnapshot = try store.load()
        try require(
            resetSnapshot.builtInPromptSets.isEmpty && resetSnapshot.overrides.isEmpty,
            "Restoring all defaults must remove every built-in prompt customization."
        )
        try require(
            resetSnapshot.customCategories.contains { $0.id == customCategory.id },
            "Restoring built-in defaults must preserve user-created categories."
        )

        let configuration = LocalModelConfiguration(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            bertModel: "unused",
            qwenModel: "unused",
            ruleAcceptanceThreshold: 0.90,
            bertAcceptanceThreshold: 0.90,
            memoryLearningThreshold: 0.90
        )
        let classifier = IntentClassificationService(
            configuration: configuration,
            localModels: models,
            memoryStore: nil,
            promptTemplateStore: store
        )
        let outcome = await classifier.classify(
            importantText: [
                SalientText(
                    text: "Astrophotography with a star tracker",
                    category: .heading,
                    salienceScore: 0.98,
                    ocrConfidence: 0.99,
                    reasons: ["heading"],
                    boundingBox: NormalizedBoundingBox(x: 0.1, y: 0.8, width: 0.7, height: 0.1)
                )
            ],
            sourceContext: .empty
        )
        try require(
            outcome.classification.customCategoryID == customCategory.id &&
                outcome.classification.customCategoryName == "Astrophotography",
            "A custom category must be selected before the built-in cascade."
        )
        try require(models.modelCallCount == 0, "Custom keyword classification must not invoke BERT or Qwen.")

        let customContext = try service.preparePromptContext(
            for: report(intent: outcome.classification)
        )
        try require(
            customContext.fallbackPrompts.first?.text ==
                "Which field guides would help you improve Astrophotography with a star tracker?",
            "The custom category template must drive prompt preparation."
        )

        let encoded = try JSONEncoder().encode(outcome.classification)
        let json = String(decoding: encoded, as: UTF8.self)
        try require(
            json.contains("customCategoryName") && json.contains("Astrophotography"),
            "Custom category identity must be preserved in analysis JSON."
        )

        print("Prompt template customization regression passed.")
    }

    private static func report(intent: IntentClassification) -> ScreenContextReport {
        ScreenContextReport(
            schemaVersion: "1.0",
            generatedAt: Date(),
            sourceContext: .empty,
            intent: intent,
            importantText: [],
            entities: ExtractedEntities(
                products: [],
                topics: [intent.identifiedSubject ?? "Astrophotography with a star tracker"],
                places: [],
                dates: [],
                brandsAndSites: [],
                prices: [],
                sizes: []
            ),
            categories: [],
            cleanedSegments: [intent.identifiedSubject ?? "Astrophotography with a star tracker"],
            statistics: AnalysisStatistics(
                ocrLineCount: 1,
                cleanedSegmentCount: 1,
                importantTextCount: 1,
                discardedLineCount: 0
            ),
            promptGeneration: nil
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TemplateRegressionError.failure(message) }
    }

    private static func defaultContract(_ templates: [CustomPromptTemplate]) -> [String] {
        templates.map {
            "\($0.defaultIdentifier ?? "")|\($0.displayTitle)|\($0.action.rawValue)|\($0.text)"
        }
    }
}

private final class TemplateRegressionModels: LocalModelServing, PromptSuggestionModelServing {
    private(set) var modelCallCount = 0

    func embeddings(model: String, inputs: [String]) async throws -> [[Double]] {
        modelCallCount += 1
        throw LocalModelError.missingEmbeddings
    }

    func qwenClassification(model: String, prompt: String) async throws -> QwenClassificationOutput {
        modelCallCount += 1
        throw LocalModelError.invalidClassification
    }

    func expandPromptChoices(
        model: String,
        requests: [PromptExpansionRequest],
        analysisJSON: String
    ) async throws -> PromptExpansionModelResult {
        modelCallCount += 1
        throw LocalModelError.invalidPromptExpansion
    }
}

private enum TemplateRegressionError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message): return message
        }
    }
}
