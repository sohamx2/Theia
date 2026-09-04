import Foundation

struct QwenChatService {
    let modelName: String

    private let localModels: QwenChatModelServing

    init() {
        let configuration = LocalModelConfiguration.current
        modelName = configuration.qwenModel
        localModels = OllamaLocalModelClient(baseURL: configuration.baseURL)
    }

    init(modelName: String, localModels: QwenChatModelServing) {
        self.modelName = modelName
        self.localModels = localModels
    }

    func reply(
        to messages: [QwenChatMessage],
        agentContext: FieldAgentContext,
        screenshotPNGData: Data? = nil
    ) async throws -> String {
        guard messages.contains(where: { $0.role == .user }) else {
            throw LocalModelError.invalidChat
        }
        if let screenshotPNGData {
            guard let visionModels = localModels as? QwenVisionChatModelServing else {
                throw LocalModelError.invalidChat
            }
            return try await visionModels.visionChat(
                model: QwenVisionRoutingPolicy.chatModel(
                    selectedModel: modelName,
                    hasScreenshot: true
                ),
                messages: messages,
                agentContext: agentContext,
                pngData: screenshotPNGData
            )
        }
        return try await localModels.chat(
            model: QwenVisionRoutingPolicy.chatModel(
                selectedModel: modelName,
                hasScreenshot: false
            ),
            messages: messages,
            agentContext: agentContext
        )
    }

    func streamedReply(
        to messages: [QwenChatMessage],
        agentContext: FieldAgentContext,
        screenshotPNGData: Data? = nil
    ) -> AsyncThrowingStream<String, Error> {
        guard messages.contains(where: { $0.role == .user }) else {
            return failedStream(LocalModelError.invalidChat)
        }
        // Vision answers stay buffered so no Qwen3-VL reasoning fragment can
        // appear before the completed response has passed the full sanitizer.
        if screenshotPNGData != nil {
            return oneShotStream {
                try await reply(
                    to: messages,
                    agentContext: agentContext,
                    screenshotPNGData: screenshotPNGData
                )
            }
        }
        if let streamingModels = localModels as? QwenChatStreamingModelServing {
            return streamingModels.chatStream(
                model: QwenVisionRoutingPolicy.chatModel(
                    selectedModel: modelName,
                    hasScreenshot: false
                ),
                messages: messages,
                agentContext: agentContext
            )
        }
        return oneShotStream {
            try await reply(to: messages, agentContext: agentContext)
        }
    }

    private func oneShotStream(
        _ operation: @escaping () async throws -> String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await operation())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func failedStream(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
