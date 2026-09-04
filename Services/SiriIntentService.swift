import AppIntents
import Foundation

enum TheiaSiriCommand: Sendable {
    case analyzeScreen
    case request(String)
    case showPrompt(String)
}

/// Local command URLs are the reliable bridge from user-created macOS
/// Shortcuts. Unlike iOS, macOS exposes App Intent actions but does not support
/// app-provided App Shortcut phrases.
enum TheiaCommandURL {
    static let scheme = "theia"

    static func command(from url: URL) -> TheiaSiriCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let action = (url.host ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func queryValue(named name: String) -> String? {
            queryItems.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        switch action {
        case "analyze", "analyze-screen":
            return .analyzeScreen
        case "ask":
            guard let request = queryValue(named: "request")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !request.isEmpty else { return nil }
            return .request(request)
        case "ask-base64":
            guard let encodedRequest = queryValue(named: "request"),
                  let data = Data(base64Encoded: encodedRequest),
                  let decodedRequest = String(data: data, encoding: .utf8) else { return nil }
            let request = decodedRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { return nil }
            return .request(request)
        case "show":
            guard let selection = queryValue(named: "selection")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selection.isEmpty else { return nil }
            return .showPrompt(selection)
        default:
            return nil
        }
    }
}

/// App Intents may arrive while macOS is launching this menu-bar app. Keep the
/// request until AppCoordinator exists, then execute it on the main actor.
@MainActor
enum TheiaSiriCommandRouter {
    private static weak var coordinator: AppCoordinator?
    private static var pendingCommands: [TheiaSiriCommand] = []

    static func connect(to coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let commands = pendingCommands
        pendingCommands.removeAll()
        commands.forEach(coordinator.handleSiriCommand)
    }

    static func submit(_ command: TheiaSiriCommand) {
        guard let coordinator else {
            pendingCommands.append(command)
            return
        }
        coordinator.handleSiriCommand(command)
    }
}

@available(macOS 13.0, *)
struct AnalyzeTheiaScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Screen with Theia"
    static var description = IntentDescription(
        "Captures the current window and asks Theia to understand it and suggest useful next steps."
    )
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await TheiaSiriCommandRouter.submit(.analyzeScreen)
        return .result(dialog: "Theia is analyzing your screen.")
    }
}

@available(macOS 13.0, *)
struct AskTheiaIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Theia"
    static var description = IntentDescription(
        "Sends a spoken request to Qwen in Theia, or runs a matching prompt command."
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(
        title: "Request",
        description: "What you want Theia or Qwen to do.",
        requestValueDialog: "What should I ask Theia?"
    )
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Theia \(\.$request)")
    }

    init() {}

    init(request: String) {
        self.request = request
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        await TheiaSiriCommandRouter.submit(.request(trimmedRequest))
        return .result(dialog: "I sent that to Theia.")
    }
}

@available(macOS 13.0, *)
enum TheiaPromptIdentifier: String, AppEnum {
    case one, two, three, four, five, six, seven, eight, nine, ten, eleven, twelve
    case letterA = "a"
    case letterB = "b"
    case letterC = "c"
    case letterD = "d"
    case letterE = "e"
    case letterF = "f"
    case letterG = "g"
    case letterH = "h"
    case letterI = "i"
    case letterJ = "j"
    case letterK = "k"
    case letterL = "l"
    case restaurants
    case topRestaurants = "top restaurants"
    case topTenRestaurants = "top ten restaurants"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Theia Prompt"
    static var caseDisplayRepresentations: [TheiaPromptIdentifier: DisplayRepresentation] = [
        .one: "One", .two: "Two", .three: "Three", .four: "Four",
        .five: "Five", .six: "Six", .seven: "Seven", .eight: "Eight",
        .nine: "Nine", .ten: "Ten", .eleven: "Eleven", .twelve: "Twelve",
        .letterA: "A", .letterB: "B", .letterC: "C", .letterD: "D",
        .letterE: "E", .letterF: "F", .letterG: "G", .letterH: "H",
        .letterI: "I", .letterJ: "J", .letterK: "K", .letterL: "L",
        .restaurants: "Restaurants",
        .topRestaurants: "Top restaurants",
        .topTenRestaurants: "The top ten restaurants"
    ]
}

@available(macOS 13.0, *)
struct ShowTheiaPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Show a Theia Prompt"
    static var description = IntentDescription(
        "Expands a numbered, lettered, or named prompt from Theia's latest screen analysis."
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Prompt", requestValueDialog: "Which Theia prompt should I show?")
    var selection: TheiaPromptIdentifier

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$selection) in Theia")
    }

    init() {}

    init(selection: TheiaPromptIdentifier) {
        self.selection = selection
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await TheiaSiriCommandRouter.submit(.showPrompt(selection.rawValue))
        return .result(dialog: "Theia is opening that prompt.")
    }
}

@available(macOS 13.0, *)
struct TheiaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnalyzeTheiaScreenIntent(),
            phrases: [
                "Analyze my screen with \(.applicationName)",
                "Ask \(.applicationName) to analyze my screen",
                "Analyze this screen using \(.applicationName)",
                "Use \(.applicationName) to analyze my screen",
                "\(.applicationName) analyze my screen"
            ],
            shortTitle: "Analyze Screen",
            systemImageName: "viewfinder"
        )

        AppShortcut(
            intent: AskTheiaIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Ask Theia",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ShowTheiaPromptIntent(),
            phrases: [
                "Show \(\.$selection) in \(.applicationName)",
                "Ask \(.applicationName) to show \(\.$selection)",
                "Ask \(.applicationName) to show me \(\.$selection)",
                "Use \(.applicationName) to show \(\.$selection)",
                "\(.applicationName) show \(\.$selection)"
            ],
            shortTitle: "Show Prompt",
            systemImageName: "list.number"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .navy }
}
