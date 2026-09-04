import Foundation

enum SiriCommandResolution: Equatable {
    case analyzeScreen
    case expandPrompt(PromptSummarySelection, resultLimit: Int)
    case chat(String)
}

enum SiriCommandInterpreter {
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12
    ]

    static func resolve(
        request rawRequest: String,
        prompts: [IntentPromptSuggestion],
        pathsPerPrompt: Int = .max
    ) -> SiriCommandResolution {
        let request = commandNormalized(rawRequest)
        if isAnalyzeCommand(request) {
            return .analyzeScreen
        }

        let paths = prompts.flatMap { prompt in
            prompt.searchOptions.prefix(max(0, pathsPerPrompt)).map { option in
                PromptSummarySelection(prompt: prompt, option: option)
            }
        }
        if let explicitIndex = explicitPathIndex(in: request),
           paths.indices.contains(explicitIndex - 1) {
            return .expandPrompt(
                paths[explicitIndex - 1],
                resultLimit: requestedResultLimit(in: request)
            )
        }

        if let semanticMatch = bestSemanticPath(for: request, paths: paths) {
            return .expandPrompt(
                semanticMatch,
                resultLimit: requestedResultLimit(in: request)
            )
        }

        return .chat(rawRequest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func pathIdentifier(for zeroBasedIndex: Int) -> String {
        let number = zeroBasedIndex + 1
        let scalarValue = UInt32(65 + zeroBasedIndex)
        let letter = UnicodeScalar(scalarValue).map(String.init) ?? "?"
        return "\(number) / \(letter)"
    }

    private static func isAnalyzeCommand(_ request: String) -> Bool {
        let variants = [
            "analyze my screen", "analyse my screen", "analyze the screen",
            "analyse the screen", "analyze this screen", "analyse this screen",
            "analyze screen", "analyse screen"
        ]
        return variants.contains(request)
    }

    private static func explicitPathIndex(in request: String) -> Int? {
        let pattern = #"^(?:show|open|expand|select)(?: me)?(?: option| prompt| choice| path)?(?: number)? ([a-l]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[1-9]|1[0-2])$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: request,
                range: NSRange(request.startIndex..<request.endIndex, in: request)
              ),
              let valueRange = Range(match.range(at: 1), in: request)
        else { return nil }
        let value = String(request[valueRange])
        if let number = Int(value) { return number }
        if let number = numberWords[value] { return number }
        guard let scalar = value.unicodeScalars.first else { return nil }
        return Int(scalar.value - 97) + 1
    }

    private static func requestedResultLimit(in request: String) -> Int {
        let pattern = #"\btop (one|two|three|four|five|six|seven|eight|nine|ten|[0-9]{1,2})\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: request,
                range: NSRange(request.startIndex..<request.endIndex, in: request)
              ),
              let valueRange = Range(match.range(at: 1), in: request)
        else { return 8 }
        let rawValue = String(request[valueRange])
        guard let value = Int(rawValue) ?? numberWords[rawValue] else { return 8 }
        return max(1, min(value, 10))
    }

    private static func bestSemanticPath(
        for request: String,
        paths: [PromptSummarySelection]
    ) -> PromptSummarySelection? {
        let stopWords: Set<String> = [
            "show", "open", "expand", "select", "tell", "give", "find", "me",
            "the", "a", "an", "about", "related", "recommended", "top", "please",
            "result", "results", "option", "prompt", "choice", "path"
        ]
        let requestTokens = Set(tokens(in: request).filter {
            !stopWords.contains($0) && Int($0) == nil
        })
        guard !requestTokens.isEmpty else { return nil }

        let ranked = paths.enumerated().map { index, selection -> (Int, Int, PromptSummarySelection) in
            let action = selection.prompt.action.rawValue.replacingOccurrences(of: "_", with: " ")
            let haystack = [
                selection.prompt.text,
                selection.option.title,
                selection.option.query,
                action
            ].joined(separator: " ")
            let candidateTokens = Set(tokens(in: haystack))
            var score = requestTokens.reduce(0) { partial, token in
                let exact = candidateTokens.contains(token)
                let singular = token.count > 3 && token.hasSuffix("s") &&
                    candidateTokens.contains(String(token.dropLast()))
                let plural = candidateTokens.contains(token + "s")
                return partial + ((exact || singular || plural) ? 3 : 0)
            }
            if requestTokens.contains("restaurant") || requestTokens.contains("restaurants") || requestTokens.contains("dining") {
                score += selection.prompt.action == .discoverRestaurants ? 8 : 0
            }
            return (score, -index, selection)
        }.sorted { left, right in
            if left.0 != right.0 { return left.0 > right.0 }
            return left.1 > right.1
        }
        guard let best = ranked.first, best.0 > 0 else { return nil }
        return best.2
    }

    private static func tokens(in value: String) -> [String] {
        normalized(value).split(separator: " ").map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Siri may retain the infinitive marker when resolving phrases such as
    /// “Ask Theia to show one.” It is meaningful for chat, so strip it only
    /// when the remainder is one of Theia's known screen or prompt commands.
    private static func commandNormalized(_ value: String) -> String {
        let request = normalized(value)
        guard request.hasPrefix("to ") else { return request }
        let candidate = String(request.dropFirst(3))
        if isAnalyzeCommand(candidate) ||
            candidate.hasPrefix("show ") ||
            candidate.hasPrefix("open ") ||
            candidate.hasPrefix("expand ") ||
            candidate.hasPrefix("select ") {
            return candidate
        }
        return request
    }
}
