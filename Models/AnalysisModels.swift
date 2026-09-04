import Foundation

enum TheiaRelease {
    static let channel = "Beta"

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
    }

    static var displayName: String {
        "\(channel) v\(marketingVersion)"
    }
}

enum TheiaPreferenceKey {
    static let experienceFocus = "theia.experience.focus"
    static let responseStyle = "theia.response.style"
    static let qwenModel = "theia.qwenModel"
    static let qwenTextContextLength = "theia.qwenTextContextLength"
    static let qwenVisionContextLength = "theia.qwenVisionContextLength"
    static let ollamaBaseURL = "theia.ollamaBaseURL"
    static let webResearchEnabled = "theia.webResearchEnabled"
    static let internetAccessPolicy = "theia.internetAccessPolicy"
    static let searchEngine = "theia.searchEngine"
    static let appearanceMode = "theia.appearanceMode"
    static let developerUIEnabled = "theia.developerUIEnabled"
    static let windowAlwaysOnTop = "theia.windowAlwaysOnTop"
    static let subpromptsPerMainPrompt = "theia.subpromptsPerMainPrompt"
}

enum VisibleSubpromptLimit {
    static let defaultValue = 1
    static let allowedRange = 1...3

    static var current: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: TheiaPreferenceKey.subpromptsPerMainPrompt) != nil else {
            return defaultValue
        }
        return allowedRange.clamped(defaults.integer(
            forKey: TheiaPreferenceKey.subpromptsPerMainPrompt
        ))
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var current: AppearanceMode {
        guard let value = UserDefaults.standard.string(forKey: TheiaPreferenceKey.appearanceMode),
              let mode = AppearanceMode(rawValue: value) else { return .system }
        return mode
    }
}

enum ExperienceFocus: String, Codable, CaseIterable, Equatable {
    case everyday = "Everyday"
    case work = "Work"
    case learning = "Learning"

    static var current: ExperienceFocus {
        guard let value = UserDefaults.standard.string(forKey: TheiaPreferenceKey.experienceFocus),
              let focus = ExperienceFocus(rawValue: value) else { return .everyday }
        return focus
    }

    var detail: String {
        switch self {
        case .everyday: return "Keeps next steps broadly practical across personal, work, and learning contexts."
        case .work: return "Uses work, implementation, decision, and productivity outcomes as tie-breakers."
        case .learning: return "Uses understanding, prerequisites, examples, and learning progression as tie-breakers."
        }
    }

    var promptHint: String {
        switch self {
        case .everyday:
            return "Prefer practical, broadly useful next steps."
        case .work:
            return "When several answers are equally relevant, prioritize concrete work, decision, implementation, and productivity outcomes."
        case .learning:
            return "When several answers are equally relevant, prioritize understanding, prerequisites, examples, and the next concept to learn."
        }
    }

    var classificationHint: String {
        "The user's optional experience focus is \(rawValue.lowercased()). Use this only as a tie-breaker when screen evidence is genuinely ambiguous; never override clear visible evidence."
    }
}

enum ResponseStyle: String, Codable, CaseIterable, Equatable {
    case concise = "Concise"
    case balanced = "Balanced"
    case exploratory = "Exploratory"

    static var current: ResponseStyle {
        guard let value = UserDefaults.standard.string(forKey: TheiaPreferenceKey.responseStyle),
              let style = ResponseStyle(rawValue: value) else { return .balanced }
        return style
    }

    var detail: String {
        switch self {
        case .concise: return "Three direct key points with no introductory paragraph."
        case .balanced: return "A direct explanatory paragraph followed by three key points."
        case .exploratory: return "A detailed, connected explanation in paragraphs without a key-point list."
        }
    }

    var chatInstruction: String {
        switch self {
        case .concise:
            return "Answer with concise key points. Omit an introductory or concluding paragraph unless required for safety or clarity."
        case .balanced:
            return "Answer with a concise explanatory paragraph followed by useful key points when applicable."
        case .exploratory:
            return "Answer with a detailed, connected explanation in clear paragraphs. Do not reduce the answer to a terse bullet list."
        }
    }
}

enum LocalAIModelTier: String, CaseIterable, Equatable {
    case fast
    case balanced
    case bestQuality = "best_quality"
    case vision

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .bestQuality: return "Best Quality"
        case .vision: return "Qwen3-VL"
        }
    }

    var modelName: String {
        switch self {
        case .fast: return "qwen3:0.6b"
        case .balanced: return "qwen3:1.7b"
        case .bestQuality: return "qwen3:4b"
        case .vision: return "qwen3-vl:4b-instruct"
        }
    }

    var modelDisplayName: String {
        switch self {
        case .fast: return "Qwen 0.6B"
        case .balanced: return "Qwen 1.7B"
        case .bestQuality: return "Qwen 4B"
        case .vision: return "Qwen3-VL 4B"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Fastest generation, with lower accuracy on nuanced requests."
        case .balanced: return "Moderate speed with stronger context and instruction following."
        case .bestQuality: return "Slowest generation, with the strongest accuracy and validation reliability."
        case .vision: return "Reads the screenshot directly for both classification and next-step prompting."
        }
    }

    var usesScreenshotVisionPipeline: Bool { self == .vision }

    static func tier(for modelName: String) -> LocalAIModelTier {
        allCases.first { $0.modelName == modelName } ?? .bestQuality
    }
}

