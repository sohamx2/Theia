import Foundation
import NaturalLanguage

struct ContextAnalysisService {
    private let temporalFreshnessService = TemporalFreshnessService()

    private struct Candidate {
        let line: OCRTextLine
        let text: String
        let score: Double
        let reasons: [String]
        let category: SalienceCategory
    }

    private struct NamedEntities {
        let places: [String]
        let organizations: [String]
    }

    /// A geometry-derived approximation of the area a person is actively
    /// reading. It is inferred from substantial prose lines rather than from an
    /// app name, so it works for documents, articles, product pages, and editors.
    private struct ReadingRegion {
        let xMin: Double
        let xMax: Double
        let yMin: Double
        let yMax: Double

        func contains(_ box: NormalizedBoundingBox, margin: Double = 0) -> Bool {
            box.centerX >= xMin - margin && box.centerX <= xMax + margin &&
                box.centerY >= yMin - margin && box.centerY <= yMax + margin
        }
    }

    private let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "by", "for", "from",
        "has", "have", "he", "her", "his", "i", "in", "is", "it", "its", "me",
        "my", "of", "on", "or", "our", "she", "that", "the", "their", "them",
        "they", "this", "to", "was", "we", "were", "will", "with", "you", "your"
    ]

    private let navigationJunk: Set<String> = [
        "about", "account", "back", "contact", "faq", "help", "home", "log in",
        "login", "menu", "more", "next", "privacy", "profile", "search", "settings",
        "sign in", "sign up", "terms", "terms of use"
    ]

    private let knownBrandsAndSites = [
        "Myntra", "Amazon", "Flipkart", "Booking.com", "Airbnb", "Expedia",
        "MakeMyTrip", "Google Flights", "GitHub", "Stack Overflow", "Coursera",
        "Udemy", "YouTube", "Netflix", "Spotify", "Notion", "Slack"
    ]

    func analyze(
        _ document: OCRDocument,
        sourceContext: ScreenSourceContext,
        intentClassifier: IntentClassificationService,
        onClassificationProgress: ClassificationProgressHandler? = nil
    ) async -> ScreenContextReport {
        let normalizedLines = document.lines.compactMap { line -> OCRTextLine? in
            let text = normalize(line.text)
            guard !text.isEmpty else { return nil }
            return OCRTextLine(
                text: text,
                confidence: line.confidence,
                boundingBox: line.boundingBox
            )
        }

        // Vision may return a section number and its title as separate boxes.
        // Join those boxes before any filtering so "6.4" + "Adam" becomes the
        // semantic heading a person sees: "6.4 Adam".
        let readingLines = mergeNumberedHeadings(in: normalizedLines)
        let medianHeight = median(readingLines.map { $0.boundingBox.height })
        let repetitionCounts = Dictionary(
            readingLines.map { ($0.text.lowercased(), 1) },
            uniquingKeysWith: +
        )

        let segmentedLines = readingLines.flatMap { line in
            segments(from: line.text).map {
                OCRTextLine(text: $0, confidence: line.confidence, boundingBox: line.boundingBox)
            }
        }

        let readingRegion = inferReadingRegion(
            from: segmentedLines,
            medianHeight: medianHeight
        )

        let cleanedLines = segmentedLines.filter {
            !shouldDiscard(
                $0,
                repetitionCount: repetitionCounts[$0.text.lowercased(), default: 1],
                medianHeight: medianHeight,
                readingRegion: readingRegion,
                sourceContext: sourceContext
            )
        }
        let termFrequencies = tokenFrequencies(in: cleanedLines.map(\.text))

        let scoredCandidates = cleanedLines.map {
            score(
                $0,
                medianHeight: medianHeight,
                termFrequencies: termFrequencies,
                readingRegion: readingRegion,
                sourceContext: sourceContext
            )
        }
        .sorted { $0.score > $1.score }

        // A new section title barely peeking in at the bottom is not yet the
        // user's active context. Keep it once supporting content below it is
        // visible. This is category-aware, so a useful corner button/action is
        // not discarded simply because it sits near an edge.
        let candidates = scoredCandidates.filter {
            !isOrphanedBottomHeading($0, among: scoredCandidates)
        }

        var seen = Set<String>()
        let uniqueCandidates = candidates.filter {
            seen.insert($0.text.lowercased()).inserted
        }
        let thresholded = uniqueCandidates.filter { $0.score >= 0.3 }
        let rankedCandidates = thresholded.isEmpty ? uniqueCandidates : thresholded
        var bodyTextCount = 0
        let structurallyBalancedCandidates = rankedCandidates.filter { candidate in
            guard candidate.category == .bodyText else { return true }
            bodyTextCount += 1
            return bodyTextCount <= 10
        }
        let reducedCandidates = Array(structurallyBalancedCandidates.prefix(24))
            .sorted(by: humanReadingOrder)

        let preliminaryImportantText = reducedCandidates.map(makeSalientText)
        // Website evidence comes exclusively from the active browser URL captured
        // before OCR. Domains visible in tabs, ads, footers, and page copy remain
        // text context but can never influence known-site rules or website memory.
        let enrichedSourceContext = sourceContext
        let classificationOutcome = await intentClassifier.classify(
            importantText: preliminaryImportantText,
            sourceContext: enrichedSourceContext,
            progress: onClassificationProgress
        )
        let classifiedIntent = classificationOutcome.classification
        let reducedText = preliminaryImportantText.map(\.text).joined(separator: "\n")
        let namedEntities = extractNamedEntities(from: reducedText)

        let importantText = preliminaryImportantText.map {
            recategorize($0, namedEntities: namedEntities)
        }
        let entities = extractEntities(
            from: importantText,
            intent: classifiedIntent.category,
            namedEntities: namedEntities,
            sourceContext: enrichedSourceContext
        )
        let intent = intentWithGroundedSubject(
            classifiedIntent,
            importantText: importantText,
            // Subject grounding needs the full active frame because the title can
            // sit above the inferred reading region. It is only accepted when it
            // agrees with the active window title, so neighboring tab labels do
            // not become subjects.
            visibleText: readingLines.map(\.text),
            entities: entities,
            sourceContext: enrichedSourceContext
        )
        var temporalText = cleanedLines.map(\.text) + importantText.map(\.text)
        if let subject = intent.identifiedSubject { temporalText.append(subject) }
        if let title = enrichedSourceContext.windowTitle { temporalText.append(title) }
        let temporalFreshness = temporalFreshnessService.assess(
            text: temporalText,
            category: intent.category
        )

        return ScreenContextReport(
            schemaVersion: "5.1",
            generatedAt: Date(),
            sourceContext: enrichedSourceContext,
            intent: intent,
            importantText: importantText,
            entities: entities,
            categories: makeCategories(from: importantText, entities: entities),
            cleanedSegments: cleanedLines.map(\.text),
            statistics: AnalysisStatistics(
                ocrLineCount: document.lines.count,
                cleanedSegmentCount: cleanedLines.count,
                importantTextCount: importantText.count,
                discardedLineCount: max(0, segmentedLines.count - cleanedLines.count)
            ),
            promptGeneration: classificationOutcome.promptGeneration,
            temporalFreshness: temporalFreshness
        )
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func segments(from text: String) -> [String] {
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: "|•·"))
            .map(normalize)
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [text] : pieces
    }

    private func mergeNumberedHeadings(in lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count >= 2 else { return lines }
        let ordered = readingOrder(lines)
        var consumed = Set<Int>()
        var merged: [OCRTextLine] = []

        for index in ordered.indices where !consumed.contains(index) {
            let marker = ordered[index]
            guard isStandaloneSectionMarker(marker.text) else {
                merged.append(marker)
                continue
            }

            let markerBox = marker.boundingBox
            let minimumTitleHeight = markerBox.height * 0.55
            let maximumTitleHeight = markerBox.height * 1.8
            var rightEdge = markerBox.x + markerBox.width
            var titleParts: [(Int, OCRTextLine)] = []
            var totalWords = 0

            let rowCandidates = ordered.indices
                .filter { candidateIndex in
                    guard candidateIndex != index,
                          !consumed.contains(candidateIndex)
                    else { return false }
                    let candidate = ordered[candidateIndex]
                    let candidateBox = candidate.boundingBox
                    let rowTolerance = max(markerBox.height, candidateBox.height) * 0.62
                    return candidateBox.x >= markerBox.x + markerBox.width - 0.008 &&
                        abs(candidateBox.centerY - markerBox.centerY) <= rowTolerance &&
                        candidateBox.height >= minimumTitleHeight &&
                        candidateBox.height <= maximumTitleHeight &&
                        isHeadingTitleFragment(candidate.text)
                }
                .sorted { ordered[$0].boundingBox.x < ordered[$1].boundingBox.x }

            for candidateIndex in rowCandidates {
                let candidate = ordered[candidateIndex]
                let gap = candidate.boundingBox.x - rightEdge
                let allowedGap = max(0.055, markerBox.height * 4.5)
                let candidateWords = tokens(in: candidate.text).count
                guard gap >= -0.008,
                      gap <= allowedGap,
                      totalWords + candidateWords <= 14
                else {
                    if !titleParts.isEmpty { break }
                    continue
                }

                titleParts.append((candidateIndex, candidate))
                totalWords += candidateWords
                rightEdge = candidate.boundingBox.x + candidate.boundingBox.width
            }

            guard !titleParts.isEmpty else {
                merged.append(marker)
                continue
            }

            consumed.insert(index)
            titleParts.forEach { consumed.insert($0.0) }
            let components = [marker] + titleParts.map(\.1)
            let xMin = components.map { $0.boundingBox.x }.min() ?? markerBox.x
            let yMin = components.map { $0.boundingBox.y }.min() ?? markerBox.y
            let xMax = components.map { $0.boundingBox.x + $0.boundingBox.width }.max()
                ?? markerBox.x + markerBox.width
            let yMax = components.map { $0.boundingBox.y + $0.boundingBox.height }.max()
                ?? markerBox.y + markerBox.height
            let totalWidth = components.reduce(0) { $0 + max($1.boundingBox.width, 0.001) }
            let confidence = components.reduce(0) {
                $0 + ($1.confidence * max($1.boundingBox.width, 0.001))
            } / totalWidth

            merged.append(
                OCRTextLine(
                    text: components.map(\.text).joined(separator: " "),
                    confidence: confidence,
                    boundingBox: NormalizedBoundingBox(
                        x: xMin,
                        y: yMin,
                        width: xMax - xMin,
                        height: yMax - yMin
                    )
                )
            )
        }

        return readingOrder(merged)
    }

    private func readingOrder(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        lines.sorted { left, right in
            let rowTolerance = max(left.boundingBox.height, right.boundingBox.height) * 0.5
            if abs(left.boundingBox.centerY - right.boundingBox.centerY) > rowTolerance {
                return left.boundingBox.centerY > right.boundingBox.centerY
            }
            return left.boundingBox.x < right.boundingBox.x
        }
    }

    private func isStandaloneSectionMarker(_ text: String) -> Bool {
        text.range(
            of: #"^\s*\d+(?:\.\d+){1,4}[.)]?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private func isHeadingTitleFragment(_ text: String) -> Bool {
        let letterCount = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        let wordCount = tokens(in: text).count
        return letterCount >= 2 &&
            wordCount <= 12 &&
            !ContentPhrasePolicy.isLikelyBodyText(text) &&
            !ContentPhrasePolicy.isInterfaceChrome(text) &&
            !ContentPhrasePolicy.isDecoratedInterfaceChrome(text)
    }

    private func inferReadingRegion(
        from lines: [OCRTextLine],
        medianHeight: Double
    ) -> ReadingRegion? {
        let safeMedianHeight = max(0.001, medianHeight)
        let proseLines = lines.filter { line in
            let letterCount = line.text.unicodeScalars.filter(CharacterSet.letters.contains).count
            return line.confidence >= 0.45 &&
                letterCount >= 18 &&
                line.boundingBox.width >= 0.11 &&
                line.boundingBox.height >= safeMedianHeight * 0.65 &&
                (ContentPhrasePolicy.isLikelyBodyText(line.text) || tokens(in: line.text).count >= 6)
        }
        guard proseLines.count >= 2 else { return nil }

        // A substantial line near the visual center is the best initial anchor.
        // Tiny OCR from thumbnails has very little area and loses naturally.
        guard let anchor = proseLines.max(by: { readingAnchorScore($0) < readingAnchorScore($1) }) else {
            return nil
        }
        let clustered = proseLines.filter {
            abs($0.boundingBox.centerX - anchor.boundingBox.centerX) <= 0.30
        }
        guard clustered.count >= 2 else { return nil }

        let xMin = max(0, (clustered.map { $0.boundingBox.x }.min() ?? 0) - 0.07)
        let xMax = min(1, (clustered.map { $0.boundingBox.x + $0.boundingBox.width }.max() ?? 1) + 0.07)
        let yMin = max(0, (clustered.map { $0.boundingBox.y }.min() ?? 0) - 0.12)
        let yMax = min(1, (clustered.map { $0.boundingBox.y + $0.boundingBox.height }.max() ?? 1) + 0.14)
        return ReadingRegion(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }

    private func readingAnchorScore(_ line: OCRTextLine) -> Double {
        let box = line.boundingBox
        let area = box.width * box.height
        let centerAffinity = max(0.2, 1 - abs(box.centerX - 0.5))
        return area * centerAffinity * line.confidence
    }

    private func humanReadingOrder(_ left: Candidate, _ right: Candidate) -> Bool {
        let leftPriority = humanCategoryPriority(left.category)
        let rightPriority = humanCategoryPriority(right.category)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }

        if left.category == .bodyText || left.category == .keyword {
            let rowTolerance = max(
                left.line.boundingBox.height,
                right.line.boundingBox.height
            ) * 0.5
            if abs(left.line.boundingBox.centerY - right.line.boundingBox.centerY) > rowTolerance {
                return left.line.boundingBox.centerY > right.line.boundingBox.centerY
            }
            return left.line.boundingBox.x < right.line.boundingBox.x
        }
        return left.score > right.score
    }

    private func humanCategoryPriority(_ category: SalienceCategory) -> Int {
        switch category {
        case .documentTitle: return 0
        case .heading, .subheading: return 1
        case .product, .topic, .place: return 2
        case .date, .price, .size, .brandOrSite: return 3
        case .action: return 4
        case .bodyText: return 5
        case .keyword: return 6
        }
    }

    private func matchesSourceTitle(_ text: String, _ sourceTitle: String?) -> Bool {
        guard let sourceTitle else { return false }
        let candidate = ContentPhrasePolicy.compactKey(text)
        let source = ContentPhrasePolicy.compactKey(sourceTitle)
        guard candidate.count >= 6, source.count >= 6 else { return false }
        if candidate == source { return true }

        let shorterCount = min(candidate.count, source.count)
        let longerCount = max(candidate.count, source.count)
        return Double(shorterCount) / Double(longerCount) >= 0.58 &&
            (candidate.contains(source) || source.contains(candidate))
    }

    private func shouldDiscard(
        _ line: OCRTextLine,
        repetitionCount: Int,
        medianHeight: Double,
        readingRegion: ReadingRegion?,
        sourceContext: ScreenSourceContext
    ) -> Bool {
        let text = line.text
        let lower = text.lowercased()
        let words = tokens(in: text)

        let isSourceTitle = matchesSourceTitle(text, sourceContext.windowTitle)
        let isNumberedTitle = ContentPhrasePolicy.titleWithoutNumbering(text) != nil
        let isProminentAction = ContentPhrasePolicy.isInterfaceAction(text) &&
            line.boundingBox.width >= 0.025 &&
            line.boundingBox.height >= max(0.008, medianHeight * 0.7)

        // The capture includes the native browser toolbar and tab strip. Those
        // labels are crisp, high-confidence OCR, but they are not page content.
        // A person naturally treats this top band as application chrome. Make
        // that spatial boundary explicit instead of trying to enumerate every
        // possible inactive tab title or domain.
        if isBrowserApplication(sourceContext), line.boundingBox.centerY >= 0.875 {
            return true
        }

        if text.count < 2 || navigationJunk.contains(lower) ||
            ContentPhrasePolicy.isDecoratedInterfaceChrome(text) {
            return true
        }
        if line.confidence < 0.35 || (line.confidence < 0.55 && words.count <= 2) {
            return true
        }
        if lower.contains("cookie") || lower.contains("all rights reserved") ||
            lower.contains("privacy policy") || lower.contains("terms and conditions") {
            return true
        }
        if repetitionCount >= 3 && words.count <= 3 && line.boundingBox.height <= medianHeight * 1.15 {
            return true
        }

        let letterCount = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        let isPurePageLikeNumber = text.range(
            of: #"^\s*\d{1,4}\s*$"#,
            options: .regularExpression
        ) != nil
        if !isSourceTitle,
           !isNumberedTitle,
           !isProminentAction,
           line.boundingBox.width <= 0.035,
           line.boundingBox.height <= medianHeight * 1.2,
           (isPurePageLikeNumber || (words.count == 1 && letterCount <= 2)) {
            return true
        }
        if ContentPhrasePolicy.isNumberedHeading(text),
           !isNumberedTitle,
           line.boundingBox.height <= medianHeight * 0.9 {
            return true
        }

        // Tiny labels outside the dominant reading region are normally page
        // thumbnails, toolbar glyphs, counters, or clipped background chrome.
        // Source titles, complete numbered headings, and visually real task
        // buttons are the deliberate exceptions.
        if let readingRegion,
           !readingRegion.contains(line.boundingBox, margin: 0.025),
           words.count <= 2,
           line.boundingBox.height <= medianHeight * 1.2,
           !isSourceTitle,
           !isNumberedTitle,
           !isProminentAction {
            return true
        }


        // Small detached corner content is normally an ad, chat badge, cookie
        // card, thumbnail, or floating overlay. Preserve substantial headings
        // and explicit task controls, but keep these peripheral fragments out
        // of classification and prompt grounding.
        if let readingRegion,
           !readingRegion.contains(line.boundingBox, margin: 0.06),
           isPeripheral(line.boundingBox),
           line.boundingBox.height <= medianHeight * 1.5,
           !isSourceTitle,
           !isNumberedTitle,
           !isProminentAction {
            return true
        }

        let alphanumericCount = text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count
        return alphanumericCount < max(2, text.count / 3)
    }

    private func isBrowserApplication(_ sourceContext: ScreenSourceContext) -> Bool {
        let identity = [sourceContext.applicationName, sourceContext.bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return ["safari", "chrome", "firefox", "edge", "brave", "arc"]
            .contains { identity.contains($0) }
    }

    private func isPeripheral(_ box: NormalizedBoundingBox) -> Bool {
        box.centerX <= 0.16 || box.centerX >= 0.84 || box.centerY <= 0.10
    }

    private func tokenFrequencies(in text: [String]) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        for phrase in text {
            for token in tokens(in: phrase) where !stopwords.contains(token) && token.count > 1 {
                frequencies[token, default: 0] += 1
            }
        }
        return frequencies
    }

    private func score(
        _ line: OCRTextLine,
        medianHeight: Double,
        termFrequencies: [String: Int],
        readingRegion: ReadingRegion?,
        sourceContext: ScreenSourceContext
    ) -> Candidate {
        var score = 0.35 + (line.confidence * 1.25)
        var reasons = ["OCR confidence"]
        let box = line.boundingBox
        let safeMedianHeight = max(medianHeight, 0.001)
        let heightRatio = box.height / safeMedianHeight

        if heightRatio >= 1.3 {
            score += min(1.4, (heightRatio - 1) * 0.9)
            reasons.append("large text or heading")
        }

        let isSourceTitle = matchesSourceTitle(line.text, sourceContext.windowTitle)
        let isInReadingRegion = readingRegion?.contains(box, margin: 0.025) ?? true
        let centerDistance = hypot(box.centerX - 0.5, box.centerY - 0.5)
        if centerDistance < 0.3 {
            score += (0.3 - centerDistance) * 2.2
            reasons.append("near screen center")
        }
        if box.centerY > 0.66 && (isInReadingRegion || isSourceTitle) {
            score += 0.3
            reasons.append("near top of page")
        }
        if isInReadingRegion {
            score += 0.45
            reasons.append("inside primary reading region")
        } else if !isSourceTitle && !ContentPhrasePolicy.isInterfaceAction(line.text) {
            score -= 0.45
            reasons.append("outside primary reading region")
        }

        let meaningfulTokens = tokens(in: line.text).filter { !stopwords.contains($0) }
        let repeatedTerms = meaningfulTokens.filter { termFrequencies[$0, default: 0] > 1 }
        if !repeatedTerms.isEmpty {
            score += min(0.9, Double(Set(repeatedTerms).count) * 0.18)
            reasons.append("contains repeated key terms")
        }

        var category = category(for: line.text, heightRatio: heightRatio)
        if isSourceTitle {
            category = .documentTitle
        }
        switch category {
        case .documentTitle:
            score += 1.05
            reasons.append("matches the active document title")
        case .price, .date, .place, .product, .topic, .brandOrSite:
            score += 0.8
            reasons.append("matches a structured entity")
        case .heading, .subheading:
            if category == .subheading && ContentPhrasePolicy.titleWithoutNumbering(line.text) == nil {
                score += 0.05
                reasons.append("standalone structural number")
            } else {
                score += 0.85
                reasons.append(category == .heading ? "heading-like phrase" : "numbered heading or subheading")
            }
        case .action:
            score += 0.45
            reasons.append("task-related action")
        case .size:
            score += 0.5
            reasons.append("product size")
        case .keyword:
            break
        case .bodyText:
            score -= 0.45
            reasons.append("supporting body prose")
        }

        if meaningfulTokens.count >= 2 && meaningfulTokens.count <= 12 {
            score += 0.25
            reasons.append("compact descriptive phrase")
        } else if meaningfulTokens.count > 24 {
            score -= 0.35
        }

        var normalizedScore = min(1, max(0, score / 4.8))
        if category == .bodyText {
            normalizedScore = min(normalizedScore, 0.64)
        }

        return Candidate(
            line: line,
            text: line.text,
            score: normalizedScore,
            reasons: reasons,
            category: category
        )
    }

    private func category(for text: String, heightRatio: Double) -> SalienceCategory {
        let lower = text.lowercased()

        if !matches(in: text, pattern: pricePattern).isEmpty { return .price }
        if !matches(in: text, pattern: datePattern).isEmpty { return .date }
        if !matches(in: text, pattern: sizePattern).isEmpty { return .size }
        if knownBrandsAndSites.contains(where: { lower.contains($0.lowercased()) }) {
            return .brandOrSite
        }
        if ContentPhrasePolicy.isInterfaceAction(text) {
            return .action
        }
        if ContentPhrasePolicy.isNumberedHeading(text) {
            return .subheading
        }
        if ContentPhrasePolicy.isLikelyBodyText(text) {
            return .bodyText
        }
        if containsAny(lower, ["chapter", "neural network", "algorithm", "tutorial", "lesson", "introduction", "overview"]) {
            return .topic
        }
        if containsAny(lower, ["hotel", "airport", "destination", "city", "flight to", "things to do in"]) {
            return .place
        }
        if heightRatio >= 1.3 || (isTitleLike(text) && tokens(in: text).count <= 12) {
            return .heading
        }
        return .keyword
    }

    private func makeSalientText(_ candidate: Candidate) -> SalientText {
        SalientText(
            text: candidate.text,
            category: candidate.category,
            salienceScore: rounded(candidate.score),
            ocrConfidence: rounded(candidate.line.confidence),
            reasons: candidate.reasons,
            boundingBox: candidate.line.boundingBox
        )
    }

    private func recategorize(
        _ item: SalientText,
        namedEntities: NamedEntities
    ) -> SalientText {
        var category = item.category
        if ContentPhrasePolicy.isInterfaceAction(item.text) {
            category = .action
        } else if category == .keyword && ContentPhrasePolicy.isViableEntity(item.text) {
            if namedEntities.places.contains(where: { primarilyRepresents(item.text, entity: $0) }) {
                category = .place
            } else if namedEntities.organizations.contains(where: { primarilyRepresents(item.text, entity: $0) }) {
                category = .brandOrSite
            }
        }

        return SalientText(
            text: item.text,
            category: category,
            salienceScore: item.salienceScore,
            ocrConfidence: item.ocrConfidence,
            reasons: item.reasons,
            boundingBox: item.boundingBox
        )
    }

    private func extractEntities(
        from importantText: [SalientText],
        intent: IntentCategory,
        namedEntities: NamedEntities,
        sourceContext: ScreenSourceContext
    ) -> ExtractedEntities {
        let text = importantText.map(\.text).joined(separator: "\n")
        var brands = namedEntities.organizations
        brands.append(contentsOf: knownBrandsAndSites.filter {
            text.localizedCaseInsensitiveContains($0)
        })

        var products = intent == .shopping
            ? rankedShoppingProductCandidates(
                in: importantText,
                sourceContext: sourceContext
            ).compactMap { productTitle(from: $0.text) }
            : rankedEntityCandidates(
                in: importantText,
                allowedCategories: [.product]
            ).compactMap { productTitle(from: $0.text) }
        var topics = rankedEntityCandidates(
            in: importantText,
            allowedCategories: intent == .learning || intent == .coding
                ? [.heading, .subheading, .topic]
                : [.topic]
        ).compactMap { entityTitle(from: $0.text) }

        if products.isEmpty && intent == .shopping {
            products = rankedFallbackCandidates(in: importantText)
                .prefix(5)
                .compactMap { productTitle(from: $0.text) }
        }
        if topics.isEmpty && (intent == .learning || intent == .coding) {
            topics = rankedFallbackCandidates(in: importantText)
                .prefix(5)
                .compactMap { entityTitle(from: $0.text) }
        }

        return ExtractedEntities(
            products: unique(products),
            topics: unique(topics),
            places: unique(namedEntities.places),
            dates: unique(matches(in: text, pattern: datePattern)),
            brandsAndSites: unique(brands),
            prices: unique(matches(in: text, pattern: pricePattern)),
            sizes: unique(matches(in: text, pattern: sizePattern))
        )
    }

    private func intentWithGroundedSubject(
        _ intent: IntentClassification,
        importantText: [SalientText],
        visibleText: [String],
        entities: ExtractedEntities,
        sourceContext: ScreenSourceContext
    ) -> IntentClassification {
        let documentTitles = importantText
            .filter { $0.category == .documentTitle }
            .sorted { groundedSubjectScore($0) > groundedSubjectScore($1) }
            .map(\.text)
        let visibleHeadings = importantText
            .filter {
                ($0.category == .heading || $0.category == .subheading || $0.category == .topic) &&
                    ContentPhrasePolicy.isViableEntity($0.text)
            }
            .sorted { groundedSubjectScore($0) > groundedSubjectScore($1) }
            .compactMap { item in
                normalizedSubject(
                    subjectWithoutSectionNumber(item.text)
                )
            }
        let windowTitle = ContentPhrasePolicy.contentFromWindowTitle(
            sourceContext.windowTitle,
            websites: sourceContext.websites
        )
        let normalizedWindowTitles = windowTitle.flatMap(normalizedSubject).map { [$0] } ?? []
        let confirmedWindowTitles = normalizedWindowTitles.filter { title in
            let titleKey = ContentPhrasePolicy.compactKey(title)
            return importantText.contains { item in
                item.category != .action &&
                    item.category != .price &&
                    item.category != .size &&
                    item.category != .date &&
                    ContentPhrasePolicy.compactKey(item.text) == titleKey
            }
        }
        let modelSubject = normalizedSubject(
            intent.identifiedSubject.flatMap {
                subjectWithoutSectionNumber($0)
            }
        )
        let modelSubjectKey = ContentPhrasePolicy.compactKey(modelSubject ?? "")
        let documentLevelKeys = Set((documentTitles + normalizedWindowTitles).map {
            ContentPhrasePolicy.compactKey($0)
        })
        let hasLocalLearningHeading = (intent.category == .learning || intent.category == .coding) &&
            !visibleHeadings.isEmpty
        let modelSelectedSourceDocument = !modelSubjectKey.isEmpty &&
            documentLevelKeys.contains(modelSubjectKey)
        let modelSelectedFilename = modelSubject.map {
            ContentPhrasePolicy.isLikelyDocumentFilename(
                $0,
                windowTitle: sourceContext.windowTitle
            )
        } ?? false
        let sourceWindowIsFilename = windowTitle.map {
            ContentPhrasePolicy.isLikelyDocumentFilename(
                $0,
                windowTitle: sourceContext.windowTitle
            )
        } ?? false
        let isBrowser = ["safari", "chrome", "firefox", "edge"].contains { token in
            sourceContext.applicationName?.lowercased().contains(token) == true ||
                sourceContext.bundleIdentifier?.lowercased().contains(token) == true
        }
        let isDocumentReader = ["preview", "books", "adobe acrobat", "pdf expert"].contains { token in
            sourceContext.applicationName?.lowercased().contains(token) == true ||
                sourceContext.bundleIdentifier?.lowercased().contains(token) == true
        }
        if isBrowser,
           [.shopping, .travel, .learning, .coding].contains(intent.category),
           let matchedSubject = bestVisibleSubjectMatchingWindowTitle(
                windowTitle,
                importantText: importantText,
                visibleText: visibleText
           ) {
            let resolvedSubject = intent.category == .shopping
                ? conciseProductIdentity(from: matchedSubject)
                : matchedSubject
            return replacingSubject(
                in: intent,
                with: resolvedSubject,
                source: "active page title and visible heading"
            )
        }
        let confirmedPageTitleKey = confirmedWindowTitles.first.map {
            ContentPhrasePolicy.compactKey($0)
        } ?? ""
        let modelSharesPageIdentity = !modelSubjectKey.isEmpty &&
            !confirmedPageTitleKey.isEmpty &&
            (modelSubjectKey.contains(confirmedPageTitleKey) ||
                confirmedPageTitleKey.contains(modelSubjectKey))
        let shouldUseConfirmedBrowserTitle = isBrowser &&
            !sourceWindowIsFilename &&
            !confirmedPageTitleKey.isEmpty &&
            !modelSubjectKey.isEmpty &&
            !modelSharesPageIdentity
        let shouldUseLocalLearningHeading = hasLocalLearningHeading && (
            modelSelectedSourceDocument ||
                modelSelectedFilename ||
                sourceWindowIsFilename ||
                isDocumentReader
        )

        if modelSubject != nil,
           !shouldUseLocalLearningHeading,
           !shouldUseConfirmedBrowserTitle {
            return intent
        }

        let categoryEntities: [String]
        switch intent.category {
        case .shopping:
            categoryEntities = entities.products
        case .learning, .coding:
            categoryEntities = entities.topics
        case .travel:
            categoryEntities = entities.places
        case .entertainment, .productivity, .news, .finance, .health, .food,
             .realEstate, .careers, .social, .governmentLegal, .sportsFitness, .other:
            categoryEntities = []
        }
        let visibleContent = importantText
            .filter {
                $0.category != .documentTitle &&
                    $0.category != .brandOrSite &&
                    $0.category != .action &&
                    $0.category != .price &&
                    $0.category != .size &&
                    $0.category != .date
            }
            .sorted { groundedSubjectScore($0) > groundedSubjectScore($1) }
            .map(\.text)

        let candidates: [(values: [String], source: String)]
        switch intent.category {
        case .learning, .coding:
            if shouldUseLocalLearningHeading {
                candidates = [
                    (visibleHeadings, "visible section heading"),
                    (categoryEntities, "extracted topic"),
                    (documentTitles, "document title"),
                    (confirmedWindowTitles, "visible active window title"),
                    (windowTitle.map { [$0] } ?? [], "active window title"),
                    (visibleContent, "visible content")
                ]
            } else {
                candidates = [
                    (confirmedWindowTitles, "visible active window title"),
                    (documentTitles, "document title"),
                    (windowTitle.map { [$0] } ?? [], "active window title"),
                    (categoryEntities, "extracted topic"),
                    (visibleHeadings, "visible heading"),
                    (visibleContent, "visible content")
                ]
            }
        case .shopping:
            candidates = [
                (confirmedWindowTitles, "visible active window title"),
                (documentTitles, "document title"),
                (categoryEntities, "extracted entity"),
                (visibleHeadings, "visible heading"),
                (windowTitle.map { [$0] } ?? [], "active window title"),
                (visibleContent, "visible content")
            ]
        case .travel:
            candidates = [
                (confirmedWindowTitles, "visible active window title"),
                (visibleHeadings, "visible heading"),
                (documentTitles, "document title"),
                (categoryEntities, "extracted entity"),
                (windowTitle.map { [$0] } ?? [], "active window title"),
                (visibleContent, "visible content")
            ]
        case .entertainment, .productivity, .news, .finance, .health, .food,
             .realEstate, .careers, .social, .governmentLegal, .sportsFitness, .other:
            candidates = [
                (confirmedWindowTitles, "visible active window title"),
                (documentTitles, "document title"),
                (windowTitle.map { [$0] } ?? [], "active window title"),
                (visibleContent, "visible content")
            ]
        }
        guard let resolved = candidates.lazy.compactMap({ group in
            group.values.compactMap(normalizedSubject).first.map {
                (value: $0, source: group.source)
            }
        }).first else {
            return intent
        }

        return replacingSubject(in: intent, with: resolved.value, source: resolved.source)
    }

    private func replacingSubject(
        in intent: IntentClassification,
        with subject: String,
        source: String
    ) -> IntentClassification {
        IntentClassification(
            category: intent.category,
            subcategory: intent.subcategory,
            customCategoryID: intent.customCategoryID,
            customCategoryName: intent.customCategoryName,
            confidence: intent.confidence,
            method: intent.method,
            identifiedSubject: subject,
            evidence: unique(intent.evidence + ["grounded subject from \(source)"]),
            attempts: intent.attempts,
            learnedSignals: intent.learnedSignals,
            memoryStorePath: intent.memoryStorePath
        )
    }

    private func bestVisibleSubjectMatchingWindowTitle(
        _ windowTitle: String?,
        importantText: [SalientText],
        visibleText: [String]
    ) -> String? {
        guard let rawWindowTitle = ContentPhrasePolicy.contentFromWindowTitle(
            windowTitle,
            websites: []
        ) ?? windowTitle,
              !rawWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let normalizedTitle = repeatedSuffixRemoved(from: rawWindowTitle)

        let titleTokens = subjectTokens(normalizedTitle)
        guard titleTokens.count >= 2 else { return nil }
        let salientCandidates = importantText.filter { item in
            ![.documentTitle, .brandOrSite, .action, .price, .size, .date]
                .contains(item.category) &&
                ContentPhrasePolicy.isViableEntity(item.text)
        }
        .map { (text: $0.text, salience: $0.salienceScore, affinity: 0.18) }
        let salientKeys = Set(salientCandidates.map { ContentPhrasePolicy.compactKey($0.text) })
        let rawCandidates = visibleText.compactMap { text -> (text: String, salience: Double, affinity: Double)? in
            guard ContentPhrasePolicy.isViableEntity(text),
                  !salientKeys.contains(ContentPhrasePolicy.compactKey(text))
            else { return nil }
            return (text: text, salience: 0.45, affinity: 0.12)
        }
        let ranked = (salientCandidates + rawCandidates).compactMap { item -> (String, Double)? in
            let candidate = subjectWithoutSectionNumber(item.text)
            let candidateTokens = subjectTokens(candidate)
            let shared = titleTokens.intersection(candidateTokens).count
            guard shared >= 2 else { return nil }
            let coverage = Double(shared) / Double(max(1, candidateTokens.count))
            guard coverage >= 0.45 else { return nil }
            let score = coverage + min(0.5, item.salience * 0.35) + item.affinity
            return (candidate, score)
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private func subjectTokens(_ value: String) -> Set<String> {
        Set(ContentPhrasePolicy.words(in: value).filter { word in
            let key = ContentPhrasePolicy.compactKey(word)
            return key.count >= 2 && !stopwords.contains(key)
        }.map(ContentPhrasePolicy.compactKey))
    }

    private func subjectWithoutSectionNumber(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"^\s*\d+(?:\.\d+)*[.)]?\s+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repeatedSuffixRemoved(from value: String) -> String {
        let parts = value.split(separator: ",", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else { return value }
        let prefixTokens = subjectTokens(parts[0])
        let suffixTokens = subjectTokens(parts[1])
        guard !suffixTokens.isEmpty, suffixTokens.isSubset(of: prefixTokens) else { return value }
        return parts[0]
    }

    private func conciseProductIdentity(from value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let modelIndex = words.lastIndex(where: {
            $0.rangeOfCharacter(from: .decimalDigits) != nil
        }), modelIndex >= 1, modelIndex < words.count - 1 else {
            return value
        }
        let genericDescriptors: Set<String> = [
            "wireless", "wired", "bluetooth", "mechanical", "gaming", "low",
            "portable", "smart", "keyboard", "mouse", "monitor", "laptop",
            "phone", "headphones", "speaker", "camera"
        ]
        let nextKey = ContentPhrasePolicy.compactKey(words[modelIndex + 1])
        guard genericDescriptors.contains(nextKey) else { return value }
        return words[...modelIndex].joined(separator: " ")
    }

    private func normalizedSubject(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let genericKeys: Set<String> = [
            "abstract", "account", "actions", "chapter", "code", "coursesyllabus",
            "dashboard", "feed", "freedelivery", "home", "inbox", "instock",
            "introduction", "issues", "itemcondition", "lesson", "menu", "messages",
            "newtab", "notifications", "overview", "price", "profile", "pullrequests",
            "question", "references", "reviews", "search", "searchresults",
            "shopping", "learning", "travel", "coding", "entertainment",
            "productivity", "other", "untitled"
        ]
        let key = ContentPhrasePolicy.compactKey(cleaned)
        guard !cleaned.isEmpty,
              !genericKeys.contains(key),
              ContentPhrasePolicy.isViableEntity(cleaned),
              !ContentPhrasePolicy.isLikelyBodyText(cleaned)
        else { return nil }
        return String(cleaned.prefix(100))
    }

    private func groundedSubjectScore(_ item: SalientText) -> Double {
        var score = item.salienceScore
        score += Double(ContentPhrasePolicy.contextPrecedence(
            for: item.text,
            category: item.category
        )) / 100
        let wordCount = ContentPhrasePolicy.words(in: item.text).count
        if wordCount >= 2 && wordCount <= 12 { score += 0.18 }
        if item.boundingBox.centerY > 0.50 { score += 0.12 }
        return score
    }

    private func rankedEntityCandidates(
        in importantText: [SalientText],
        allowedCategories: Set<SalienceCategory>
    ) -> [SalientText] {
        importantText
            .filter {
                allowedCategories.contains($0.category) &&
                    ContentPhrasePolicy.isViableEntity($0.text)
            }
            .sorted { entityScore($0) > entityScore($1) }
    }

    private func rankedShoppingProductCandidates(
        in importantText: [SalientText],
        sourceContext: ScreenSourceContext
    ) -> [SalientText] {
        let allowed: Set<SalienceCategory> = [.heading, .subheading, .product]
        let windowTitleKey = ContentPhrasePolicy.compactKey(sourceContext.windowTitle ?? "")

        return importantText
            .filter {
                allowed.contains($0.category) &&
                    ContentPhrasePolicy.isViableEntity($0.text) &&
                    !isGenericShoppingSection($0.text)
            }
            .sorted {
                shoppingProductScore($0, windowTitleKey: windowTitleKey) >
                    shoppingProductScore($1, windowTitleKey: windowTitleKey)
            }
    }

    private func shoppingProductScore(
        _ item: SalientText,
        windowTitleKey: String
    ) -> Double {
        var score = entityScore(item)
        let key = ContentPhrasePolicy.compactKey(item.text)
        if !key.isEmpty && windowTitleKey.contains(key) { score += 0.75 }
        if item.category == .heading { score += 0.20 }
        let hasLetters = item.text.rangeOfCharacter(from: .letters) != nil
        let hasNumbers = item.text.rangeOfCharacter(from: .decimalDigits) != nil
        if hasLetters && hasNumbers { score += 0.14 }
        return score
    }

    private func isGenericShoppingSection(_ text: String) -> Bool {
        let key = ContentPhrasePolicy.compactKey(text)
        let genericKeys: Set<String> = [
            "colors", "colours", "compare", "contact", "contactseller",
            "expertopinion", "features", "images", "offers", "overview",
            "price", "ratings", "reviews", "similarproducts", "similarsportsbikes",
            "specifications", "videos", "writereview"
        ]
        return genericKeys.contains(key) || ContentPhrasePolicy.isInterfaceChrome(text)
    }

    private func rankedFallbackCandidates(in importantText: [SalientText]) -> [SalientText] {
        importantText
            .filter {
                ($0.category == .heading || $0.category == .subheading || $0.category == .keyword) &&
                    ContentPhrasePolicy.isViableEntity($0.text)
            }
            .sorted { entityScore($0) > entityScore($1) }
    }

    private func entityScore(_ item: SalientText) -> Double {
        let wordCount = ContentPhrasePolicy.words(in: item.text).count
        var score = item.salienceScore
        score += Double(item.category.contextPrecedence) / 100
        if wordCount >= 2 && wordCount <= 12 { score += 0.18 }
        if item.boundingBox.width >= 0.14 { score += 0.08 }
        if item.boundingBox.centerY > 0.42 && item.boundingBox.centerY < 0.88 { score += 0.06 }
        return score
    }

    private func entityTitle(from text: String) -> String? {
        if ContentPhrasePolicy.isNumberedHeading(text) {
            return ContentPhrasePolicy.titleWithoutNumbering(text)
        }
        return ContentPhrasePolicy.isViableEntity(text) ? text : nil
    }

    private func productTitle(from text: String) -> String? {
        let withoutSectionSuffix = text.replacingOccurrences(
            of: #"\s+(?:price|review|reviews|specifications|features|colou?rs?)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return entityTitle(from: withoutSectionSuffix)
    }

    private func primarilyRepresents(_ text: String, entity: String) -> Bool {
        let textWords = ContentPhrasePolicy.words(in: text)
        let entityWords = ContentPhrasePolicy.words(in: entity)
        return !entityWords.isEmpty &&
            text.localizedCaseInsensitiveContains(entity) &&
            textWords.count <= entityWords.count + 3
    }

    private func isOrphanedBottomHeading(
        _ candidate: Candidate,
        among candidates: [Candidate]
    ) -> Bool {
        guard candidate.category == .heading || candidate.category == .subheading,
              candidate.line.boundingBox.centerY < 0.07
        else { return false }

        let headingBox = candidate.line.boundingBox
        let hasSupportingTextBelow = candidates.contains { other in
            guard other.text != candidate.text,
                  other.category == .bodyText || other.category == .topic || other.category == .keyword,
                  other.line.boundingBox.centerY < headingBox.y
            else { return false }
            let otherBox = other.line.boundingBox
            let overlap = min(headingBox.x + headingBox.width, otherBox.x + otherBox.width) -
                max(headingBox.x, otherBox.x)
            return overlap > min(headingBox.width, otherBox.width) * 0.15
        }
        return !hasSupportingTextBelow
    }

    private func extractNamedEntities(from text: String) -> NamedEntities {
        guard !text.isEmpty else { return NamedEntities(places: [], organizations: []) }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var places: [String] = []
        var organizations: [String] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            let value = normalize(String(text[range]))
            guard ContentPhrasePolicy.isViableEntity(value) else { return true }
            if tag == .placeName {
                places.append(value)
            } else if tag == .organizationName {
                organizations.append(value)
            }
            return true
        }

        return NamedEntities(
            places: unique(places),
            organizations: unique(organizations)
        )
    }

    private func makeCategories(
        from importantText: [SalientText],
        entities: ExtractedEntities
    ) -> [ExtractedCategory] {
        var categories = [
            ExtractedCategory(name: "products", items: entities.products),
            ExtractedCategory(name: "topics", items: entities.topics),
            ExtractedCategory(name: "places", items: entities.places),
            ExtractedCategory(name: "dates", items: entities.dates),
            ExtractedCategory(name: "brands_and_sites", items: entities.brandsAndSites),
            ExtractedCategory(name: "prices", items: entities.prices),
            ExtractedCategory(name: "sizes", items: entities.sizes)
        ]

        for category in [
            SalienceCategory.documentTitle, .heading, .subheading, .action, .keyword, .bodyText
        ] {
            let values = unique(importantText.filter { $0.category == category }.map(\.text))
            categories.append(ExtractedCategory(name: category.rawValue, items: values))
        }
        return categories.filter { !$0.items.isEmpty }
    }

    private func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func isTitleLike(_ text: String) -> Bool {
        let words = text.split(separator: " ").filter { $0.rangeOfCharacter(from: .letters) != nil }
        guard words.count >= 2 else { return false }
        let capitalized = words.filter { $0.first?.isUppercase == true }.count
        return Double(capitalized) / Double(words.count) >= 0.6
    }

    private func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: text.contains)
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap {
            guard let matchRange = Range($0.range, in: text) else { return nil }
            return normalize(String(text[matchRange]))
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let key = $0.lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0.02 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private var pricePattern: String {
        #"(?:[$₹€£]\s?\d[\d,]*(?:\.\d{1,2})?|\b\d[\d,]*(?:\.\d{1,2})?\s?(?:USD|INR|EUR|GBP))"#
    }

    private var datePattern: String {
        #"\b(?:\d{1,2}\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)(?:\s+\d{2,4})?|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,?\s+\d{2,4})?|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)\b"#
    }

    private var sizePattern: String {
        #"(?:(?-i:\b(?:XXS|XS|S|M|L|XL|XXL|XXXL)\b)|\bsize\s*[:\-]?\s*(?:(?-i:XXS|XS|S|M|L|XL|XXL|XXXL)|\d{1,3})\b|(?-i:\b(?:EU|UK|US)\s*\d{1,2}\b))"#
    }
}
