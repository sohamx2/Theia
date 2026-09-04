import Foundation

struct FieldAgentContextService {
    func context(
        for report: ScreenContextReport,
        subject: String
    ) -> FieldAgentContext {
        let normalizedSubject = clean(subject, fallback: "the current subject")
        let field = report.intent.customCategoryName ?? fieldName(
            category: report.intent.category,
            subcategory: report.intent.subcategory,
            subject: normalizedSubject,
            report: report
        )
        let sourceKind = sourceKind(for: report)
        let nearbyConcepts = nearbyConcepts(
            in: report,
            excluding: normalizedSubject
        )

        return FieldAgentContext(
            category: report.intent.category,
            subcategory: report.intent.subcategory,
            activeSubject: normalizedSubject,
            field: field,
            specialistRole: specialistRole(
                category: report.intent.category,
                field: field
            ),
            sourceKind: sourceKind,
            userStage: userStage(
                category: report.intent.category,
                sourceKind: sourceKind,
                report: report
            ),
            assumptions: assumptions(
                category: report.intent.category,
                field: field,
                sourceKind: sourceKind,
                report: report
            ),
            nearbyConcepts: nearbyConcepts
        )
    }

    func generalContext() -> FieldAgentContext {
        FieldAgentContext(
            category: .other,
            subcategory: nil,
            activeSubject: "general questions",
            field: "general assistance",
            specialistRole: "concise general assistant",
            sourceKind: "direct chat",
            userStage: "The user opened Qwen directly without an active screen analysis.",
            assumptions: [
                "Ask for clarification when the field or goal is ambiguous.",
                "Do not claim access to current screen content or live web results."
            ],
            nearbyConcepts: []
        )
    }

    func continuingContext(
        from context: FieldAgentContext,
        parentPrompt: String,
        selectedPath: String,
        existingAnswer: String
    ) -> FieldAgentContext {
        FieldAgentContext(
            category: context.category,
            subcategory: context.subcategory,
            activeSubject: context.activeSubject,
            field: context.field,
            specialistRole: context.specialistRole,
            sourceKind: context.sourceKind,
            userStage: "Continuing from a selected Theia path with a fresh Qwen conversation.",
            assumptions: context.assumptions,
            nearbyConcepts: context.nearbyConcepts,
            continuationContext: QwenContinuationContext(
                parentPrompt: compact(parentPrompt, limit: 1_200),
                selectedPath: compact(selectedPath, limit: 500),
                existingAnswer: compact(existingAnswer, limit: 6_000)
            )
        )
    }

