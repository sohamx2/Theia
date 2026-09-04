import Foundation

struct TemporalFreshnessService {
    static let defaultKnowledgeCutoff: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2024, month: 12, day: 31))!
    }()

    let knowledgeCutoff: Date

    init(knowledgeCutoff: Date = TemporalFreshnessService.defaultKnowledgeCutoff) {
        self.knowledgeCutoff = knowledgeCutoff
    }

    func assess(
        report: ScreenContextReport,
        analyzedAt: Date = Date()
    ) -> TemporalFreshnessAssessment {
        var text = report.cleanedSegments
        text.append(contentsOf: report.importantText.map(\.text))
        if let subject = report.intent.identifiedSubject { text.append(subject) }
        if let title = report.sourceContext.windowTitle { text.append(title) }
        return assess(text: text, category: report.intent.category, analyzedAt: analyzedAt)
    }

    func assess(
        text rawText: [String],
        category: IntentCategory? = nil,
        analyzedAt: Date = Date()
    ) -> TemporalFreshnessAssessment {
        let evidenceLines = rawText.filter { !isBoilerplateDateLine($0) }
        let text = evidenceLines.joined(separator: "\n").lowercased()
        let detectedYears = years(in: text)
        let relativeSignals = matchingPhrases(
            in: text,
            phrases: [
                "latest", "breaking", "today", "yesterday", "tomorrow",
                "this week", "this month", "this year", "as of", "currently",
                "live updates", "real time", "real-time", "newly announced",
                "just released"
            ]
        )
        let currentFactSignals = matchingPhrases(
            in: text,
            phrases: [
                "current price", "current rate", "current version", "current law",
                "current score", "current ranking", "in stock", "out of stock",
                "release date", "flight status", "market price", "weather forecast"
            ]
        )
        let categoryFactSignals = category.map {
            matchingPhrases(in: text, phrases: currentFactPhrases(for: $0))
        } ?? []
        let temporalSignals = Array(
            Set(relativeSignals + currentFactSignals + categoryFactSignals)
        ).sorted()
        let cutoffYear = gregorianCalendar.component(.year, from: knowledgeCutoff)
        let postCutoffYears = detectedYears.filter { $0 > cutoffYear }
        let cutoffLabel = Self.cutoffFormatter.string(from: knowledgeCutoff)

        if let signal = (relativeSignals + currentFactSignals + categoryFactSignals).first,
           let matchingLine = firstLine(containing: signal, in: evidenceLines) {
            return assessment(
                status: .currentInformationRequested,
                analyzedAt: analyzedAt,
                detectedYears: detectedYears,
                signals: temporalSignals,
                requiresSearch: true,
                confidence: 0.97,
                trigger: TemporalFreshnessTrigger(
                    rule: categoryFactSignals.contains(signal)
                        ? "category_current_fact"
                        : "explicit_current_request",
                    signal: signal,
                    matchingLine: matchingLine
                ),
                reason: "The visible content explicitly requests information that can change: \(signal)."
            )
        }

        if let latestYear = postCutoffYears.max(),
           let matchingLine = firstLine(containingYear: latestYear, in: evidenceLines) {
            let freshnessSensitive = category.map(isFreshnessSensitiveCategory) ?? false
            return assessment(
                status: .outsideKnowledgeWindow,
                analyzedAt: analyzedAt,
                detectedYears: detectedYears,
                signals: temporalSignals,
                requiresSearch: freshnessSensitive,
                confidence: freshnessSensitive ? 0.94 : 0.84,
                trigger: TemporalFreshnessTrigger(
                    rule: "post_cutoff_year",
                    signal: String(latestYear),
                    matchingLine: matchingLine
                ),
                reason: freshnessSensitive
                    ? "The visible \(category?.rawValue ?? "unknown") content references \(latestYear), after the local knowledge window ending \(cutoffLabel)."
                    : "The content references \(latestYear), but its classified activity does not inherently require current factual retrieval."
            )
        }

        if !detectedYears.isEmpty {
            return assessment(
                status: .withinKnowledgeWindow,
                analyzedAt: analyzedAt,
                detectedYears: detectedYears,
                signals: [],
                requiresSearch: false,
                confidence: 0.94,
                trigger: nil,
                reason: "The latest detected year is within Qwen's configured knowledge window ending \(cutoffLabel)."
            )
        }

        return assessment(
            status: .stable,
            analyzedAt: analyzedAt,
            detectedYears: [],
            signals: [],
            requiresSearch: false,
            confidence: 0.82,
            trigger: nil,
            reason: "No post-cutoff date or request for current information was detected."
        )
    }

    private var gregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func assessment(
        status: TemporalFreshnessStatus,
        analyzedAt: Date,
        detectedYears: [Int],
        signals: [String],
        requiresSearch: Bool,
        confidence: Double,
        trigger: TemporalFreshnessTrigger?,
        reason: String
    ) -> TemporalFreshnessAssessment {
        TemporalFreshnessAssessment(
            status: status,
            knowledgeCutoff: knowledgeCutoff,
            analyzedAt: analyzedAt,
            detectedYears: detectedYears,
            temporalSignals: signals,
            trigger: trigger,
            requiresLiveWebSearch: requiresSearch,
            confidence: confidence,
            reason: reason
        )
    }

    private func years(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(20\d{2})(?!\d)"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Array(Set(regex.matches(in: text, range: range).compactMap { match in
            guard let yearRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[yearRange])
        })).sorted()
    }

    private func matchingPhrases(in text: String, phrases: [String]) -> [String] {
        phrases.filter { containsPhrase($0, in: text) }
    }

    private func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.lowercased())
        let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func isBoilerplateDateLine(_ rawText: String) -> Bool {
        let text = rawText.lowercased()
        return text.contains("copyright") || text.contains("all rights reserved") || text.contains("©")
    }

    private func currentFactPhrases(for category: IntentCategory) -> [String] {
        switch category {
        case .finance:
            return ["live market price", "current interest rate", "current exchange rate", "latest earnings"]
        case .governmentLegal:
            return ["current law", "current regulation", "latest court ruling", "current visa rule"]
        case .sportsFitness:
            return ["live score", "current standings", "latest lineup", "current injury report"]
        case .travel:
            return ["live availability", "current fare", "flight status", "weather forecast", "travel advisory"]
        case .shopping:
            return ["current price", "in stock", "out of stock", "available now", "just released"]
        case .careers:
            return ["current job opening", "open vacancy", "currently hiring", "current salary range"]
        case .health:
            return ["current outbreak", "active recall", "latest guideline", "current advisory"]
        case .news:
            return ["breaking news", "live updates", "latest developments"]
        default:
            return []
        }
    }

    private func isFreshnessSensitiveCategory(_ category: IntentCategory) -> Bool {
        switch category {
        case .shopping, .travel, .news, .finance, .health, .realEstate,
             .careers, .governmentLegal, .sportsFitness:
            return true
        case .learning, .coding, .productivity, .entertainment, .food, .social, .other:
            return false
        }
    }

    private func firstLine(containing phrase: String, in lines: [String]) -> String? {
        lines.first { containsPhrase(phrase, in: $0.lowercased()) }
    }

    private func firstLine(containingYear year: Int, in lines: [String]) -> String? {
        lines.first { years(in: $0).contains(year) }
    }

    private static let cutoffFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