enum QwenVisionContextWindow: Int, CaseIterable, Equatable {
    case efficient = 8_192
    case recommended = 16_384
    case extended = 32_768

    var title: String {
        switch self {
        case .efficient: return "Efficient"
        case .recommended: return "Balanced"
        case .extended: return "Extended"
        }
    }

    var detail: String {
        switch self {
        case .efficient:
            return "Uses less memory, but very large or dense screenshots may still exceed the limit."
        case .recommended:
            return "Recommended for this 16 GB Mac and large enough for most full-screen screenshots."
        case .extended:
            return "Handles denser screenshots but uses substantially more unified memory and may run slower."
        }
    }

    static var current: QwenVisionContextWindow {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["THEIA_QWEN_VISION_CONTEXT_LENGTH"],
           let value = Int(configured),
           let window = QwenVisionContextWindow(rawValue: value) {
            return window
        }
        let stored = UserDefaults.standard.integer(
            forKey: TheiaPreferenceKey.qwenVisionContextLength
        )
        return QwenVisionContextWindow(rawValue: stored) ?? .recommended
    }
}

enum QwenTextContextWindow: Int, CaseIterable, Equatable {
    case efficient = 8_192
    case recommended = 16_384
    case extended = 32_768

    var title: String {
        switch self {
        case .efficient: return "8K"
        case .recommended: return "16K"
        case .extended: return "32K"
        }
    }

    var detail: String {
        switch self {
        case .efficient:
            return "Lower memory use for short chats and prompt answers."
        case .recommended:
            return "Keeps substantially more screen context and conversation history without the old 4K ceiling."
        case .extended:
            return "Maximum context for long material; uses more unified memory and can respond more slowly."
        }
    }

    static var current: QwenTextContextWindow {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["THEIA_QWEN_TEXT_CONTEXT_LENGTH"],
           let value = Int(configured),
           let window = QwenTextContextWindow(rawValue: value) {
            return window
        }
        let stored = UserDefaults.standard.integer(
            forKey: TheiaPreferenceKey.qwenTextContextLength
        )
        return QwenTextContextWindow(rawValue: stored) ?? .recommended
    }
}

enum QwenOutputTokenBudget {
    static let promptExpansion = 512
    static let directChat = 1_024
}

enum SearchEngine: String, Codable, CaseIterable, Equatable {
    case google
    case duckDuckGo = "duckduckgo"
    case bing
    case brave

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        }
    }

    static var current: SearchEngine {
        guard let value = UserDefaults.standard.string(forKey: TheiaPreferenceKey.searchEngine),
              let engine = SearchEngine(rawValue: value) else { return .google }
        return engine
    }

    func searchURL(for query: String) -> URL? {
        let baseURL: String
        switch self {
        case .google: baseURL = "https://www.google.com/search"
        case .duckDuckGo: baseURL = "https://duckduckgo.com/"
        case .bing: baseURL = "https://www.bing.com/search"
        case .brave: baseURL = "https://search.brave.com/search"
        }
        var components = URLComponents(string: baseURL)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

enum InternetAccessPolicy: String, Codable, CaseIterable, Equatable {
    case automatic
    case ask
    case never

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .ask: return "Ask"
        case .never: return "Never"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Use live public search automatically when current evidence is needed."
        case .ask:
            return "Request permission before each analysis that needs live public search."
        case .never:
            return "Keep analysis offline, even when the visible content is newer than Qwen."
        }
    }

    static var current: InternetAccessPolicy {
        let environment = ProcessInfo.processInfo.environment
        if let rawValue = environment["THEIA_INTERNET_ACCESS_POLICY"],
           let policy = InternetAccessPolicy(rawValue: rawValue.lowercased()) {
            return policy
        }

        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: TheiaPreferenceKey.internetAccessPolicy),
           let policy = InternetAccessPolicy(rawValue: rawValue) {
            return policy
        }

        // Preserve an explicit choice made with the earlier on/off setting.
        if defaults.object(forKey: TheiaPreferenceKey.webResearchEnabled) != nil {
            let rawValue = defaults.string(forKey: TheiaPreferenceKey.webResearchEnabled) ?? "true"
            let disabledValues: Set<String> = ["0", "false", "no", "off"]
            return disabledValues.contains(rawValue.lowercased()) ? .never : .ask
        }
        return .ask
    }
}

enum TemporalFreshnessStatus: String, Codable, Equatable {
    case stable
    case withinKnowledgeWindow = "within_knowledge_window"
    case outsideKnowledgeWindow = "outside_knowledge_window"
    case currentInformationRequested = "current_information_requested"
    case timeSensitive = "time_sensitive"
}

struct TemporalFreshnessAssessment: Codable, Equatable {
    let status: TemporalFreshnessStatus
    let knowledgeCutoff: Date
    let analyzedAt: Date
    let detectedYears: [Int]
    let temporalSignals: [String]
    let trigger: TemporalFreshnessTrigger?
    let requiresLiveWebSearch: Bool
    let confidence: Double
    let reason: String
}