    private func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(limit))
    }

    private func fieldName(
        category: IntentCategory,
        subcategory: IntentSubcategory?,
        subject: String,
        report: ScreenContextReport
    ) -> String {
        switch category {
        case .learning:
            return learningField(in: report) ?? "learning about \(subject)"
        case .shopping:
            return shoppingField(subject: subject, subcategory: subcategory)
        case .travel:
            return "travel planning for \(subject)"
        case .coding:
            return codingField(subject: subject, report: report)
        case .entertainment:
            return subcategoryField(subcategory, fallback: "entertainment")
        case .productivity:
            return subcategoryField(subcategory, fallback: "productivity workflows")
        case .news:
            return subcategoryField(subcategory, fallback: "news analysis")
        case .finance:
            return subcategoryField(subcategory, fallback: "personal finance")
        case .health:
            return subcategoryField(subcategory, fallback: "health information")
        case .food:
            return subcategoryField(subcategory, fallback: "food and dining")
        case .realEstate:
            return subcategoryField(subcategory, fallback: "real estate")
        case .careers:
            return subcategoryField(subcategory, fallback: "career development")
        case .social:
            return subcategoryField(subcategory, fallback: "online communities")
        case .governmentLegal:
            return subcategoryField(subcategory, fallback: "government and legal information")
        case .sportsFitness:
            return subcategoryField(subcategory, fallback: "sports and fitness")
        case .other:
            return subject == "the current subject" ? "general assistance" : subject
        }
    }

    private func learningField(in report: ScreenContextReport) -> String? {
        let context = searchableContext(in: report)
        let fields: [([String], String)] = [
            (["deep learning", "deeplearning", "neural network", "loss function"], "machine learning and deep learning"),
            (["machine learning", "linear regression", "classification model"], "machine learning"),
            (["programming", "software", "algorithm", "computer science"], "computer science"),
            (["probability", "statistics", "statistical"], "statistics and probability"),
            (["calculus", "linear algebra", "mathematics"], "mathematics"),
            (["physics", "quantum", "mechanics"], "physics"),
            (["chemistry", "chemical"], "chemistry"),
            (["biology", "biological", "genetics"], "biology"),
            (["economics", "economic", "financial"], "economics and finance")
        ]
        return fields.first { entry in
            entry.0.contains { context.contains($0) }
        }?.1
    }

    private func shoppingField(
        subject: String,
        subcategory: IntentSubcategory?
    ) -> String {
        let value = subject.lowercased()
        let productFields: [([String], String)] = [
            (["keyboard", "keycap", "mechanical switch"], "computer keyboards"),
            (["laptop", "macbook", "notebook computer"], "laptop computers"),
            (["monitor", "display"], "computer monitors"),
            (["headphone", "earbud", "headset"], "headphones and audio gear"),
            (["phone", "iphone", "smartphone"], "smartphones"),
            (["motorcycle", "motorbike", "bike"], "motorcycles"),
            (["car", "suv", "sedan"], "cars"),
            (["shoe", "sneaker", "boot"], "footwear"),
            (["shirt", "jacket", "dress", "jeans", "clothing"], "clothing and fashion"),
            (["sofa", "chair", "desk", "furniture"], "furniture"),
            (["moisturizer", "serum", "skincare", "sunscreen"], "skincare products")
        ]
        if let field = productFields.first(where: { entry in
            entry.0.contains { value.contains($0) }
        })?.1 {
            return field
        }
        return subcategoryField(subcategory, fallback: "products like \(subject)")
    }

    private func codingField(subject: String, report: ScreenContextReport) -> String {
        let context = searchableContext(in: report)
        let fields: [([String], String)] = [
            (["swift", "swiftui", "xcode"], "Swift and macOS development"),
            (["javascript", "typescript", "react", "node.js"], "JavaScript and web development"),
            (["python", "django", "flask"], "Python development"),
            (["sql", "database", "postgres"], "database engineering"),
            (["api", "http", "json"], "API integration")
        ]
        return fields.first { entry in
            entry.0.contains { context.contains($0) }
        }?.1 ?? "software engineering for \(subject)"
    }

    private func specialistRole(category: IntentCategory, field: String) -> String {
        switch category {
        case .learning: return "progress-aware tutor specializing in \(field)"
        case .shopping: return "product research specialist for \(field)"
        case .travel: return "travel planner specializing in \(field)"
        case .coding: return "senior engineer specializing in \(field)"
        case .finance: return "careful financial research assistant for \(field)"
        case .health: return "evidence-conscious health information assistant for \(field)"
        case .governmentLegal: return "source-conscious public information assistant for \(field)"
        default: return "specialist assistant for \(field)"
        }
    }

    private func sourceKind(for report: ScreenContextReport) -> String {
        switch report.sourceContext.bundleIdentifier {
        case "com.apple.Preview":
            return "book or PDF document"
        case "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac":
            return report.sourceContext.websites.isEmpty ? "web page" : "active website"
        case "com.apple.dt.Xcode", "com.microsoft.VSCode":
            return "source code workspace"
        default:
            return report.intent.category == .learning ? "learning source" : "visible application"
        }
    }

    private func userStage(
        category: IntentCategory,
        sourceKind: String,
        report: ScreenContextReport
    ) -> String {
        let context = searchableContext(in: report)
        switch category {
        case .learning where sourceKind == "book or PDF document":
            if context.contains("previous chapter") || context.contains("previous section") {
                return "Progressing through a domain-specific textbook; earlier chapters and sections indicate established prior knowledge."
            }
            return "Studying a domain-specific book or PDF rather than starting from a generic beginner search."
        case .learning:
            return "Actively studying the detected subject inside the classified field."
        case .shopping:
            return "Actively evaluating the detected product within its exact product family."
        case .coding:
            return "Working on an active technical task, not requesting a generic programming overview."
        default:
            return "Working on the detected subject inside the classified field."
        }
    }

    private func assumptions(
        category: IntentCategory,
        field: String,
        sourceKind: String,
        report: ScreenContextReport
    ) -> [String] {
        switch category {
        case .learning:
            var values = [
                "Keep recommendations inside \(field) unless the user explicitly asks to broaden the scope.",
                "Prefer concepts immediately adjacent to the active subject over generic beginner foundations."
            ]
            if sourceKind == "book or PDF document" && isTechnicalLearningField(field) {
                values.append("General mathematical foundations such as linear algebra, calculus, and introductory probability are already understood.")
            }
            if searchableContext(in: report).contains("previous chapter") {
                values.append("Concepts named as earlier chapters are established context and should guide the next response.")
            }
            return values
        case .shopping:
            return [
                "Stay within the exact product type \(field), not the broad shopping category.",
                "Prioritize compatibility, intended use, value, and meaningful product differences."
            ]
        case .coding:
            return [
                "Stay within the detected language, framework, and current technical task.",
                "Prefer concrete implementation and debugging steps over generic tutorials."
            ]
        case .health, .finance, .governmentLegal:
            return [
                "Distinguish general information from professional advice.",
                "Flag claims that require current authoritative verification."
            ]
        default:
            return ["Keep every answer grounded in the classified field and active subject."]
        }
    }

    private func nearbyConcepts(
        in report: ScreenContextReport,
        excluding subject: String
    ) -> [String] {
        var candidates: [String] = []
        switch report.intent.category {
        case .learning, .coding:
            candidates += report.entities.topics
        case .shopping:
            candidates += report.entities.products
        case .travel:
            candidates += report.entities.places
        default:
            break
        }
        candidates += report.importantText.filter {
            [.heading, .subheading, .topic, .product, .place].contains($0.category)
        }.map(\.text)

        let context = searchableContext(in: report)
        let knownConcepts: [(String, String)] = [
            ("supervised learning", "Supervised Learning"),
            ("linear regression", "Linear Regression"),
            ("shallow neural network", "Shallow Neural Networks"),
            ("deep neural network", "Deep Neural Networks"),
            ("activation function", "Activation Functions"),
            ("gradient descent", "Gradient Descent"),
            ("model training", "Model Training"),
            ("probability theory", "Probability Theory"),
            ("linear algebra", "Linear Algebra"),
            ("calculus", "Calculus")
        ]
        candidates += knownConcepts.compactMap { context.contains($0.0) ? $0.1 : nil }

        let subjectKey = ContentPhrasePolicy.compactKey(subject)
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let value = clean(candidate, fallback: "")
            let key = ContentPhrasePolicy.compactKey(value)
            guard key.count >= 4,
                  key != subjectKey,
                  !key.contains(subjectKey),
                  !subjectKey.contains(key),
                  seen.insert(key).inserted
            else { return nil }
            return String(value.prefix(80))
        }.prefix(10).map { $0 }
    }

    private func searchableContext(in report: ScreenContextReport) -> String {
        let values = [
            report.sourceContext.windowTitle ?? "",
            report.intent.identifiedSubject ?? ""
        ] + Array(report.cleanedSegments.prefix(24)) + report.entities.topics + report.entities.products
        return values.joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    private func isTechnicalLearningField(_ field: String) -> Bool {
        [
            "machine learning", "deep learning", "computer science",
            "statistics", "mathematics", "physics", "chemistry",
            "biology", "economics"
        ].contains { field.contains($0) }
    }

    private func subcategoryField(
        _ subcategory: IntentSubcategory?,
        fallback: String
    ) -> String {
        guard let subcategory else { return fallback }
        return subcategory.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func clean(_ value: String, fallback: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? fallback : cleaned
    }
}
