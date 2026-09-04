import Foundation

/// Shared guardrails for keeping buttons, navigation, and page metadata out of
/// extracted content entities. OCR frequently removes whitespace from controls
/// (for example, "ADD TO BAG" becomes "ADDTOBAG"), so comparisons deliberately
/// use a compact alphanumeric key.
struct ContentPhrasePolicy {
    private static let actionKeys: Set<String> = [
        "addtobag", "addtocart", "addtobasket", "applycoupon", "applyfilter",
        "booknow", "buynow", "checkout", "checkin", "checkoutnow", "choosecolor",
        "choosesize", "clearall", "continue", "continueshopping", "create", "debug",
        "deploy", "download", "export", "filter", "gotocart", "import", "install",
        "learnmore", "loadmore", "new", "open", "pause", "play", "publish",
        "readmore", "remove", "run", "save", "search", "selectcolor", "selectsize",
        "send", "share", "shopnow", "showmore", "signin", "signup", "sortby",
        "submit", "upload", "viewbag", "viewcart", "wishlist"
    ]

    private static let chromeKeys: Set<String> = [
        "about", "account", "back", "bag", "bestoffers", "cart", "categories",
        "colors", "colours", "contact", "customerratings", "customerreviews",
        "delivery", "deliveryoptions", "details", "expertopinion", "faq", "features",
        "freeshipping", "help", "home", "images", "inclusiveofalltaxes",
        "login", "menu", "more", "mrp", "navigation", "offers", "overview",
        "paymentoptions", "privacy", "productdetails", "profile", "ratings",
        "recommended", "reviews", "searchresults", "settings", "shipping",
        "similarproducts", "similarsportsbikes", "sizechart", "specifications",
        "terms", "termsofuse", "videos", "viewdetails"
    ]

    static func compactKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func isInterfaceAction(_ text: String) -> Bool {
        let key = compactKey(text)
        guard !key.isEmpty else { return false }
        if actionKeys.contains(key) { return true }

        // A control and a numeric price/count are sometimes returned as one OCR
        // line. Limit fuzzy matching to numeric residue so a heading such as
        // "Checkout strategies" remains real content.
        return actionKeys.contains { action in
            if key.hasPrefix(action) {
                return isControlResidue(key.dropFirst(action.count))
            }
            if key.hasSuffix(action) {
                return isControlResidue(key.dropLast(action.count))
            }
            return false
        }
    }

    private static func isControlResidue(_ residue: Substring) -> Bool {
        let letters = String(residue.filter(\.isLetter))
        return letters.isEmpty || ["item", "items", "mrp", "only"].contains(letters)
    }

    static func isInterfaceChrome(_ text: String) -> Bool {
        let key = compactKey(text)
        return isInterfaceAction(text) || chromeKeys.contains(key)
    }

    /// Vision occasionally joins a toolbar glyph with its nearby label, such as
    /// reading a magnifying-glass icon plus "Search" as "Qv Search". Treat a
    /// one- or two-character decoration around a known chrome label as chrome,
    /// without fuzzy-matching real words such as "research".
    static func isDecoratedInterfaceChrome(_ text: String) -> Bool {
        let tokens = words(in: text)
        guard tokens.count >= 2 else { return false }

        if let last = tokens.last,
           (actionKeys.contains(last) || chromeKeys.contains(last)),
           tokens.dropLast().allSatisfy({ $0.count <= 2 || $0.allSatisfy(\.isNumber) }) {
            return true
        }
        if let first = tokens.first,
           (actionKeys.contains(first) || chromeKeys.contains(first)),
           tokens.dropFirst().allSatisfy({ $0.count <= 2 || $0.allSatisfy(\.isNumber) }) {
            return true
        }
        return false
    }

    static func isViableEntity(_ text: String) -> Bool {
        let cleanedWords = words(in: text)
        let letterCount = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard !isInterfaceChrome(text),
              !isLikelyBodyText(text),
              letterCount >= 3,
              !cleanedWords.isEmpty,
              cleanedWords.count <= 16,
              text.count <= 140,
              !text.contains("@"),
              !text.localizedCaseInsensitiveContains("http://"),
              !text.localizedCaseInsensitiveContains("https://")
        else { return false }
        return true
    }