struct TemporalFreshnessTrigger: Codable, Equatable {
    let rule: String
    let signal: String
    let matchingLine: String
}

struct NormalizedBoundingBox: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var centerX: Double { x + (width / 2) }
    var centerY: Double { y + (height / 2) }
}

struct OCRTextLine: Codable, Equatable {
    let text: String
    let confidence: Double
    let boundingBox: NormalizedBoundingBox
}

struct OCRDocument: Codable, Equatable {
    let lines: [OCRTextLine]

    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

enum IntentCategory: String, Codable, CaseIterable, Equatable, Hashable {
    case shopping
    case learning
    case travel
    case coding
    case entertainment
    case productivity
    case news
    case finance
    case health
    case food
    case realEstate = "real_estate"
    case careers
    case social
    case governmentLegal = "government_legal"
    case sportsFitness = "sports_fitness"
    case other
}

enum IntentSubcategory: String, Codable, CaseIterable, Equatable, Hashable {
    case clothingFashion = "clothing_fashion"
    case electronicsAppliances = "electronics_appliances"
    case vehiclesParts = "vehicles_parts"
    case flightsTransport = "flights_transport"
    case hotelsStays = "hotels_stays"
    case destinationsActivities = "destinations_activities"
    case coursesTutorials = "courses_tutorials"
    case academicResearch = "academic_research"
    case referenceMaterials = "reference_materials"
    case programmingDebugging = "programming_debugging"
    case APIsTechnicalDocs = "apis_technical_docs"
    case toolsPackages = "tools_packages"
    case projectManagement = "project_management"
    case documentsCollaboration = "documents_collaboration"
    case personalOrganization = "personal_organization"
    case music
    case moviesTelevision = "movies_television"
    case gamesBooks = "games_books"
    case generalNews = "general_news"
    case businessTechnology = "business_technology"
    case politicsWorldEvents = "politics_world_events"
    case bankingPayments = "banking_payments"
    case investingMarkets = "investing_markets"
    case personalFinanceInsurance = "personal_finance_insurance"
    case generalHealth = "general_health"
    case fitnessNutrition = "fitness_nutrition"
    case medicalResearchCare = "medical_research_care"
    case recipesCooking = "recipes_cooking"
    case restaurantsReviews = "restaurants_reviews"
    case groceryDelivery = "grocery_delivery"
    case buyingSelling = "buying_selling"
    case rentals
    case homeImprovement = "home_improvement"
    case jobSearching = "job_searching"
    case resumesInterviews = "resumes_interviews"
    case professionalDevelopment = "professional_development"
    case discussionForums = "discussion_forums"
    case socialNetworks = "social_networks"
    case creatorCommunities = "creator_communities"
    case governmentServices = "government_services"
    case legalInformation = "legal_information"
    case formsRegulations = "forms_regulations"
    case sportsNewsTeams = "sports_news_teams"
    case trainingWorkouts = "training_workouts"
    case equipmentEvents = "equipment_events"

    var parent: IntentCategory {
        switch self {
        case .clothingFashion, .electronicsAppliances, .vehiclesParts: return .shopping
        case .flightsTransport, .hotelsStays, .destinationsActivities: return .travel
        case .coursesTutorials, .academicResearch, .referenceMaterials: return .learning
        case .programmingDebugging, .APIsTechnicalDocs, .toolsPackages: return .coding
        case .projectManagement, .documentsCollaboration, .personalOrganization: return .productivity
        case .music, .moviesTelevision, .gamesBooks: return .entertainment
        case .generalNews, .businessTechnology, .politicsWorldEvents: return .news
        case .bankingPayments, .investingMarkets, .personalFinanceInsurance: return .finance
        case .generalHealth, .fitnessNutrition, .medicalResearchCare: return .health
        case .recipesCooking, .restaurantsReviews, .groceryDelivery: return .food
        case .buyingSelling, .rentals, .homeImprovement: return .realEstate
        case .jobSearching, .resumesInterviews, .professionalDevelopment: return .careers
        case .discussionForums, .socialNetworks, .creatorCommunities: return .social
        case .governmentServices, .legalInformation, .formsRegulations: return .governmentLegal
        case .sportsNewsTeams, .trainingWorkouts, .equipmentEvents: return .sportsFitness
        }
    }
}

enum ClassificationMethod: String, Codable, Equatable {
    case ruleBased = "rule_based"
    case bert
    case qwen
    case qwenVision = "qwen3_vl"
    case fallback
}

struct ClassificationAttempt: Codable, Equatable, Identifiable {
    let method: ClassificationMethod
    let category: IntentCategory?
    let subcategory: IntentSubcategory?
    let confidence: Double?
    let accepted: Bool
    let evidence: [String]
    let error: String?

    init(
        method: ClassificationMethod,
        category: IntentCategory?,
        subcategory: IntentSubcategory? = nil,
        confidence: Double?,
        accepted: Bool,
        evidence: [String],
        error: String?
    ) {
        self.method = method
        self.category = category
        self.subcategory = subcategory?.parent == category ? subcategory : nil
        self.confidence = confidence
        self.accepted = accepted
        self.evidence = evidence
        self.error = error
    }

