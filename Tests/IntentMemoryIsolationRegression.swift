import Foundation
import SQLite3

@main
struct IntentMemoryIsolationRegression {
    static func main() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("theia-memory-isolation-\(UUID().uuidString).sqlite3")

        var initialStore: IntentMemoryStore? = try IntentMemoryStore(databaseURL: databaseURL)
        try initialStore?.rememberBERTTrainingExample(
            model: "all-minilm",
            contextFingerprint: "historical-qwen-label",
            category: .coding,
            qwenConfidence: 0.99,
            embedding: [0.1, 0.2, 0.3]
        )
        initialStore = nil

        try executeLegacySeed(at: databaseURL)

        let rebuiltStore = try IntentMemoryStore(databaseURL: databaseURL)
        let rebuiltSignals = try rebuiltStore.allSignals()
        let rebuiltExamples = try rebuiltStore.bertTrainingExamples(model: "all-minilm")
        try require(
            rebuiltSignals.isEmpty,
            "A stale verified signal survived the memory schema rebuild."
        )
        try require(
            rebuiltExamples.isEmpty,
            "A historical Qwen-supervised embedding survived the memory schema rebuild."
        )

        let configuration = LocalModelConfiguration(
            baseURL: URL(string: "http://theia-regression.invalid")!,
            bertModel: "all-minilm",
            qwenModel: "qwen-regression",
            ruleAcceptanceThreshold: 0.90,
            bertAcceptanceThreshold: 0.90,
            memoryLearningThreshold: 0.50
        )
        let classifier = IntentClassificationService(
            configuration: configuration,
            localModels: StandaloneQwenMemoryProbe(),
            memoryStore: rebuiltStore,
            mode: .qwenOnly
        )
        let result = await classifier.classify(
            importantText: [
                SalientText(
                    text: "Ambiguous activity",
                    category: .heading,
                    salienceScore: 0.95,
                    ocrConfidence: 0.99,
                    reasons: ["test heading"],
                    boundingBox: NormalizedBoundingBox(
                        x: 0.1,
                        y: 0.8,
                        width: 0.5,
                        height: 0.05
                    )
                )
            ],
            sourceContext: .empty
        ).classification

        try require(result.method == .qwen, "The regression did not exercise standalone Qwen.")
        try require(result.confidence == 0.55, "Standalone Qwen confidence was not calibrated.")
        let finalSignals = try rebuiltStore.allSignals()
        let finalExamples = try rebuiltStore.bertTrainingExamples(model: "all-minilm")
        try require(
            finalSignals.isEmpty && finalExamples.isEmpty,
            "Standalone Qwen wrote unconfirmed classifier memory."
        )

        print("Intent memory isolation regression passed.")
    }

    private static func executeLegacySeed(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw MemoryRegressionFailure("Could not reopen the memory fixture.")
        }
        defer { sqlite3_close(database) }

        let sql = """
        UPDATE classification_memory_metadata SET value = '2' WHERE key = 'schema_version';
        INSERT INTO learned_intent_signals
            (kind, value, category, confidence, observations, created_at, updated_at, verified, policy_version)
        VALUES
            ('keyword', 'ambiguous activity', 'coding', 0.99, 99,
             '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1, 3);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MemoryRegressionFailure(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw MemoryRegressionFailure(message) }
    }
}

private final class StandaloneQwenMemoryProbe: LocalModelServing {
    func embeddings(model: String, inputs: [String]) async throws -> [[Double]] {
        throw MemoryRegressionFailure("Standalone Qwen must not request BERT embeddings.")
    }

    func qwenClassification(model: String, prompt: String) async throws -> QwenClassificationOutput {
        QwenClassificationOutput(
            category: .coding,
            subcategory: .programmingDebugging,
            confidence: 0.99,
            reason: "Unconfirmed standalone model decision.",
            signals: ["ambiguous activity"],
            trainingContext: "An ambiguous coding activity."
        )
    }
}

private struct MemoryRegressionFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