    /// Returns the content-bearing part of a native window title while
    /// removing browser and site suffixes such as "Product - Amazon - Safari".
    static func contentFromWindowTitle(
        _ title: String?,
        websites: [String] = []
    ) -> String? {
        guard let title else { return nil }

        var excludedLabels: Set<String> = [
            "safari", "safari technology preview", "google chrome", "chrome",
            "firefox", "microsoft edge"
        ]
        for website in websites {
            let host = website
                .lowercased()
                .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
            var labels = host.split(separator: ".").map(String.init)
            while labels.count >= 2 {
                excludedLabels.insert(labels.joined(separator: "."))
                if let firstLabel = labels.first,
                   !["m", "mobile", "www"].contains(firstLabel) {
                    excludedLabels.insert(firstLabel)
                }
                labels.removeFirst()
            }
        }

        let components = title
            .components(separatedBy: CharacterSet(charactersIn: "|—–"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            .filter { component in
                let lower = component.lowercased()
                return isViableEntity(component) &&
                    !isLikelyBodyText(component) &&
                    !excludedLabels.contains(lower)
            }
        return components.max { $0.count < $1.count }
    }

    /// Detects source-document filenames that should not become the subject of
    /// a prompt when a more local section heading is visible on screen.
    static func isLikelyDocumentFilename(_ text: String, windowTitle: String? = nil) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        let hasDocumentExtension = value.range(
            of: #"\.(?:pdf|epub|docx?|pptx?|rtf|txt|md|tex)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if hasDocumentExtension { return true }

        let separatorCount = value.filter { $0 == "_" }.count
        let hasDateOrBuildSequence = value.range(
            of: #"\b\d{1,4}(?:[_-]\d{1,4}){2,}\b"#,
            options: .regularExpression
        ) != nil
        let hasFileVersionSuffix = value.range(
            of: #"(?:^|[\s_-])(?:copy|draft|final|edited|revised|v\d+)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let valueKey = compactKey(value)
        let windowKey = compactKey(windowTitle ?? "")
        let matchesWindowTitle = !valueKey.isEmpty &&
            !windowKey.isEmpty &&
            (valueKey == windowKey || windowKey.contains(valueKey))

        return (separatorCount >= 2 && (hasDateOrBuildSequence || hasFileVersionSuffix || matchesWindowTitle)) ||
            (matchesWindowTitle && (hasDateOrBuildSequence || hasFileVersionSuffix))
    }

    static func isNumberedHeading(_ text: String) -> Bool {
        let numberFirst = #"^\s*\(?\d+(?:\.\d+){0,4}\)?[.)]?(?:\s+\p{L}.*)?\s*$"#
        let labeledNumber = #"^\s*(?:chapter|section|part|problem|figure|table|appendix|exercise|example)\s+\d+(?:\.\d+){0,4}(?:\s*[:.\-–—]\s*.*)?\s*$"#
        return text.range(of: numberFirst, options: [.regularExpression, .caseInsensitive]) != nil ||
            text.range(of: labeledNumber, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func titleWithoutNumbering(_ text: String) -> String? {
        let prefix = #"^\s*(?:(?:chapter|section|part|problem|figure|table|appendix|exercise|example)\s+)?\(?\d+(?:\.\d+){0,4}\)?[.)]?\s*[:\-–—]?\s*"#
        let cleaned = text
            .replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let letterCount = cleaned.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 3 ? cleaned : nil
    }

    static func contextPrecedence(for text: String, category: SalienceCategory) -> Int {
        if category == .subheading && titleWithoutNumbering(text) == nil {
            return 45
        }
        return category.contextPrecedence
    }

    static func contextRole(for text: String, category: SalienceCategory) -> String {
        if category == .subheading && titleWithoutNumbering(text) == nil {
            return "structural_marker"
        }
        return category.contextRole
    }

    static func isLikelyBodyText(_ text: String) -> Bool {
        let phraseWords = words(in: text)
        guard phraseWords.count >= 7, !isTitleLike(text) else { return false }

        let proseWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "because", "by", "for",
            "from", "has", "have", "in", "is", "it", "of", "on", "or", "that",
            "the", "their", "this", "to", "was", "were", "which", "with"
        ]
        let proseWordCount = phraseWords.filter(proseWords.contains).count
        let hasSentencePunctuation = text.rangeOfCharacter(from: CharacterSet(charactersIn: ".,;:")) != nil
        return phraseWords.count >= 11 ||
            (phraseWords.count >= 8 && proseWordCount >= 2) ||
            (hasSentencePunctuation && proseWordCount >= 2)
    }

    private static func isTitleLike(_ text: String) -> Bool {
        let titleWords = text.split(separator: " ").filter {
            $0.rangeOfCharacter(from: .letters) != nil
        }
        guard titleWords.count >= 2 else { return false }
        let capitalized = titleWords.filter { $0.first?.isUppercase == true }.count
        return Double(capitalized) / Double(titleWords.count) >= 0.6
    }
}

/// Removes model-internal reasoning markers before text reaches normal UI.
/// Raw model payloads remain available to Developer UI diagnostics.
struct QwenVisibleOutputSanitizer {
    static func sanitize(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        for tag in ["think", "analysis", "reasoning"] {
            value = removingTaggedBlocks(tag, from: value)
        }
        value = removingLeadingReasoningSection(from: value)
        value = removingMetaDescriptionParagraphs(from: value)
        value = value.replacingOccurrences(
            of: #"^\s*(?:final\s+answer|answer|response)\s*:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsMetaNarration(_ input: String) -> Bool {
        let value = input.lowercased()
        let markers = [
            "this response provides", "this answer provides", "this explanation provides",
            "this response explains", "this answer explains", "this explanation explains",
            "the response focuses", "the answer focuses", "the explanation focuses",
            "the response emphasizes", "the answer emphasizes", "the explanation emphasizes",
            "this response will", "this answer will", "the following response",
            "without listing techniques", "without recommendations or lists",
            "we are given a user query", "we must answer", "let's craft the response",
            "the specialist profile is", "the instructions say"
        ]
        return markers.contains(where: value.contains)
    }

    private static func removingTaggedBlocks(_ tag: String, from input: String) -> String {
        var value = input
        let closedPattern = "(?is)<\\s*\(tag)\\b[^>]*>.*?<\\s*/\\s*\(tag)\\s*>"
        value = value.replacingOccurrences(
            of: closedPattern,
            with: "",
            options: .regularExpression
        )

        let opening = "<\(tag)"
        if let range = value.range(of: opening, options: .caseInsensitive) {
            // An unclosed reasoning block is safer to suppress than to expose.
            value = String(value[..<range.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingLeadingReasoningSection(from input: String) -> String {
        let lines = input.components(separatedBy: .newlines)
        guard let firstIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return "" }

        let first = normalizedHeading(lines[firstIndex])
        let reasoningHeadings: Set<String> = [
            "thinking", "reasoning", "analysis", "chain of thought", "internal reasoning"
        ]
        let reasoningPreambles = [
            "we need to ", "i need to ", "the user asks ", "the user wants ",
            "first, i need to ", "first i need to ", "first, we need to ",
            "first we need to ", "let's analyze", "let us analyze", "let me analyze",
            "let's think", "let us think", "we are given ", "we must ",
            "the task is to ", "the user is asking ", "the specialist profile ",
            "the instructions say ", "important:"
        ]
        let beginsWithReasoning = reasoningHeadings.contains(first) ||
            reasoningPreambles.contains(where: first.lowercased().hasPrefix)
        guard beginsWithReasoning else { return input }

        let answerHeadings: Set<String> = [
            "answer", "final answer", "response", "final response", "polished answer"
        ]
        if let answerIndex = lines.indices.dropFirst(firstIndex + 1).first(where: {
            answerHeadings.contains(normalizedHeading(lines[$0]))
        }) {
            return lines.dropFirst(answerIndex + 1).joined(separator: "\n")
        }

        return ""
    }

    private static func removingMetaDescriptionParagraphs(from input: String) -> String {
        input.components(separatedBy: "\n\n")
            .filter { !containsMetaNarration($0) }
            .joined(separator: "\n\n")
    }

    private static func normalizedHeading(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: #"^\s*#{1,6}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