    var id: String { method.rawValue }
}

enum ClassificationStageState: String, Equatable {
    case pending
    case running
    case completed
    case failed
    case skipped
}

struct ClassificationStageProgress: Equatable, Identifiable {
    let method: ClassificationMethod
    let state: ClassificationStageState
    let attempt: ClassificationAttempt?

    var id: String { method.rawValue }
}

typealias ClassificationProgressHandler = @MainActor ([ClassificationStageProgress]) -> Void

enum LearnedSignalKind: String, Codable, Equatable {
    case website
    case keyword
}

struct LearnedIntentSignal: Codable, Equatable, Identifiable {
    let kind: LearnedSignalKind
    let value: String
    let category: IntentCategory
    let confidence: Double
    let observations: Int

    var id: String { "\(kind.rawValue):\(value.lowercased())" }
}

struct IntentClassification: Codable, Equatable {
    let category: IntentCategory
    let subcategory: IntentSubcategory?
    let customCategoryID: UUID?
    let customCategoryName: String?
    let confidence: Double
    let method: ClassificationMethod
    /// The concrete subject of the activity identified by a model or a grounded
    /// deterministic fallback, such as "KTM RC 390 motorcycle" rather than only
    /// the broad "shopping" label.
    let identifiedSubject: String?
    let evidence: [String]
    let attempts: [ClassificationAttempt]
    let learnedSignals: [LearnedIntentSignal]
    let memoryStorePath: String?

    init(
        category: IntentCategory,
        subcategory: IntentSubcategory? = nil,
        customCategoryID: UUID? = nil,
        customCategoryName: String? = nil,
        confidence: Double,
        method: ClassificationMethod = .ruleBased,
        identifiedSubject: String? = nil,
        evidence: [String],
        attempts: [ClassificationAttempt] = [],
        learnedSignals: [LearnedIntentSignal] = [],
        memoryStorePath: String? = nil
    ) {
        self.category = category
        self.subcategory = subcategory?.parent == category ? subcategory : nil
        self.customCategoryID = customCategoryID
        self.customCategoryName = customCategoryName
        self.confidence = confidence
        self.method = method
        self.identifiedSubject = identifiedSubject
        self.evidence = evidence
        self.attempts = attempts
        self.learnedSignals = learnedSignals
        self.memoryStorePath = memoryStorePath
    }
}

struct ScreenSourceContext: Codable, Equatable {
    let applicationName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let websites: [String]

    static let empty = ScreenSourceContext(
        applicationName: nil,
        bundleIdentifier: nil,
        windowTitle: nil,
        websites: []
    )

    func addingWebsites(_ newWebsites: [String]) -> ScreenSourceContext {
        var seen = Set<String>()
        let combined = (websites + newWebsites).filter {
            let key = $0.lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
        return ScreenSourceContext(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            websites: combined
        )
    }
}

enum SalienceCategory: String, Codable, Equatable {
    case documentTitle = "document_title"
    case heading
    case subheading
    case product
    case topic
    case place
    case date
    case price
    case size
    case brandOrSite = "brand_or_site"
    case action
    case keyword
    case bodyText = "body_text"

    /// Structural precedence supplied to local models. This is deliberately
    /// separate from visual salience: a centered paragraph can be visually
    /// prominent without being the subject of the page.
    var contextPrecedence: Int {
        switch self {
        case .heading: return 100
        case .subheading: return 95
        case .product, .topic, .place: return 90
        case .documentTitle: return 85
        case .brandOrSite: return 80
        case .date, .price, .size: return 75
        case .action: return 70
        case .keyword: return 55
        case .bodyText: return 25
        }
    }

    var contextRole: String {
        switch self {
        case .heading, .subheading: return "document_structure"
        case .documentTitle: return "source_document"
        case .product, .topic, .place: return "primary_entity"
        case .brandOrSite, .date, .price, .size: return "supporting_fact"
        case .action: return "interface_action"
        case .keyword: return "supporting_keyword"
        case .bodyText: return "supporting_prose"
        }
    }
}

struct SalientText: Codable, Equatable, Identifiable {
    let text: String
    let category: SalienceCategory
    let salienceScore: Double
    let ocrConfidence: Double
    let reasons: [String]
    let boundingBox: NormalizedBoundingBox

    var id: String {
        "\(category.rawValue):\(text.lowercased())"
    }
}

struct ExtractedEntities: Codable, Equatable {
    let products: [String]
    let topics: [String]
    let places: [String]
    let dates: [String]
    let brandsAndSites: [String]
    let prices: [String]
    let sizes: [String]
}

struct ExtractedCategory: Codable, Equatable, Identifiable {
    let name: String
    let items: [String]

