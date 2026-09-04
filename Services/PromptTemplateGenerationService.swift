import Foundation

struct PromptTemplateGenerationService {
    private let qwenChatService = QwenChatService()
    private let fieldAgentContextService = FieldAgentContextService()

    func generate(
        categoryName: String,
        categoryDescription: String,
        action: SuggestedPromptAction
    ) async throws -> String {
        let request = """
        Create one concise next-step question template for Theia.
        Classification category: \(categoryName)
        Category purpose: \(categoryDescription)
        Prompt action: \(action.rawValue.replacingOccurrences(of: "_", with: " "))

        The result must be one user-facing question, contain the exact placeholder
        {subject}, and ask a useful next step appropriate to this category and action.
        Return only the template sentence, with no label, quotes, markdown, or explanation.
        """
        let response = try await qwenChatService.reply(
            to: [QwenChatMessage(role: .user, text: request)],
            agentContext: fieldAgentContextService.generalContext()
        )
        let template = response
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard template.localizedCaseInsensitiveContains("{subject}") else {
            throw PromptTemplateStoreError.missingSubjectPlaceholder
        }
        return template
    }
}
