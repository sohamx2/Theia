import Foundation

@main
struct ChatHistoryStoreRegression {
    @MainActor
    static func main() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-chat-history-\(UUID().uuidString).json")
        let store = ChatHistoryStore(fileURL: temporaryURL)
        let timestamp = Date(timeIntervalSince1970: 1_788_195_600)
        let context = FieldAgentContext(
            category: .other,
            subcategory: nil,
            activeSubject: "general questions",
            field: "general assistance",
            specialistRole: "concise general assistant",
            sourceKind: "direct chat",
            userStage: "Direct chat",
            assumptions: [],
            nearbyConcepts: []
        )
        let conversation = QwenChatConversation(
            mode: .general,
            agentContext: context,
            messages: [
                QwenChatMessage(role: .user, text: "Persist this", createdAt: timestamp)
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try store.save([conversation])
        let restored = try store.load()
        guard restored == [conversation] else {
            throw RegressionFailure.historyDidNotRoundTrip
        }

        let state = AppState(chatHistoryStore: store)
        state.startNewQwenChat(with: context, mode: .general)
        let firstNewID = state.activeQwenChatConversationID
        state.startNewQwenChat(with: context, mode: .general)
        guard let firstNewID,
              state.activeQwenChatConversationID != firstNewID,
              state.qwenChatConversations == [conversation],
              try store.load() == [conversation] else {
            throw RegressionFailure.newChatReusedOldConversation
        }

        let continuedContext = FieldAgentContextService().continuingContext(
            from: context,
            parentPrompt: "How are DNNs used?",
            selectedPath: "Practical applications",
            existingAnswer: "DNNs are used for perception, language, and prediction."
        )
        state.startNewQwenChat(with: continuedContext, mode: .specialist)
        guard state.qwenChatMessages.count == 1,
              state.qwenChatMessages.first?.role == .assistant,
              !state.qwenChatMessages.contains(where: { $0.role == .user }),
              state.qwenChatAgentContext?.continuationContext == continuedContext.continuationContext,
              state.qwenChatConversations == [conversation]
        else {
            throw RegressionFailure.continuationInheritedChatHistory
        }

        state.appendQwenChatMessage(QwenChatMessage(role: .user, text: "Now persist this chat"))
        guard state.qwenChatConversations.count == 2,
              try store.load().count == 2,
              let activeID = state.activeQwenChatConversationID else {
            throw RegressionFailure.messageDidNotCreateHistory
        }

        state.deleteQwenChatConversation(activeID)
        guard state.qwenChatConversations == [conversation],
              try store.load() == [conversation] else {
            throw RegressionFailure.chatWasNotDeleted
        }

        let emptyConversation = QwenChatConversation(
            mode: .general,
            agentContext: context,
            messages: [QwenChatMessage(role: .assistant, text: "Greeting only")]
        )
        try store.save([emptyConversation, conversation])
        guard try store.load() == [conversation] else {
            throw RegressionFailure.emptyChatWasPersisted
        }

        print("Chat history persistence regression passed.")
    }
}

private enum RegressionFailure: Error {
    case historyDidNotRoundTrip
    case newChatReusedOldConversation
    case continuationInheritedChatHistory
    case messageDidNotCreateHistory
    case chatWasNotDeleted
    case emptyChatWasPersisted
}