    var id: String { name }
}

struct AnalysisStatistics: Codable, Equatable {
    let ocrLineCount: Int
    let cleanedSegmentCount: Int
    let importantTextCount: Int
    let discardedLineCount: Int
}

enum SuggestedPromptAction: String, Codable, CaseIterable, Equatable {
    case discoverSimilar = "discover_similar"
    case findComplementary = "find_complementary"
    case exploreStyling = "explore_styling"
    case compareAlternatives = "compare_alternatives"
    case findIndependentReviews = "find_independent_reviews"
    case learnPrerequisite = "learn_prerequisite"
    case findLearningMaterial = "find_learning_material"
    case exploreApplications = "explore_applications"
    case learnNextTopic = "learn_next_topic"
    case findFlights = "find_flights"
    case discoverRestaurants = "discover_restaurants"
    case exploreDestination = "explore_destination"
    case planItinerary = "plan_itinerary"
    case codingAssistance = "coding_assistance"
    case debugIssue = "debug_issue"
    case testSolution = "test_solution"
    case findImplementationExamples = "find_implementation_examples"
    case productivityNextStep = "productivity_next_step"
    case summarizeWork = "summarize_work"
    case improveWorkflow = "improve_workflow"
    case discoverMedia = "discover_media"
    case generalAssistance = "general_assistance"
}

struct BuiltInPromptTemplateDefinition: Equatable, Identifiable {
    let subcategory: IntentSubcategory
    let action: SuggestedPromptAction
    let defaultText: String

    var id: String { Self.identifier(subcategory: subcategory, action: action) }

    static func identifier(
        subcategory: IntentSubcategory,
        action: SuggestedPromptAction
    ) -> String {
        "built-in:\(subcategory.rawValue):\(action.rawValue)"
    }
}

struct PromptTemplateOverride: Codable, Equatable, Identifiable {
    let id: String
    let subcategory: IntentSubcategory
    let action: SuggestedPromptAction
    var text: String
    var updatedAt: Date
}

struct CustomPromptTemplate: Codable, Equatable, Identifiable {
    let id: UUID
    var defaultIdentifier: String?
    var title: String?
    var action: SuggestedPromptAction
    var text: String
    var updatedAt: Date

    var displayTitle: String {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? action.displayName : value
    }

    init(
        id: UUID = UUID(),
        defaultIdentifier: String? = nil,
        title: String? = nil,
        action: SuggestedPromptAction,
        text: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.defaultIdentifier = defaultIdentifier
        self.title = title
        self.action = action
        self.text = text
        self.updatedAt = updatedAt
    }
}

struct BuiltInPromptSetOverride: Codable, Equatable, Identifiable {
    var id: String { subcategory.rawValue }
    let subcategory: IntentSubcategory
    var templates: [CustomPromptTemplate]
    var updatedAt: Date
}

struct CustomIntentCategory: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var categoryDescription: String
    var keywords: [String]
    var parentBehavior: IntentCategory
    var templates: [CustomPromptTemplate]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        categoryDescription: String,
        keywords: [String],
        parentBehavior: IntentCategory,
        templates: [CustomPromptTemplate],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.categoryDescription = categoryDescription
        self.keywords = keywords
        self.parentBehavior = parentBehavior
        self.templates = templates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PromptTemplateSettingsSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var overrides: [PromptTemplateOverride]
    var builtInPromptSets: [BuiltInPromptSetOverride]
    var customCategories: [CustomIntentCategory]

    init(
        schemaVersion: Int = 2,
        overrides: [PromptTemplateOverride] = [],
        builtInPromptSets: [BuiltInPromptSetOverride] = [],
        customCategories: [CustomIntentCategory] = []
    ) {
        self.schemaVersion = schemaVersion
        self.overrides = overrides
        self.builtInPromptSets = builtInPromptSets
        self.customCategories = customCategories
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, overrides, builtInPromptSets, customCategories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        overrides = try container.decodeIfPresent([PromptTemplateOverride].self, forKey: .overrides) ?? []
        builtInPromptSets = try container.decodeIfPresent(
            [BuiltInPromptSetOverride].self,
            forKey: .builtInPromptSets
        ) ?? []
        customCategories = try container.decodeIfPresent(
            [CustomIntentCategory].self,
            forKey: .customCategories
        ) ?? []
    }
}

extension SuggestedPromptAction {
    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// These paths are most useful as a ranked set of named things. Their
    /// expanded UI resolves every name to its own Safari destination instead
    /// of showing one generic listicle or broad "top 10" search.
    var prefersNamedResults: Bool {
        switch self {
        case .discoverSimilar, .findComplementary, .compareAlternatives,
             .exploreDestination, .discoverRestaurants, .findFlights,
             .discoverMedia:
            return true
        case .exploreStyling, .findIndependentReviews, .learnPrerequisite,
             .findLearningMaterial, .exploreApplications, .learnNextTopic,
             .planItinerary, .codingAssistance, .debugIssue, .testSolution,
             .findImplementationExamples, .productivityNextStep, .summarizeWork,
             .improveWorkflow, .generalAssistance:
            return false
        }
    }

    func answerShape(
        parentPrompt: String,
        option: SuggestedSearchOption
    ) -> PromptAnswerShape {
        if prefersNamedResults { return .namedList }

        let text = "\(parentPrompt) \(option.title) \(option.query)".lowercased()
        let explicitListCues = [
            "top 5", "top five", "top 10", "top ten", "list of",
            "alternatives", "similar products", "similar hotels",
            "recommended restaurants", "best restaurants", "best hotels"
        ]
        return explicitListCues.contains(where: text.contains)
            ? .namedList
            : .directAnswer
    }
}

enum PromptAnswerShape: String, Equatable {
    case directAnswer = "direct_answer"
    case namedList = "named_list"
}

enum PromptDirectAnswerMode: String, Equatable {
    case explanation
    case walkthrough
    case hints
    case solution

