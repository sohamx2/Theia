import Foundation

enum AnalysisJSONError: LocalizedError {
    case applicationSupportUnavailable
    case noSavedAnalysis

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support folder could not be located."
        case .noSavedAnalysis:
            return "No previous Theia analysis has been saved yet."
        }
    }
}

struct AnalysisJSONService {
    struct SavedAnalysis {
        let report: ScreenContextReport
        let json: String
        let fileURL: URL
    }

    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    func encode(_ report: ScreenContextReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }

    func save(_ json: String) throws -> URL {
        let directory = try analysisDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory.appendingPathComponent("latest-analysis.json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func loadLatest() throws -> SavedAnalysis {
        let fileURL = try analysisDirectory()
            .appendingPathComponent("latest-analysis.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AnalysisJSONError.noSavedAnalysis
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(ScreenContextReport.self, from: data)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return SavedAnalysis(report: report, json: json, fileURL: fileURL)
    }

    private func analysisDirectory() throws -> URL {
        if let directoryOverride { return directoryOverride }
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AnalysisJSONError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent("Theia", isDirectory: true)
            .appendingPathComponent("Analysis", isDirectory: true)
    }
}
