import Foundation
import SQLite3

enum IntentMemoryStoreError: LocalizedError {
    case applicationSupportUnavailable
    case database(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support folder could not be located."
        case .database(let message):
            return "Classification memory could not be updated. \(message)"
        }
    }
}

struct BERTTrainingExample {
    let category: IntentCategory
    let qwenConfidence: Double
    let embedding: [Double]
    let contextFingerprint: String
}

final class IntentMemoryStore {
    let databaseURL: URL

    private let requiredDistinctContexts = 12
    private let requiredCategoryShare = 0.99
    private let requiredQwenConfirmations = 3
    private let requiredQwenAgreement = 0.99
    private let currentRulePolicyVersion = 3
    private let currentMemorySchemaVersion = 3
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func makeDefault() throws -> IntentMemoryStore {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw IntentMemoryStoreError.applicationSupportUnavailable
        }

        let directory = applicationSupport
            .appendingPathComponent("Theia", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try IntentMemoryStore(
            databaseURL: directory.appendingPathComponent("classification.sqlite3")
        )
    }

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.databaseURL.path, &handle, flags, nil)

        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned error code \(result)."
            if let handle { sqlite3_close(handle) }
            throw IntentMemoryStoreError.database(message)
        }

        database = handle
        do {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS learned_intent_signals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL,
                    category TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    observations INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    verified INTEGER NOT NULL DEFAULT 0,
                    policy_version INTEGER NOT NULL DEFAULT 1,
                    UNIQUE(kind, value)
                );
                """
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_learned_signals_kind ON learned_intent_signals(kind);"
            )
            if try !columnExistsLocked(table: "learned_intent_signals", column: "verified") {
                // Existing rows were learned using the old screen-level rule. Keep
                // them for auditability, but do not trust them until new evidence
                // verifies the signal-level association.
                try execute(
                    "ALTER TABLE learned_intent_signals ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;"
                )
            }
            if try !columnExistsLocked(table: "learned_intent_signals", column: "policy_version") {
                // Rules promoted under the previous policy remain available for
                // audit, but cannot participate in classification until they
                // satisfy the stricter repeated-evidence policy.
                try execute(
                    "ALTER TABLE learned_intent_signals ADD COLUMN policy_version INTEGER NOT NULL DEFAULT 1;"
                )
            }
            try execute(
                """
                CREATE TABLE IF NOT EXISTS intent_signal_observations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL,
                    category TEXT NOT NULL,
                    context_fingerprint TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    explicitly_supported INTEGER NOT NULL DEFAULT 0,
                    source_method TEXT NOT NULL DEFAULT 'legacy',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(kind, value, category, context_fingerprint)
                );
                """
            )
            if try !columnExistsLocked(table: "intent_signal_observations", column: "source_method") {
                try execute(
                    "ALTER TABLE intent_signal_observations ADD COLUMN source_method TEXT NOT NULL DEFAULT 'legacy';"
                )
            }
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_signal_observations_lookup
                ON intent_signal_observations(kind, value, category);
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS qwen_supervised_bert_examples (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    model TEXT NOT NULL,
                    context_fingerprint TEXT NOT NULL,
                    category TEXT NOT NULL,
                    qwen_confidence REAL NOT NULL,
                    embedding_json TEXT NOT NULL,
                    dimensions INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(model, context_fingerprint)
                );
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_qwen_bert_examples_model_category
                ON qwen_supervised_bert_examples(model, category, updated_at);
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS classification_memory_metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )
            try execute(
                """
                INSERT OR IGNORE INTO classification_memory_metadata(key, value)
                VALUES ('schema_version', '0');
                """
            )

            // Version 3 quarantines all labels learned from uncalibrated Qwen
            // confidence. The downloaded models remain untouched; only adaptive
            // classifier memory is rebuilt under the consensus policy.
            let versionCheck = "(SELECT value FROM classification_memory_metadata WHERE key = 'schema_version')"
            try execute("DELETE FROM learned_intent_signals WHERE \(versionCheck) != '\(currentMemorySchemaVersion)';")
            try execute("DELETE FROM intent_signal_observations WHERE \(versionCheck) != '\(currentMemorySchemaVersion)';")
            try execute("DELETE FROM qwen_supervised_bert_examples WHERE \(versionCheck) != '\(currentMemorySchemaVersion)';")
            try execute(
                "UPDATE classification_memory_metadata SET value = '\(currentMemorySchemaVersion)' WHERE key = 'schema_version';"
            )
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func matchingSignals(in text: String, websites: [String]) throws -> [LearnedIntentSignal] {
        try lock.withLock {
            let signals = try fetchAllLocked()
            let normalizedWebsites = websites.map(normalizeWebsite)
            let lowerText = text.lowercased()

            return signals.filter { signal in
                switch signal.kind {
                case .website:
                    let learnedWebsite = normalizeWebsite(signal.value)
                    return normalizedWebsites.contains {
                        $0 == learnedWebsite || $0.hasSuffix(".\(learnedWebsite)")
                    }
                case .keyword:
                    return ContentPhrasePolicy.isViableEntity(signal.value) &&
                        containsPhrase(signal.value, in: lowerText)
                }
            }
        }
    }

    /// Records a possible association without immediately turning it into a rule.
    /// Promotion requires 12 distinct screenshots, 99% category agreement, and
    /// repeated direct Qwen confirmation. A single model decision can never add
    /// a keyword or website to the trusted rule set.
    @discardableResult
    func observeCandidate(
        kind: LearnedSignalKind,
        value rawValue: String,
        category: IntentCategory,
        confidence: Double,
        contextFingerprint: String,
        explicitlySupported: Bool,
        sourceMethod: ClassificationMethod
    ) throws -> LearnedIntentSignal? {
        try lock.withLock {
            let value = normalize(kind: kind, value: rawValue)
            let fingerprint = contextFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !fingerprint.isEmpty else {
                throw IntentMemoryStoreError.database("An empty memory observation was ignored.")
            }
            if kind == .keyword && !ContentPhrasePolicy.isViableEntity(value) {
                return nil
            }

            try recordObservationLocked(
                kind: kind,
                value: value,
                category: category,
                confidence: confidence,
                contextFingerprint: fingerprint,
                explicitlySupported: explicitlySupported,
                sourceMethod: sourceMethod
            )

            let associations = try associationEvidenceLocked(kind: kind, value: value)
            let totalObservations = associations.reduce(0) { $0 + $1.observations }
            let eligible = associations.filter { evidence in
                guard evidence.observations >= requiredDistinctContexts,
                      totalObservations > 0,
                      evidence.qwenObservations >= requiredQwenConfirmations
                else { return false }
                let categoryShare = Double(evidence.observations) / Double(totalObservations)
                let qwenAgreement = Double(evidence.qwenSupportedObservations) /
                    Double(evidence.qwenObservations)
                return categoryShare >= requiredCategoryShare &&
                    qwenAgreement >= requiredQwenAgreement
            }

            guard let best = eligible.sorted(by: associationIsStronger).first else {
                try setVerificationLocked(kind: kind, value: value, verified: false)
                return nil
            }

            let promoted = try saveVerifiedSignalLocked(
                kind: kind,
                value: value,
                category: best.category,
                confidence: best.confidence,
                observations: best.observations
            )
            return promoted.category == category ? promoted : nil
        }
    }

    func allSignals() throws -> [LearnedIntentSignal] {
        try lock.withLock { try fetchAllLocked() }
    }

    func rememberBERTTrainingExample(
        model: String,
        contextFingerprint: String,
        category: IntentCategory,
        qwenConfidence: Double,
        embedding: [Double]
    ) throws {
        try lock.withLock {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let fingerprint = contextFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedModel.isEmpty,
                  !fingerprint.isEmpty,
                  !embedding.isEmpty,
                  embedding.allSatisfy(\.isFinite)
            else {
                throw IntentMemoryStoreError.database("An invalid BERT training example was ignored.")
            }

            let encoded = try JSONEncoder().encode(embedding)
            guard let embeddingJSON = String(data: encoded, encoding: .utf8) else {
                throw IntentMemoryStoreError.database("A BERT training vector could not be encoded.")
            }

            let sql = """
                INSERT INTO qwen_supervised_bert_examples
                    (model, context_fingerprint, category, qwen_confidence,
                     embedding_json, dimensions, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(model, context_fingerprint) DO UPDATE SET
                    category = CASE
                        WHEN excluded.qwen_confidence >= qwen_supervised_bert_examples.qwen_confidence
                        THEN excluded.category
                        ELSE qwen_supervised_bert_examples.category
                    END,
                    qwen_confidence = MAX(
                        qwen_supervised_bert_examples.qwen_confidence,
                        excluded.qwen_confidence
                    ),
                    embedding_json = CASE
                        WHEN excluded.qwen_confidence >= qwen_supervised_bert_examples.qwen_confidence
                        THEN excluded.embedding_json
                        ELSE qwen_supervised_bert_examples.embedding_json
                    END,
                    dimensions = CASE
                        WHEN excluded.qwen_confidence >= qwen_supervised_bert_examples.qwen_confidence
                        THEN excluded.dimensions
                        ELSE qwen_supervised_bert_examples.dimensions
                    END,
                    updated_at = excluded.updated_at;
                """
            var statement: OpaquePointer?
            try prepare(sql, statement: &statement)
            defer { sqlite3_finalize(statement) }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            sqlite3_bind_text(statement, 1, normalizedModel, -1, transient)
            sqlite3_bind_text(statement, 2, fingerprint, -1, transient)
            sqlite3_bind_text(statement, 3, category.rawValue, -1, transient)
            sqlite3_bind_double(statement, 4, min(1, max(0, qwenConfidence)))
            sqlite3_bind_text(statement, 5, embeddingJSON, -1, transient)
            sqlite3_bind_int(statement, 6, Int32(embedding.count))
            sqlite3_bind_text(statement, 7, timestamp, -1, transient)
            sqlite3_bind_text(statement, 8, timestamp, -1, transient)

            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func bertTrainingExamples(
        model: String,
        limitPerCategory: Int = 200
    ) throws -> [BERTTrainingExample] {
        try lock.withLock {
            let sql = """
                SELECT category, qwen_confidence, embedding_json, context_fingerprint
                FROM qwen_supervised_bert_examples
                WHERE model = ?
                ORDER BY updated_at DESC;
                """
            var statement: OpaquePointer?
            try prepare(sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, model, -1, transient)

            var categoryCounts: [IntentCategory: Int] = [:]
            var examples: [BERTTrainingExample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let categoryText = sqlite3_column_text(statement, 0),
                      let category = IntentCategory(rawValue: String(cString: categoryText)),
                      categoryCounts[category, default: 0] < limitPerCategory,
                      let embeddingText = sqlite3_column_text(statement, 2),
                      let fingerprintText = sqlite3_column_text(statement, 3),
                      let data = String(cString: embeddingText).data(using: .utf8),
                      let embedding = try? JSONDecoder().decode([Double].self, from: data),
                      !embedding.isEmpty
                else { continue }

                examples.append(
                    BERTTrainingExample(
                        category: category,
                        qwenConfidence: sqlite3_column_double(statement, 1),
                        embedding: embedding,
                        contextFingerprint: String(cString: fingerprintText)
                    )
                )
                categoryCounts[category, default: 0] += 1
            }
            return examples
        }
    }

    private func fetchAllLocked() throws -> [LearnedIntentSignal] {
        let sql = """
            SELECT kind, value, category, confidence, observations
            FROM learned_intent_signals
            WHERE verified = 1 AND policy_version = \(currentRulePolicyVersion)
            ORDER BY updated_at DESC;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [LearnedIntentSignal] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let signal = decodeSignal(statement) {
                results.append(signal)
            }
        }
        return results
    }

    private func fetchLocked(
        kind: LearnedSignalKind,
        value: String
    ) throws -> LearnedIntentSignal? {
        let sql = """
            SELECT kind, value, category, confidence, observations
            FROM learned_intent_signals
            WHERE kind = ? AND value = ? AND verified = 1
                AND policy_version = \(currentRulePolicyVersion)
            LIMIT 1;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeSignal(statement)
    }

    private func decodeSignal(_ statement: OpaquePointer?) -> LearnedIntentSignal? {
        guard let kindText = sqlite3_column_text(statement, 0),
              let valueText = sqlite3_column_text(statement, 1),
              let categoryText = sqlite3_column_text(statement, 2),
              let kind = LearnedSignalKind(rawValue: String(cString: kindText)),
              let category = IntentCategory(rawValue: String(cString: categoryText))
        else { return nil }

        return LearnedIntentSignal(
            kind: kind,
            value: String(cString: valueText),
            category: category,
            confidence: rounded(sqlite3_column_double(statement, 3)),
            observations: Int(sqlite3_column_int(statement, 4))
        )
    }

    private struct AssociationEvidence {
        let category: IntentCategory
        let observations: Int
        let qwenObservations: Int
        let qwenSupportedObservations: Int
        let confidence: Double
    }

    private func recordObservationLocked(
        kind: LearnedSignalKind,
        value: String,
        category: IntentCategory,
        confidence: Double,
        contextFingerprint: String,
        explicitlySupported: Bool,
        sourceMethod: ClassificationMethod
    ) throws {
        let sql = """
            INSERT INTO intent_signal_observations
                (kind, value, category, context_fingerprint, confidence,
                 explicitly_supported, created_at, updated_at, source_method)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind, value, category, context_fingerprint) DO UPDATE SET
                confidence = MAX(intent_signal_observations.confidence, excluded.confidence),
                explicitly_supported = MAX(
                    intent_signal_observations.explicitly_supported,
                    excluded.explicitly_supported
                ),
                source_method = CASE
                    WHEN excluded.source_method = 'qwen' THEN excluded.source_method
                    ELSE intent_signal_observations.source_method
                END,
                updated_at = excluded.updated_at;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        sqlite3_bind_text(statement, 3, category.rawValue, -1, transient)
        sqlite3_bind_text(statement, 4, contextFingerprint, -1, transient)
        sqlite3_bind_double(statement, 5, min(1, max(0, confidence)))
        sqlite3_bind_int(statement, 6, explicitlySupported ? 1 : 0)
        sqlite3_bind_text(statement, 7, timestamp, -1, transient)
        sqlite3_bind_text(statement, 8, timestamp, -1, transient)
        sqlite3_bind_text(statement, 9, sourceMethod.rawValue, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func associationEvidenceLocked(
        kind: LearnedSignalKind,
        value: String
    ) throws -> [AssociationEvidence] {
        let sql = """
            SELECT category,
                   COUNT(*),
                   SUM(CASE WHEN source_method = 'qwen' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN source_method = 'qwen' AND explicitly_supported = 1 THEN 1 ELSE 0 END),
                   AVG(confidence)
            FROM intent_signal_observations
            WHERE kind = ? AND value = ?
                AND source_method IN ('bert', 'qwen')
            GROUP BY category;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)

        var results: [AssociationEvidence] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let categoryText = sqlite3_column_text(statement, 0),
                  let category = IntentCategory(rawValue: String(cString: categoryText))
            else { continue }
            results.append(
                AssociationEvidence(
                    category: category,
                    observations: Int(sqlite3_column_int(statement, 1)),
                    qwenObservations: Int(sqlite3_column_int(statement, 2)),
                    qwenSupportedObservations: Int(sqlite3_column_int(statement, 3)),
                    confidence: rounded(sqlite3_column_double(statement, 4))
                )
            )
        }
        return results
    }

    private func associationIsStronger(
        _ left: AssociationEvidence,
        _ right: AssociationEvidence
    ) -> Bool {
        if left.observations != right.observations {
            return left.observations > right.observations
        }
        if left.qwenSupportedObservations != right.qwenSupportedObservations {
            return left.qwenSupportedObservations > right.qwenSupportedObservations
        }
        return left.confidence > right.confidence
    }

    private func saveVerifiedSignalLocked(
        kind: LearnedSignalKind,
        value: String,
        category: IntentCategory,
        confidence: Double,
        observations: Int
    ) throws -> LearnedIntentSignal {
        let sql = """
            INSERT INTO learned_intent_signals
                (kind, value, category, confidence, observations, created_at,
                 updated_at, verified, policy_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, \(currentRulePolicyVersion))
            ON CONFLICT(kind, value) DO UPDATE SET
                category = excluded.category,
                confidence = excluded.confidence,
                observations = excluded.observations,
                updated_at = excluded.updated_at,
                verified = 1,
                policy_version = excluded.policy_version;
            """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        sqlite3_bind_text(statement, 3, category.rawValue, -1, transient)
        sqlite3_bind_double(statement, 4, min(1, max(0, confidence)))
        sqlite3_bind_int(statement, 5, Int32(observations))
        sqlite3_bind_text(statement, 6, timestamp, -1, transient)
        sqlite3_bind_text(statement, 7, timestamp, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard let saved = try fetchLocked(kind: kind, value: value) else {
            throw IntentMemoryStoreError.database("The verified signal could not be read back.")
        }
        return saved
    }

    private func setVerificationLocked(
        kind: LearnedSignalKind,
        value: String,
        verified: Bool
    ) throws {
        let sql = "UPDATE learned_intent_signals SET verified = ? WHERE kind = ? AND value = ?;"
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, verified ? 1 : 0)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, transient)
        sqlite3_bind_text(statement, 3, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func columnExistsLocked(table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(\(table));", statement: &statement)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func databaseError() -> IntentMemoryStoreError {
        IntentMemoryStoreError.database(String(cString: sqlite3_errmsg(database)))
    }

    private func normalize(kind: LearnedSignalKind, value: String) -> String {
        switch kind {
        case .website:
            return normalizeWebsite(value)
        case .keyword:
            return value
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
    }

    private func normalizeWebsite(_ value: String) -> String {
        let trimmed = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        if let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"),
           let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return trimmed.hasPrefix("www.") ? String(trimmed.dropFirst(4)) : trimmed
    }

    private func containsPhrase(_ phrase: String, in lowerText: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.lowercased())
        guard let expression = try? NSRegularExpression(pattern: "(?<![a-z0-9])\(escaped)(?![a-z0-9])") else {
            return false
        }
        let range = NSRange(lowerText.startIndex..<lowerText.endIndex, in: lowerText)
        return expression.firstMatch(in: lowerText, range: range) != nil
    }

    private func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