    static func infer(parentPrompt: String, option: SuggestedSearchOption) -> Self {
        let text = "\(parentPrompt) \(option.title) \(option.query)".lowercased()
        if ["step-by-step", "step by step", "walkthrough", "worked example", "trace through"]
            .contains(where: text.contains) {
            return .walkthrough
        }
        if ["hint", "nudge", "help me start"].contains(where: text.contains) {
            return .hints
        }
        if ["full solution", "solve this", "implementation", "write the code"]
            .contains(where: text.contains) {
            return .solution
        }
        return .explanation
    }
}

struct SuggestedSearchOption: Codable, Equatable, Identifiable {
    let title: String
    let query: String

    var id: String { "\(title.lowercased()):\(query.lowercased())" }
}

/// A selected next-step answer that Qwen should explain locally instead of
/// handing off to a browser search.
struct PromptSummaryRequest: Equatable {
    let subject: String
    let parentPrompt: String
    let option: SuggestedSearchOption
    let category: IntentCategory
    let visibleContext: [String]
    let webSearchResults: [WebSearchResult]
    let responseStyle: ResponseStyle
    let requestedNamedResultCount: Int
    let answerShape: PromptAnswerShape

    var directAnswerMode: PromptDirectAnswerMode {
        PromptDirectAnswerMode.infer(parentPrompt: parentPrompt, option: option)
    }

    init(
        subject: String,
        parentPrompt: String,
        option: SuggestedSearchOption,
        category: IntentCategory,
        visibleContext: [String],
        webSearchResults: [WebSearchResult] = [],
        responseStyle: ResponseStyle = .balanced,
        requestedNamedResultCount: Int = 0,
        answerShape: PromptAnswerShape? = nil
    ) {
        self.subject = subject
        self.parentPrompt = parentPrompt
        self.option = option
        self.category = category
        self.visibleContext = visibleContext
        self.webSearchResults = webSearchResults
        self.responseStyle = responseStyle
        self.requestedNamedResultCount = max(0, min(requestedNamedResultCount, 10))
        self.answerShape = answerShape ?? (
            requestedNamedResultCount > 0 ? .namedList : .directAnswer
        )
    }
}

struct PromptSummaryResult: Equatable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let model: String
    let query: String
    let webResults: [WebSearchResult]
    let isLiveWebGrounded: Bool
    let namedRecommendations: [String]
    let answerShape: PromptAnswerShape

    init(
        title: String,
        summary: String,
        keyPoints: [String],
        model: String,
        query: String = "",
        webResults: [WebSearchResult] = [],
        isLiveWebGrounded: Bool = false,
        namedRecommendations: [String] = [],
        answerShape: PromptAnswerShape? = nil
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.model = model
        self.query = query
        self.webResults = webResults
        self.isLiveWebGrounded = isLiveWebGrounded
        self.namedRecommendations = namedRecommendations
        self.answerShape = answerShape ?? (
            namedRecommendations.isEmpty ? .directAnswer : .namedList
        )
    }
}

struct PromptSummarySelection: Equatable {
    let prompt: IntentPromptSuggestion
    let option: SuggestedSearchOption

    var id: String { "\(prompt.id)::\(option.id)" }
}

struct PromptSummaryExpansionState: Equatable {
    let selection: PromptSummarySelection
    let summary: PromptSummaryResult?
    let error: String?
    let isGenerating: Bool
}

/// A deterministic specialist profile derived from Theia's classification and
/// visible screen evidence. Qwen adopts this profile instead of treating each
/// request as an unrelated general-knowledge question.
struct QwenContinuationContext: Codable, Equatable {
    let parentPrompt: String
    let selectedPath: String
    let existingAnswer: String
}

struct FieldAgentContext: Codable, Equatable {
    let category: IntentCategory
    let subcategory: IntentSubcategory?
    let activeSubject: String
    let field: String
    let specialistRole: String
    let sourceKind: String
    let userStage: String
    let assumptions: [String]
    let nearbyConcepts: [String]
    let continuationContext: QwenContinuationContext?

    init(
        category: IntentCategory,
        subcategory: IntentSubcategory?,
        activeSubject: String,
        field: String,
        specialistRole: String,
        sourceKind: String,
        userStage: String,
        assumptions: [String],
        nearbyConcepts: [String],
        continuationContext: QwenContinuationContext? = nil
    ) {
        self.category = category
        self.subcategory = subcategory
        self.activeSubject = activeSubject
        self.field = field
        self.specialistRole = specialistRole
        self.sourceKind = sourceKind
        self.userStage = userStage
        self.assumptions = assumptions
        self.nearbyConcepts = nearbyConcepts
        self.continuationContext = continuationContext
    }
}

enum QwenChatRole: String, Codable, Equatable {
    case user
    case assistant
}

