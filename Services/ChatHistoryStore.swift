import Foundation

struct ChatHistoryStore {
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
            .appendingPathComponent("Chat", isDirectory: true)
            .appendingPathComponent("qwen-history.json", isDirectory: false)
    }

    func load() throws -> [QwenChatConversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([QwenChatConversation].self, from: data)
        let conversations = decoded.filter(\.hasUserMessages)
        if conversations.count != decoded.count {
            try save(conversations)
        }
        return conversations
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversations: [QwenChatConversation]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let recentConversations = conversations
            .filter(\.hasUserMessages)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(100)
        let data = try encoder.encode(Array(recentConversations))
        try data.write(to: fileURL, options: .atomic)
    }
}
