import SwiftUI

struct PromptCategoryListItem: Identifiable, Equatable {
    enum Origin: Equatable {
        case builtIn(IntentSubcategory)
        case custom(UUID)
    }

    let id: String
    let name: String
    let parentName: String
    let categoryDescription: String
    let origin: Origin
    var templates: [CustomPromptTemplate]
    let defaultTemplates: [CustomPromptTemplate]
    let isCustomized: Bool
}

@MainActor
final class PromptTemplateSettingsModel: ObservableObject {
    @Published private(set) var categories: [PromptCategoryListItem] = []
    @Published var errorMessage: String?

    private let store: PromptTemplateStore
    private let service: IntentPromptSuggestionService

    init(
        store: PromptTemplateStore = PromptTemplateStore(),
        service: IntentPromptSuggestionService = IntentPromptSuggestionService()
    ) {
        self.store = store
        self.service = service
        reload()
    }

    func reload() {
        do {
            let snapshot = try store.load()
            let definitions = Dictionary(grouping: service.builtInTemplateDefinitions(), by: \.subcategory)
            let builtIn = IntentSubcategory.allCases.map { subcategory in
                let defaults = definitions[subcategory] ?? []
                let defaultTemplates = store.defaultBuiltInPromptSet(from: defaults)
                return PromptCategoryListItem(
                    id: "built-in:\(subcategory.rawValue)",
                    name: displayName(subcategory.rawValue),
                    parentName: displayName(subcategory.parent.rawValue),
                    categoryDescription: "Built-in \(displayName(subcategory.parent.rawValue)) prompts",
                    origin: .builtIn(subcategory),
                    templates: store.effectiveBuiltInPromptSet(for: subcategory, defaults: defaults),
                    defaultTemplates: defaultTemplates,
                    isCustomized: snapshot.builtInPromptSets.contains { $0.subcategory == subcategory } ||
                        snapshot.overrides.contains { $0.subcategory == subcategory }
                )
            }
            let custom = snapshot.customCategories.map { category in
                PromptCategoryListItem(
                    id: "custom:\(category.id.uuidString)",
                    name: category.name,
                    parentName: "Custom · \(displayName(category.parentBehavior.rawValue))",
                    categoryDescription: category.categoryDescription,
                    origin: .custom(category.id),
                    templates: category.templates,
                    defaultTemplates: [],
                    isCustomized: true
                )
            }
            categories = (builtIn + custom).sorted {
                if $0.parentName == $1.parentName {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.parentName.localizedCaseInsensitiveCompare($1.parentName) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ category: PromptCategoryListItem, templates: [CustomPromptTemplate]) throws {
        switch category.origin {
        case .builtIn(let subcategory):
            try store.saveBuiltInPromptSet(subcategory: subcategory, templates: templates)
        case .custom(let categoryID):
            guard var custom = store.customCategory(id: categoryID) else { return }
            custom.templates = templates
            try store.saveCustomCategory(custom)
        }
        reload()
    }

    func reset(_ category: PromptCategoryListItem) throws {
        guard case .builtIn(let subcategory) = category.origin else { return }
        try store.resetBuiltInPromptSet(subcategory: subcategory)
        reload()
    }

    func resetPrompt(
        _ prompt: CustomPromptTemplate,
        in category: PromptCategoryListItem
    ) throws {
        guard case .builtIn(let subcategory) = category.origin else { return }
        let definitions = service.builtInTemplateDefinitions().filter {
            $0.subcategory == subcategory
        }
        try store.resetBuiltInPrompt(
            subcategory: subcategory,
            promptID: prompt.id,
            defaults: definitions
        )
        reload()
    }

    func resetAllBuiltInTemplates() throws {
        try store.resetAllBuiltInPromptSets()
        reload()
    }

    func deleteCustomCategory(_ category: PromptCategoryListItem) throws {
        guard case .custom(let id) = category.origin else { return }
        try store.deleteCustomCategory(id: id)
        reload()
    }

    func createCustomCategory(
        name: String,
        description: String,
        keywords: [String],
        parentBehavior: IntentCategory,
        promptTitle: String,
        action: SuggestedPromptAction,
        templateText: String
    ) throws {
        try store.saveCustomCategory(
            CustomIntentCategory(
                name: name,
                categoryDescription: description,
                keywords: keywords,
                parentBehavior: parentBehavior,
                templates: [
                    CustomPromptTemplate(title: promptTitle, action: action, text: templateText)
                ]
            )
        )
        reload()
    }

    private func displayName(_ rawValue: String) -> String {
        if rawValue == IntentSubcategory.jobSearching.rawValue { return "Job Search" }
        return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct PromptTemplateSettingsView: View {
    let onBack: () -> Void

    @StateObject private var model = PromptTemplateSettingsModel()
    @State private var selectedCategoryID: String?
    @State private var editingPromptID: UUID?
    @State private var isAddingPrompt = false
    @State private var isCreatingCategory = false
    @State private var searchText = ""
    @State private var isConfirmingResetAll = false
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            TheiaTheme.background.ignoresSafeArea()
            if isCreatingCategory {
                CustomCategoryEditorView(model: model) {
                    isCreatingCategory = false
                }
            } else if let category = selectedCategory {
                if editingPromptID != nil || isAddingPrompt {
                    PromptEditorView(
                        model: model,
                        category: category,
                        prompt: category.templates.first { $0.id == editingPromptID },
                        onBack: {
                            editingPromptID = nil
                            isAddingPrompt = false
                        },
                        onSaved: {
                            editingPromptID = nil
                            isAddingPrompt = false
                        }
                    )
                } else {
                    categoryDetail(category)
                }
            } else {
                categoryList
            }
        }
        .frame(minWidth: 720, minHeight: 610)
        .tint(TheiaTheme.action)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
        .foregroundStyle(TheiaTheme.ink)
        .alert("Restore all built-in templates?", isPresented: $isConfirmingResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) {
                try? model.resetAllBuiltInTemplates()
            }
        } message: {
            Text("Every built-in prompt will return to its Theia default. Custom categories are preserved.")
        }
    }

    private var selectedCategory: PromptCategoryListItem? {
        model.categories.first { $0.id == selectedCategoryID }
    }

    private var filteredCategories: [PromptCategoryListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.categories }
        return model.categories.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.parentName.localizedCaseInsensitiveContains(query)
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            navigationHeader(title: "Prompt Templates", subtitle: "Defaults are kept separately from your local changes.", back: onBack) {
                HStack(spacing: 8) {
                    Button("Restore All Defaults") { isConfirmingResetAll = true }
                        .buttonStyle(.bordered)
                    Button("Add Category") { isCreatingCategory = true }
                        .buttonStyle(.borderedProminent)
                        .tint(TheiaTheme.action)
                        .foregroundStyle(TheiaTheme.actionText)
                }
            }
            TextField("Search categories", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredCategories) { category in
                        Button { selectedCategoryID = category.id } label: {
                            HStack(spacing: 14) {
                                Text(category.isCustomized ? "CUSTOM" : "BUILT-IN")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(category.isCustomized ? TheiaTheme.gold : TheiaTheme.blue)
                                    .frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(category.name)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(TheiaTheme.ink)
                                    Text("\(category.parentName) · \(category.templates.count) prompts")
                                        .font(.caption)
                                        .foregroundStyle(TheiaTheme.mutedInk)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(TheiaTheme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private func categoryDetail(_ category: PromptCategoryListItem) -> some View {
        VStack(spacing: 0) {
            navigationHeader(
                title: category.name,
                subtitle: "\(category.parentName) · Change, add, or delete prompts.",
                back: { selectedCategoryID = nil }
            ) {
                if category.templates.count < 4 {
                    Button("Add Prompt") { isAddingPrompt = true }
                        .buttonStyle(.borderedProminent)
                        .tint(TheiaTheme.action)
                        .foregroundStyle(TheiaTheme.actionText)
                }
            }

            ScrollView {
                VStack(spacing: 11) {
                    ForEach(Array(category.templates.enumerated()), id: \.element.id) { index, prompt in
                        Button { editingPromptID = prompt.id } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(TheiaTheme.actionText)
                                    .frame(width: 30, height: 30)
                                    .background(TheiaTheme.action, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(prompt.displayTitle)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(TheiaTheme.ink)
                                    Text(prompt.action.displayName)
                                        .font(.caption)
                                        .foregroundStyle(TheiaTheme.mutedInk)
                                    Text(prompt.text)
                                        .font(.caption)
                                        .foregroundStyle(TheiaTheme.mutedInk)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text("Edit")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(TheiaTheme.blue)
                            }
                            .padding(15)
                            .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(TheiaTheme.border))
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(TheiaTheme.danger)
                    }

                    HStack {
                        if case .builtIn = category.origin, category.isCustomized {
                            Button("Restore Category Defaults") { try? model.reset(category) }
                                .buttonStyle(.bordered)
                        }
                        if case .custom = category.origin {
                            Button("Delete Category", role: .destructive) {
                                try? model.deleteCustomCategory(category)
                                selectedCategoryID = nil
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                        Text("Maximum 4 prompts")
                            .font(.caption)
                            .foregroundStyle(TheiaTheme.mutedInk)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private func navigationHeader<Actions: View>(
        title: String,
        subtitle _: String,
        back: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 14) {
            Button(action: back) {
                Text("Back")
                    .frame(width: 64, height: 32)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(TheiaTheme.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(TheiaTheme.ink)
            }
            Spacer()
            actions()
        }
        .padding(28)
    }
}

private struct PromptEditorView: View {
    @ObservedObject var model: PromptTemplateSettingsModel
    let category: PromptCategoryListItem
    let prompt: CustomPromptTemplate?
    let onBack: () -> Void
    let onSaved: () -> Void

    @State private var title: String
    @State private var action: SuggestedPromptAction
    @State private var text: String
    @State private var errorMessage: String?
    @State private var isGenerating = false

    private let generator = PromptTemplateGenerationService()

    init(
        model: PromptTemplateSettingsModel,
        category: PromptCategoryListItem,
        prompt: CustomPromptTemplate?,
        onBack: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.category = category
        self.prompt = prompt
        self.onBack = onBack
        self.onSaved = onSaved
        _title = State(initialValue: prompt?.displayTitle ?? "New Prompt")
        _action = State(initialValue: prompt?.action ?? Self.availableAction(in: category))
        _text = State(initialValue: prompt?.text ?? "What would you like to explore next about {subject}?")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Button(action: onBack) {
                        Text("Back")
                            .frame(width: 64, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(TheiaTheme.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(prompt == nil ? "Add Prompt" : "Change Prompt")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(TheiaTheme.ink)
                        Text(category.name).font(.caption).foregroundStyle(TheiaTheme.mutedInk)
                    }
                }

                field("PROMPT NAME", "The label shown in this category, such as Interview Questions.") {
                    TextField("Prompt name", text: $title).textFieldStyle(.roundedBorder)
                }
                field("RESPONSE BEHAVIOR", "Controls Qwen's JSON schema and validation. Each category needs distinct behaviors.") {
                    Picker("Response behavior", selection: $action) {
                        ForEach(SuggestedPromptAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                field("PROMPT TEMPLATE", "Use {subject} where Theia should insert the analyzed topic.") {
                    TextEditor(text: $text)
                        .font(.system(size: 14, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 150)
                        .background(TheiaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(TheiaTheme.border))
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(TheiaTheme.danger)
                }

                HStack {
                    Button {
                        generateWithQwen()
                    } label: {
                        if isGenerating { ProgressView().controlSize(.small) }
                        else { Text("Generate with Qwen") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating)

                    if prompt != nil, category.templates.count > 1 {
                        Button("Delete Prompt", role: .destructive, action: deletePrompt)
                            .buttonStyle(.bordered)
                    }

                    if let prompt,
                       case .builtIn = category.origin,
                       prompt.defaultIdentifier != nil {
                        Button("Restore Default") { restoreDefault(prompt) }
                            .buttonStyle(.bordered)
                    }

                    Spacer()
                    Button("Save Prompt", action: savePrompt)
                        .buttonStyle(.borderedProminent)
                        .tint(TheiaTheme.action)
                        .foregroundStyle(TheiaTheme.actionText)
                }
            }
            .padding(28)
        }
    }

    private func field<Content: View>(_ title: String, _: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.bold()).foregroundStyle(TheiaTheme.ink)
            content()
        }
    }

    private func savePrompt() {
        var templates = category.templates
        let value = CustomPromptTemplate(
            id: prompt?.id ?? UUID(),
            defaultIdentifier: prompt?.defaultIdentifier,
            title: title,
            action: action,
            text: text
        )
        if let prompt, let index = templates.firstIndex(where: { $0.id == prompt.id }) {
            templates[index] = value
        } else {
            templates.append(value)
        }
        do {
            try model.save(category, templates: templates)
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }

    private func deletePrompt() {
        guard let prompt else { return }
        do {
            try model.save(category, templates: category.templates.filter { $0.id != prompt.id })
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }

    private func restoreDefault(_ prompt: CustomPromptTemplate) {
        do {
            try model.resetPrompt(prompt, in: category)
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateWithQwen() {
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                text = try await generator.generate(
                    categoryName: category.name,
                    categoryDescription: category.categoryDescription,
                    action: action
                )
            } catch {
                errorMessage = "Qwen could not generate a template. \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private static func availableAction(in category: PromptCategoryListItem) -> SuggestedPromptAction {
        let used = Set(category.templates.map(\.action))
        return SuggestedPromptAction.allCases.first { !used.contains($0) } ?? .generalAssistance
    }
}

private struct CustomCategoryEditorView: View {
    @ObservedObject var model: PromptTemplateSettingsModel
    let onBack: () -> Void

    @State private var name = ""
    @State private var categoryDescription = ""
    @State private var keywords = ""
    @State private var parentBehavior: IntentCategory = .other
    @State private var promptTitle = "Next Step"
    @State private var action: SuggestedPromptAction = .generalAssistance
    @State private var templateText = "What would you like to explore next about {subject}?"
    @State private var errorMessage: String?
    @State private var isGenerating = false

    private let generator = PromptTemplateGenerationService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 14) {
                    Button("Back", action: onBack)
                        .buttonStyle(.bordered)
                        .frame(width: 74, height: 32)
                        .foregroundStyle(TheiaTheme.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New Classification Category")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(TheiaTheme.ink)
                    }
                }
                TextField("Category name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Description", text: $categoryDescription).textFieldStyle(.roundedBorder)
                TextField("Matching keywords, comma separated", text: $keywords).textFieldStyle(.roundedBorder)
                Picker("Closest built-in behavior", selection: $parentBehavior) {
                    ForEach(IntentCategory.allCases, id: \.self) {
                        Text($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                    }
                }
                TextField("First prompt name", text: $promptTitle).textFieldStyle(.roundedBorder)
                Picker("Response behavior", selection: $action) {
                    ForEach(SuggestedPromptAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextEditor(text: $templateText)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 120)
                    .background(TheiaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 14))

                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(TheiaTheme.danger) }
                HStack {
                    Button("Generate Template with Qwen") { generateWithQwen() }
                        .buttonStyle(.bordered)
                        .disabled(isGenerating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Add Category", action: createCategory)
                        .buttonStyle(.borderedProminent)
                        .tint(TheiaTheme.action)
                        .foregroundStyle(TheiaTheme.actionText)
                }
            }
            .padding(28)
        }
    }

    private func generateWithQwen() {
        isGenerating = true
        Task {
            do {
                templateText = try await generator.generate(
                    categoryName: name,
                    categoryDescription: categoryDescription,
                    action: action
                )
            } catch { errorMessage = error.localizedDescription }
            isGenerating = false
        }
    }

    private func createCategory() {
        do {
            try model.createCustomCategory(
                name: name,
                description: categoryDescription,
                keywords: keywords.split(separator: ",").map(String.init),
                parentBehavior: parentBehavior,
                promptTitle: promptTitle,
                action: action,
                templateText: templateText
            )
            onBack()
        } catch { errorMessage = error.localizedDescription }
    }
}