struct QwenChatMessage: Codable, Equatable, Identifiable {
    let id: UUID
    let role: QwenChatRole
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: QwenChatRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

enum QwenChatMode: String, Codable, Equatable {
    case general
    case specialist
}

struct QwenChatConversation: Codable, Equatable, Identifiable {
    let id: UUID
    let mode: QwenChatMode
    var agentContext: FieldAgentContext
    var messages: [QwenChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        mode: QwenChatMode,
        agentContext: FieldAgentContext,
        messages: [QwenChatMessage],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.agentContext = agentContext
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var title: String {
        if let firstQuestion = messages.first(where: { $0.role == .user })?.text {
            return String(firstQuestion.prefix(56))
        }
        return mode == .general ? "General chat" : agentContext.activeSubject
    }

    var hasUserMessages: Bool {
        messages.contains { message in
            message.role == .user &&
                !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct WebSearchResult: Codable, Equatable, Identifiable {
    let rank: Int
    let title: String
    let snippet: String
    let sourceHost: String
    let url: String

    var id: String { "\(rank):\(url)" }
}

/// The exact main prompt shown in the analysis window and sent back to Qwen
/// when Theia asks for concrete, selectable follow-up paths.
struct PromptExpansionRequest: Equatable {
    let action: SuggestedPromptAction
    let mainPrompt: String
    let subject: String
    let contextHint: String?
    let agentContext: FieldAgentContext?
    let excludedChoices: [String]
    let isRepair: Bool
    let webSearchResults: [WebSearchResult]

    init(
        action: SuggestedPromptAction,
        mainPrompt: String,
        subject: String,
        contextHint: String? = nil,
        agentContext: FieldAgentContext? = nil,
        excludedChoices: [String] = [],
        isRepair: Bool = false,
        webSearchResults: [WebSearchResult] = []
    ) {
        self.action = action
        self.mainPrompt = mainPrompt
        self.subject = subject
        self.contextHint = contextHint
        self.agentContext = agentContext
        self.excludedChoices = excludedChoices
        self.isRepair = isRepair
        self.webSearchResults = webSearchResults
    }
}

struct PromptExpansionResult: Equatable {
    let action: SuggestedPromptAction
    let searchOptions: [SuggestedSearchOption]
}

enum PromptDiagnosticStage: String, Codable, Equatable {
    case initialGeneration = "initial_generation"
    case webResearch = "web_research"
    case repair
    case promptExpansion = "prompt_expansion"
}

struct PromptDiagnosticItem: Codable, Equatable, Identifiable {
    let index: Int
    let action: String?
    let target: String?
    let rationale: String?
    let evidence: [String]
    let searchOptions: [SuggestedSearchOption]
    let rawJSON: String

    var id: String { "\(index):\(action ?? "unknown")" }
}

struct PromptValidationRejection: Codable, Equatable, Identifiable {
    let action: String?
    let field: String
    let value: String?
    let reason: String

    var id: String {
        "\(action ?? "unknown"):\(field):\(value ?? "nil"):\(reason)"
    }
}

struct PromptStageDiagnostic: Codable, Equatable, Identifiable {
    let stage: PromptDiagnosticStage
    let requestedActions: [SuggestedPromptAction]
    let startedAt: Date
    let durationMilliseconds: Int
    let timeoutSeconds: Int
    let timedOut: Bool
    let succeeded: Bool
    let requestPrompt: String
    let rawResponse: String?
    let decodedItems: [PromptDiagnosticItem]
    let rejections: [PromptValidationRejection]
    let errorType: String?
    let errorMessage: String?
    /// Timing values reported by Ollama itself. These separate model loading,
    /// prompt ingestion, and token generation from Theia's total request time.
    let modelLoadMilliseconds: Int?
    let promptEvaluationMilliseconds: Int?
    let generationMilliseconds: Int?
    let inputTokenCount: Int?
    let outputTokenCount: Int?

    var id: String { "\(stage.rawValue):\(startedAt.timeIntervalSince1970)" }

    init(
        stage: PromptDiagnosticStage,
        requestedActions: [SuggestedPromptAction],
        startedAt: Date,
        durationMilliseconds: Int,
        timeoutSeconds: Int,
        timedOut: Bool,
        succeeded: Bool,
        requestPrompt: String,
        rawResponse: String?,
        decodedItems: [PromptDiagnosticItem],
        rejections: [PromptValidationRejection],
        errorType: String?,
        errorMessage: String?,
        modelLoadMilliseconds: Int? = nil,
        promptEvaluationMilliseconds: Int? = nil,
        generationMilliseconds: Int? = nil,
        inputTokenCount: Int? = nil,
        outputTokenCount: Int? = nil
    ) {
        self.stage = stage
        self.requestedActions = requestedActions
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.timeoutSeconds = timeoutSeconds
        self.timedOut = timedOut
        self.succeeded = succeeded
        self.requestPrompt = requestPrompt
        self.rawResponse = rawResponse
        self.decodedItems = decodedItems
        self.rejections = rejections
        self.errorType = errorType
        self.errorMessage = errorMessage
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.promptEvaluationMilliseconds = promptEvaluationMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
    }

    func addingRejections(_ additional: [PromptValidationRejection]) -> PromptStageDiagnostic {
        PromptStageDiagnostic(
            stage: stage,
            requestedActions: requestedActions,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            timeoutSeconds: timeoutSeconds,
            timedOut: timedOut,
            succeeded: succeeded,
            requestPrompt: requestPrompt,
            rawResponse: rawResponse,
            decodedItems: decodedItems,
            rejections: rejections + additional,
            errorType: errorType,
            errorMessage: errorMessage,
            modelLoadMilliseconds: modelLoadMilliseconds,
            promptEvaluationMilliseconds: promptEvaluationMilliseconds,
            generationMilliseconds: generationMilliseconds,
            inputTokenCount: inputTokenCount,
            outputTokenCount: outputTokenCount
        )
    }

    func replacingStage(_ replacement: PromptDiagnosticStage) -> PromptStageDiagnostic {
        PromptStageDiagnostic(
            stage: replacement,
            requestedActions: requestedActions,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            timeoutSeconds: timeoutSeconds,
            timedOut: timedOut,
            succeeded: succeeded,
            requestPrompt: requestPrompt,
            rawResponse: rawResponse,
            decodedItems: decodedItems,
            rejections: rejections,
            errorType: errorType,
            errorMessage: errorMessage,
            modelLoadMilliseconds: modelLoadMilliseconds,
            promptEvaluationMilliseconds: promptEvaluationMilliseconds,
            generationMilliseconds: generationMilliseconds,
            inputTokenCount: inputTokenCount,
            outputTokenCount: outputTokenCount
        )
    }
}

struct PromptExpansionModelResult: Equatable {
    let expansions: [PromptExpansionResult]
    let diagnostic: PromptStageDiagnostic
}

struct PromptModelCallFailure: LocalizedError {
    let diagnostic: PromptStageDiagnostic

    var errorDescription: String? {
        diagnostic.errorMessage ?? "The local prompt model call failed."
    }
}

struct IntentPromptSuggestion: Codable, Equatable, Identifiable {
    let text: String
    let action: SuggestedPromptAction
    let confidence: Double
    let rationale: String
    let evidence: [String]
    let searchOptions: [SuggestedSearchOption]

    var id: String { "\(action.rawValue):\(text.lowercased())" }
}

struct IntentPromptGeneration: Codable, Equatable {
    let model: String
    let prompts: [IntentPromptSuggestion]
    let error: String?
    let diagnostics: [PromptStageDiagnostic]?
    let agentContext: FieldAgentContext?
    let screenInsight: String?

    init(
        model: String,
        prompts: [IntentPromptSuggestion],
        error: String?,
        diagnostics: [PromptStageDiagnostic]? = nil,
        agentContext: FieldAgentContext? = nil,
        screenInsight: String? = nil
    ) {
        self.model = model
        self.prompts = prompts
        self.error = error
        self.diagnostics = diagnostics
        self.agentContext = agentContext
        self.screenInsight = screenInsight
    }
}

struct PreparedPromptContext: Equatable {
    let subject: String
    let agentContext: FieldAgentContext
    let payloadJSON: String
    let requests: [PromptExpansionRequest]
    let fallbackPrompts: [IntentPromptSuggestion]
}

struct ScreenContextReport: Codable, Equatable {
    let schemaVersion: String
    let generatedAt: Date
    let sourceContext: ScreenSourceContext
    let intent: IntentClassification
    let importantText: [SalientText]
    let entities: ExtractedEntities
    let categories: [ExtractedCategory]
    let cleanedSegments: [String]
    let statistics: AnalysisStatistics
    let promptGeneration: IntentPromptGeneration?
    let temporalFreshness: TemporalFreshnessAssessment?

    init(
        schemaVersion: String,
        generatedAt: Date,
        sourceContext: ScreenSourceContext,
        intent: IntentClassification,
        importantText: [SalientText],
        entities: ExtractedEntities,
        categories: [ExtractedCategory],
        cleanedSegments: [String],
        statistics: AnalysisStatistics,
        promptGeneration: IntentPromptGeneration?,
        temporalFreshness: TemporalFreshnessAssessment? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceContext = sourceContext
        self.intent = intent
        self.importantText = importantText
        self.entities = entities
        self.categories = categories
        self.cleanedSegments = cleanedSegments
        self.statistics = statistics
        self.promptGeneration = promptGeneration
        self.temporalFreshness = temporalFreshness
    }

    func addingPromptGeneration(_ generation: IntentPromptGeneration) -> ScreenContextReport {
        ScreenContextReport(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            sourceContext: sourceContext,
            intent: intent,
            importantText: importantText,
            entities: entities,
            categories: categories,
            cleanedSegments: cleanedSegments,
            statistics: statistics,
            promptGeneration: generation,
            temporalFreshness: temporalFreshness
        )
    }

    func replacingIntent(
        _ replacementIntent: IntentClassification,
        promptGeneration: IntentPromptGeneration? = nil
    ) -> ScreenContextReport {
        ScreenContextReport(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            sourceContext: sourceContext,
            intent: replacementIntent,
            importantText: importantText,
            entities: entities,
            categories: categories,
            cleanedSegments: cleanedSegments,
            statistics: statistics,
            promptGeneration: promptGeneration,
            temporalFreshness: temporalFreshness
        )
    }
}
