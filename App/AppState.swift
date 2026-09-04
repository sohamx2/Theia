import AppKit
import Combine

struct QwenChatImageAttachment {
    let id = UUID()
    let fileName: String
    let pngData: Data
    let preview: NSImage
}

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case checkingPermission
        case requestingPermission
        case capturing
        case recognizingText
        case analyzingContext
        case analyzingVision
        case awaitingInternetPermission
        case generatingPrompts
        case savingResults
        case complete
        case cancelled
        case permissionRequired
        case failed

        var message: String {
            switch self {
            case .idle:
                return "Ready to analyze your screen"
            case .checkingPermission:
                return "Checking Screen Recording permission..."
            case .requestingPermission:
                return "Requesting Screen Recording permission..."
            case .capturing:
                return "Capturing the frontmost window..."
            case .recognizingText:
                return "Extracting text from the screenshot..."
            case .analyzingContext:
                return "Classifying context with rules, BERT, and Qwen..."
            case .analyzingVision:
                return "Understanding the screenshot with Qwen3-VL..."
            case .awaitingInternetPermission:
                return "Waiting for live web-search permission..."
            case .generatingPrompts:
                return "Generating next-step prompts with Qwen..."
            case .savingResults:
                return "Creating the analysis JSON file..."
            case .complete:
                return "Analysis complete"
            case .cancelled:
                return "Analysis cancelled"
            case .permissionRequired:
                return "Screen Recording permission is required"
            case .failed:
                return "Analysis failed"
            }
        }

        var isWorking: Bool {
            switch self {
            case .checkingPermission, .requestingPermission, .capturing,
                    .recognizingText, .analyzingContext, .analyzingVision,
                    .awaitingInternetPermission,
                    .generatingPrompts,
                    .savingResults:
                return true
            default:
                return false
            }
        }
    }

    @Published var currentStatus: Status = .idle
    @Published var ocrOutput = ""
    @Published var lastImage: NSImage?
    @Published var latestError: String?
    @Published var analysisReport: ScreenContextReport?
    @Published var analysisJSON = ""
    @Published var analysisJSONFileURL: URL?
    @Published var classificationProgress: [ClassificationStageProgress] = []
    @Published private(set) var promptSummaryExpansions: [String: PromptSummaryExpansionState] = [:]
    @Published var qwenChatMessages: [QwenChatMessage] = []
    @Published var qwenChatAgentContext: FieldAgentContext?
    @Published var qwenChatMode: QwenChatMode = .general
    @Published private(set) var qwenChatConversations: [QwenChatConversation] = []
    @Published private(set) var activeQwenChatConversationID: UUID?
    @Published var qwenChatError: String?
    @Published var isQwenChatResponding = false
    @Published var qwenChatImageAttachment: QwenChatImageAttachment?
    @Published private(set) var activeLocalModelName = LocalModelConfiguration.current.qwenModel
    @Published var pendingLocalModelName: String?
    @Published var localModelSwitchError: String?
    @Published var lastSiriRequest: String?

    private let chatHistoryStore: ChatHistoryStore
    private var activeQwenChatCreatedAt = Date()

    init(chatHistoryStore: ChatHistoryStore = ChatHistoryStore()) {
        self.chatHistoryStore = chatHistoryStore
        do {
            qwenChatConversations = try chatHistoryStore.load()
        } catch {
            qwenChatError = "Local chat history could not be loaded. \(error.localizedDescription)"
        }
    }

    func beginLocalModelSwitch(to modelName: String) {
        pendingLocalModelName = modelName
        localModelSwitchError = nil
    }

    func finishLocalModelSwitch(to modelName: String) {
        activeLocalModelName = modelName
        pendingLocalModelName = nil
        localModelSwitchError = nil
    }

    func failLocalModelSwitch(_ message: String) {
        pendingLocalModelName = nil
        localModelSwitchError = message
    }

    func resetForAnalysis() {
        currentStatus = .checkingPermission
        ocrOutput = ""
        lastImage = nil
        latestError = nil
        analysisReport = nil
        analysisJSON = ""
        analysisJSONFileURL = nil
        classificationProgress = []
        resetPromptSummary()
    }

    func resetPromptSummary() {
        promptSummaryExpansions.removeAll()
    }

    func promptSummaryExpansion(
        for selection: PromptSummarySelection
    ) -> PromptSummaryExpansionState? {
        promptSummaryExpansions[selection.id]
    }

    func beginPromptSummary(_ selection: PromptSummarySelection) {
        promptSummaryExpansions[selection.id] = PromptSummaryExpansionState(
            selection: selection,
            summary: nil,
            error: nil,
            isGenerating: true
        )
    }

    func finishPromptSummary(
        _ summary: PromptSummaryResult,
        for selection: PromptSummarySelection
    ) {
        guard promptSummaryExpansions[selection.id] != nil else { return }
        promptSummaryExpansions[selection.id] = PromptSummaryExpansionState(
            selection: selection,
            summary: summary,
            error: nil,
            isGenerating: false
        )
    }

    func failPromptSummary(
        _ message: String,
        for selection: PromptSummarySelection
    ) {
        guard promptSummaryExpansions[selection.id] != nil else { return }
        promptSummaryExpansions[selection.id] = PromptSummaryExpansionState(
            selection: selection,
            summary: nil,
            error: message,
            isGenerating: false
        )
    }

    func dismissPromptSummary(_ selection: PromptSummarySelection) {
        promptSummaryExpansions[selection.id] = nil
    }

    func prepareQwenChat(with context: FieldAgentContext, mode: QwenChatMode) {
        if let activeID = activeQwenChatConversationID,
           !qwenChatConversations.contains(where: { $0.id == activeID }),
           qwenChatMode == mode,
           let activeContext = qwenChatAgentContext,
           conversationContext(activeContext, matches: context, mode: mode) {
            return
        }

        if let activeID = activeQwenChatConversationID,
           let active = qwenChatConversations.first(where: { $0.id == activeID }),
           conversation(active, matches: context, mode: mode) {
            apply(active)
            return
        }

        if let existing = qwenChatConversations.first(where: {
            conversation($0, matches: context, mode: mode)
        }) {
            apply(existing)
            return
        }

        startNewQwenChat(with: context, mode: mode)
    }

    func startNewQwenChat() {
        guard let context = qwenChatAgentContext else { return }
        startNewQwenChat(with: context, mode: qwenChatMode)
    }

    func appendQwenChatMessage(_ message: QwenChatMessage) {
        qwenChatMessages.append(message)
        updateActiveConversation()
    }

    func beginStreamingQwenResponse(_ text: String) -> UUID {
        let message = QwenChatMessage(role: .assistant, text: text)
        qwenChatMessages.append(message)
        return message.id
    }

    func updateStreamingQwenResponse(id: UUID, text: String) {
        guard let index = qwenChatMessages.firstIndex(where: { $0.id == id }) else { return }
        let existing = qwenChatMessages[index]
        qwenChatMessages[index] = QwenChatMessage(
            id: existing.id,
            role: existing.role,
            text: text,
            createdAt: existing.createdAt
        )
    }

    func finishStreamingQwenResponse() {
        updateActiveConversation()
    }

    func selectQwenChatConversation(_ id: UUID) {
        guard let conversation = qwenChatConversations.first(where: { $0.id == id }) else { return }
        apply(conversation)
    }

    func deleteQwenChatConversation(_ id: UUID) {
        let wasActive = activeQwenChatConversationID == id
        let activeContext = qwenChatAgentContext
        let activeMode = qwenChatMode
        qwenChatConversations.removeAll { $0.id == id }
        persistQwenChatHistory()
        if wasActive, let activeContext {
            startNewQwenChat(with: activeContext, mode: activeMode)
        }
    }

    func startNewQwenChat(with context: FieldAgentContext, mode: QwenChatMode) {
        qwenChatError = nil
        isQwenChatResponding = false
        qwenChatImageAttachment = nil
        let messages = [
            QwenChatMessage(
                role: .assistant,
                text: mode == .general
                    ? "I’m ready to help. What would you like to work through?"
                    : "I’m ready as your \(context.specialistRole). The active subject is \(context.activeSubject)."
            )
        ]
        activeQwenChatConversationID = UUID()
        activeQwenChatCreatedAt = Date()
        qwenChatMode = mode
        qwenChatAgentContext = context
        qwenChatMessages = messages
    }

    private func apply(_ conversation: QwenChatConversation) {
        activeQwenChatConversationID = conversation.id
        activeQwenChatCreatedAt = conversation.createdAt
        qwenChatMode = conversation.mode
        qwenChatAgentContext = conversation.agentContext
        qwenChatMessages = conversation.messages
        qwenChatError = nil
        isQwenChatResponding = false
        qwenChatImageAttachment = nil
    }

    private func conversation(
        _ conversation: QwenChatConversation,
        matches context: FieldAgentContext,
        mode: QwenChatMode
    ) -> Bool {
        guard conversation.mode == mode else { return false }
        return conversationContext(conversation.agentContext, matches: context, mode: mode)
    }

    private func conversationContext(
        _ activeContext: FieldAgentContext,
        matches context: FieldAgentContext,
        mode: QwenChatMode
    ) -> Bool {
        if mode == .general { return true }
        return activeContext.field == context.field &&
            activeContext.activeSubject == context.activeSubject
    }

    private func updateActiveConversation() {
        guard let activeID = activeQwenChatConversationID,
              let context = qwenChatAgentContext
        else { return }

        guard qwenChatMessages.contains(where: {
            $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return }

        if let index = qwenChatConversations.firstIndex(where: { $0.id == activeID }) {
            qwenChatConversations[index].agentContext = context
            qwenChatConversations[index].messages = Array(qwenChatMessages.suffix(200))
            qwenChatConversations[index].updatedAt = Date()
        } else {
            qwenChatConversations.insert(
                QwenChatConversation(
                    id: activeID,
                    mode: qwenChatMode,
                    agentContext: context,
                    messages: Array(qwenChatMessages.suffix(200)),
                    createdAt: activeQwenChatCreatedAt,
                    updatedAt: Date()
                ),
                at: 0
            )
        }

        qwenChatConversations.sort { $0.updatedAt > $1.updatedAt }
        persistQwenChatHistory()
    }

    private func persistQwenChatHistory() {
        do {
            try chatHistoryStore.save(qwenChatConversations)
        } catch {
            qwenChatError = "Chat is available, but its local history could not be saved. \(error.localizedDescription)"
        }
    }
}
