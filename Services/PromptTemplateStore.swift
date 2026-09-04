import Foundation

enum PromptTemplateStoreError: LocalizedError {
    case missingSubjectPlaceholder
    case emptyCategoryName
    case emptyKeywords
    case emptyTemplate
    case emptyPromptTitle
    case tooManyTemplates
    case duplicatePromptAction

    var errorDescription: String? {
        switch self {
        case .missingSubjectPlaceholder:
            return "Templates must include the {subject} placeholder."
        case .emptyCategoryName:
            return "Enter a name for the custom category."
        case .emptyKeywords:
            return "Add at least one keyword or phrase used to recognize this category."
        case .emptyTemplate:
            return "The prompt template cannot be empty."
        case .emptyPromptTitle:
            return "Enter a name for every prompt."
        case .tooManyTemplates:
            return "Each category must contain between one and four prompts."
        case .duplicatePromptAction:
            return "Each prompt in a category must use a different response behavior."
        }
    }
}

struct CustomCategoryMatch {
    let category: CustomIntentCategory
    let matchedKeywords: [String]
    let confidence: Double
}

struct PromptTemplateStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        self.fileURL = applicationSupport
            .appendingPathComponent("Theia", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent("prompt-templates.json", isDirectory: false)
    }

    func load() throws -> PromptTemplateSettingsSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PromptTemplateSettingsSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PromptTemplateSettingsSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func overrideText(
        for subcategory: IntentSubcategory,
        action: SuggestedPromptAction
    ) -> String? {
        let id = BuiltInPromptTemplateDefinition.identifier(
            subcategory: subcategory,
            action: action
        )
        return try? load().overrides.first(where: { $0.id == id })?.text
    }

    func customCategory(id: UUID) -> CustomIntentCategory? {
        try? load().customCategories.first(where: { $0.id == id })
    }

    func builtInPromptSet(for subcategory: IntentSubcategory) -> [CustomPromptTemplate]? {
        try? load().builtInPromptSets.first(where: { $0.subcategory == subcategory })?.templates
    }

    func effectiveBuiltInPromptSet(
        for subcategory: IntentSubcategory,
        defaults: [BuiltInPromptTemplateDefinition]
    ) -> [CustomPromptTemplate] {
        guard let snapshot = try? load() else {
            return defaults.map(Self.customTemplate(from:))
        }
        if let promptSet = snapshot.builtInPromptSets.first(where: {
            $0.subcategory == subcategory
        }) {
            return promptSet.templates.enumerated().map { index, savedTemplate in
                var template = savedTemplate
                guard template.defaultIdentifier == nil else { return template }
                let matchingDefault = defaults.first { $0.action == template.action }
                    ?? (defaults.indices.contains(index) ? defaults[index] : nil)
                template.defaultIdentifier = matchingDefault?.id
                return template
            }
        }
        let legacyOverrides = Dictionary(
            uniqueKeysWithValues: snapshot.overrides.map { ($0.id, $0.text) }
        )
        return defaults.map { definition in
            CustomPromptTemplate(
                defaultIdentifier: definition.id,
                title: definition.action.displayName,
                action: definition.action,
                text: legacyOverrides[definition.id] ?? definition.defaultText
            )
        }
    }

    func defaultBuiltInPromptSet(
        from defaults: [BuiltInPromptTemplateDefinition]
    ) -> [CustomPromptTemplate] {
        defaults.map(Self.customTemplate(from:))
    }

    func saveBuiltInPromptSet(
        subcategory: IntentSubcategory,
        templates rawTemplates: [CustomPromptTemplate]
    ) throws {
        let templates = try validatedTemplates(rawTemplates)
        var snapshot = try load()
        let promptSet = BuiltInPromptSetOverride(
            subcategory: subcategory,
            templates: templates,
            updatedAt: Date()
        )
        if let index = snapshot.builtInPromptSets.firstIndex(where: {
            $0.subcategory == subcategory
        }) {
            snapshot.builtInPromptSets[index] = promptSet
        } else {
            snapshot.builtInPromptSets.append(promptSet)
        }
        snapshot.overrides.removeAll { $0.subcategory == subcategory }
        snapshot.schemaVersion = 2
        try save(snapshot)
    }

    func resetBuiltInPromptSet(subcategory: IntentSubcategory) throws {
        var snapshot = try load()
        snapshot.builtInPromptSets.removeAll { $0.subcategory == subcategory }
        snapshot.overrides.removeAll { $0.subcategory == subcategory }
        snapshot.schemaVersion = 2
        try save(snapshot)
    }

    func resetBuiltInPrompt(
        subcategory: IntentSubcategory,
        promptID: UUID,
        defaults: [BuiltInPromptTemplateDefinition]
    ) throws {
        var templates = effectiveBuiltInPromptSet(for: subcategory, defaults: defaults)
        guard let index = templates.firstIndex(where: { $0.id == promptID }) else { return }
        let current = templates[index]
        let defaultTemplates = defaultBuiltInPromptSet(from: defaults)
        guard let defaultTemplate = defaultTemplates.first(where: {
            $0.defaultIdentifier == current.defaultIdentifier
        }) ?? defaultTemplates.first(where: { $0.action == current.action }) else {
            return
        }
        templates[index] = CustomPromptTemplate(
            id: current.id,
            defaultIdentifier: defaultTemplate.defaultIdentifier,
            title: defaultTemplate.title,
            action: defaultTemplate.action,
            text: defaultTemplate.text
        )
        try saveBuiltInPromptSet(subcategory: subcategory, templates: templates)
    }

    func resetAllBuiltInPromptSets() throws {
        var snapshot = try load()
        snapshot.builtInPromptSets.removeAll()
        snapshot.overrides.removeAll()
        snapshot.schemaVersion = 2
        try save(snapshot)
    }

    func saveOverride(
        subcategory: IntentSubcategory,
        action: SuggestedPromptAction,
        text rawText: String
    ) throws {
        let text = try validatedTemplate(rawText)
        let id = BuiltInPromptTemplateDefinition.identifier(
            subcategory: subcategory,
            action: action
        )
        var snapshot = try load()
        if let index = snapshot.overrides.firstIndex(where: { $0.id == id }) {
            snapshot.overrides[index].text = text
            snapshot.overrides[index].updatedAt = Date()
        } else {
            snapshot.overrides.append(
                PromptTemplateOverride(
                    id: id,
                    subcategory: subcategory,
                    action: action,
                    text: text,
                    updatedAt: Date()
                )
            )
        }
        try save(snapshot)
    }

    func resetOverride(
        subcategory: IntentSubcategory,
        action: SuggestedPromptAction
    ) throws {
        let id = BuiltInPromptTemplateDefinition.identifier(
            subcategory: subcategory,
            action: action
        )
        var snapshot = try load()
        snapshot.overrides.removeAll { $0.id == id }
        try save(snapshot)
    }

    func saveCustomCategory(_ rawCategory: CustomIntentCategory) throws {
        let name = rawCategory.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PromptTemplateStoreError.emptyCategoryName }
        let keywords = normalizedKeywords(rawCategory.keywords)
        guard !keywords.isEmpty else { throw PromptTemplateStoreError.emptyKeywords }
        let templates = rawCategory.templates
        let validated = try validatedTemplates(templates)

        var category = rawCategory
        category.name = name
        category.categoryDescription = rawCategory.categoryDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        category.keywords = keywords
        category.templates = validated
        category.updatedAt = Date()

        var snapshot = try load()
        if let index = snapshot.customCategories.firstIndex(where: { $0.id == category.id }) {
            snapshot.customCategories[index] = category
        } else {
            snapshot.customCategories.append(category)
        }
        try save(snapshot)
    }

    func deleteCustomCategory(id: UUID) throws {
        var snapshot = try load()
        snapshot.customCategories.removeAll { $0.id == id }
        try save(snapshot)
    }

    func bestCustomCategoryMatch(in rawText: String) -> CustomCategoryMatch? {
        guard let categories = try? load().customCategories else { return nil }
        let text = normalized(rawText)
        guard !text.isEmpty else { return nil }

        return categories.compactMap { category -> (CustomCategoryMatch, Int)? in
            let matchedKeywords = category.keywords.filter {
                let keyword = normalized($0)
                return keyword.count >= 2 && containsPhrase(keyword, in: text)
            }
            let nameMatched = containsPhrase(normalized(category.name), in: text)
            guard nameMatched || !matchedKeywords.isEmpty else { return nil }

            let score = (nameMatched ? 4 : 0) + matchedKeywords.reduce(0) {
                $0 + max(1, normalized($1).split(separator: " ").count)
            }
            let confidence = min(0.99, 0.91 + (nameMatched ? 0.04 : 0) + Double(matchedKeywords.count) * 0.02)
            return (
                CustomCategoryMatch(
                    category: category,
                    matchedKeywords: matchedKeywords,
                    confidence: confidence
                ),
                score
            )
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    private func save(_ snapshot: PromptTemplateSettingsSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private func validatedTemplate(_ rawText: String) throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PromptTemplateStoreError.emptyTemplate }
        guard text.localizedCaseInsensitiveContains("{subject}") else {
            throw PromptTemplateStoreError.missingSubjectPlaceholder
        }
        return text
    }

    private func validatedTemplates(
        _ rawTemplates: [CustomPromptTemplate]
    ) throws -> [CustomPromptTemplate] {
        guard (1...4).contains(rawTemplates.count) else {
            throw PromptTemplateStoreError.tooManyTemplates
        }
        guard Set(rawTemplates.map(\.action)).count == rawTemplates.count else {
            throw PromptTemplateStoreError.duplicatePromptAction
        }
        return try rawTemplates.map { template in
            let title = template.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw PromptTemplateStoreError.emptyPromptTitle }
            return CustomPromptTemplate(
                id: template.id,
                defaultIdentifier: template.defaultIdentifier,
                title: title,
                action: template.action,
                text: try validatedTemplate(template.text),
                updatedAt: Date()
            )
        }
    }

    private static func customTemplate(
        from definition: BuiltInPromptTemplateDefinition
    ) -> CustomPromptTemplate {
        CustomPromptTemplate(
            defaultIdentifier: definition.id,
            title: definition.action.displayName,
            action: definition.action,
            text: definition.defaultText
        )
    }

    private func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { keyword in
            let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(value)
            guard key.count >= 2, seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}+#]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func containsPhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return " \(text) ".contains(" \(phrase) ")
    }
}
