import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator: NSObject, ObservableObject {
    private enum WindowFrameName {
        static let settings = "Theia.Settings"
        static let onboarding = "Theia.Onboarding"
        static let promptResults = "Theia.PromptResults"
        static let qwenChat = "Theia.QwenChat"
        static let chatHistory = "Theia.ChatHistory"
        static let developer = "Theia.Developer"
    }

    private enum WebSearchConsentDecision {
        case allow
        case offline
        case cancel
    }

    private enum ManagedPage: Equatable {
        case analysis
        case onboarding
        case settings
        case promptResults
        case qwenChat
        case chatHistory
    }

    private struct PromptSummaryTaskRecord {
        let requestID: UUID
        let task: Task<Void, Never>
    }

    let state = AppState()

    private static let onboardingCompletedKey = "theia.onboarding.completed"

    private let captureService = ScreenCaptureService()
    private let ocrService = OCRService()
    private let contextAnalysisService = ContextAnalysisService()
    private let sourceContextService = SourceContextService()
    private var intentClassificationService = IntentClassificationService()
    private var intentPromptSuggestionService = IntentPromptSuggestionService()
    private var promptSummaryService = PromptSummaryService()
    private var qwenChatService = QwenChatService()
    private var qwenVisionPromptService = QwenVisionPromptService()
    private let fieldAgentContextService = FieldAgentContextService()
    private let analysisJSONService = AnalysisJSONService()
    private let installedAppURL = URL(fileURLWithPath: "/Applications/Theia.app", isDirectory: true)
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var analysisPanel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var promptResultsPanel: TheiaPromptPanel?
    private var qwenChatPanel: TheiaPromptPanel?
    private var chatHistoryPanel: TheiaPromptPanel?
    private var analysisTask: Task<Void, Never>?
    private var activeAnalysisID: UUID?
    private var promptSummaryTasks: [String: PromptSummaryTaskRecord] = [:]
    private var qwenChatTask: Task<Void, Never>?
    private var localModelSwitchTask: Task<Void, Never>?
    private var pendingPromptOrigin: NSRect?
    private var activePromptOrigin: NSRect?
    private var promptResultsFrameBeforeGeneration: NSRect?

    override init() {
        super.init()
        TheiaSiriCommandRouter.connect(to: self)
        DispatchQueue.main.async { [weak self] in
            self?.configureStatusItem()
            self?.showOnboardingIfNeeded()
        }
    }

    func openSiriSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.siri"
        ]
        for rawURL in settingsURLs {
            if let url = URL(string: rawURL), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openShortcutsApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.shortcuts"
        ) else {
            state.latestError = "The Shortcuts app could not be found on this Mac."
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func analyzeScreen() {
        if relaunchInstalledCopyIfNeeded() {
            return
        }

        let requestedOrigin = menuBarIconFrame() ?? menuBarFallbackOrigin(on: NSScreen.main)
        statusPopover?.performClose(nil)
        analysisTask?.cancel()
        closePromptResults()
        pendingPromptOrigin = requestedOrigin
        state.resetForAnalysis()
        let analysisID = UUID()
        activeAnalysisID = analysisID
        let sourceContext = sourceContextService.capture()
        let targetWindowID = captureService.frontmostWindowID()
        analysisTask = Task { [weak self] in
            await self?.runAnalysis(
                analysisID: analysisID,
                sourceContext: sourceContext,
                targetWindowID: targetWindowID
            )
        }
    }

    func handleSiriCommand(_ siriCommand: TheiaSiriCommand) {
        switch siriCommand {
        case .analyzeScreen:
            state.lastSiriRequest = "Analyze my screen"
            analyzeScreen()
        case .request(let request):
            handleNaturalLanguageCommand(request)
        case .showPrompt(let selection):
            if state.analysisReport == nil {
                loadAndShowLastAnalysis()
                guard state.analysisReport != nil else {
                    showAnalysisPanel()
                    return
                }
            }
            handleNaturalLanguageCommand("show \(selection)")
        }
    }

    private func handleNaturalLanguageCommand(_ request: String) {
        let command = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        state.lastSiriRequest = command
        let prompts = state.analysisReport?.promptGeneration?.prompts ?? []
        switch SiriCommandInterpreter.resolve(
            request: command,
            prompts: prompts,
            pathsPerPrompt: VisibleSubpromptLimit.current
        ) {
        case .analyzeScreen:
            analyzeScreen()
        case .expandPrompt(let selection, let resultLimit):
            summarizePrompt(
                selection.option,
                for: selection.prompt,
                resultLimit: resultLimit
            )
        case .chat(let message):
            showGeneralQwenChat()
            sendQwenChatMessage(message)
        }
    }

    func cancelAnalysis() {
        guard state.currentStatus.isWorking else { return }
        activeAnalysisID = nil
        analysisTask?.cancel()
        analysisTask = nil
        pendingPromptOrigin = nil
        state.currentStatus = .cancelled
        state.latestError = nil
        state.classificationProgress = []
    }

    func showLastAnalysis() {
        pendingPromptOrigin = menuBarIconFrame() ?? menuBarFallbackOrigin(on: NSScreen.main)
        statusPopover?.performClose(nil)
        loadAndShowLastAnalysis()
    }

    private func loadAndShowLastAnalysis() {
        cancelAllPromptSummaryTasks()
        state.resetPromptSummary()
        do {
            let saved = try analysisJSONService.loadLatest()
            state.currentStatus = .complete
            state.ocrOutput = saved.report.cleanedSegments.joined(separator: "\n")
            state.lastImage = nil
            state.latestError = nil
            state.analysisReport = saved.report
            state.analysisJSON = saved.json
            state.analysisJSONFileURL = saved.fileURL
            state.classificationProgress = []
        } catch {
            state.currentStatus = .failed
            state.latestError = "The last analysis could not be opened. \(error.localizedDescription)"
        }
        if state.analysisReport?.promptGeneration != nil {
            showPromptResults()
        }
    }

    func showDeveloperUI() {
        if state.analysisReport == nil {
            do {
                let saved = try analysisJSONService.loadLatest()
                state.currentStatus = .complete
                state.ocrOutput = saved.report.cleanedSegments.joined(separator: "\n")
                state.analysisReport = saved.report
                state.analysisJSON = saved.json
                state.analysisJSONFileURL = saved.fileURL
                state.latestError = nil
            } catch {
                state.latestError = "No saved analysis is available yet."
            }
        }
        showAnalysisPanel()
    }

    func showGeneralQwenChat() {
        showQwenChat(
            context: fieldAgentContextService.generalContext(),
            mode: .general
        )
    }

    func showSpecializedQwenChat() {
        showQwenChat(context: activeFieldAgentContext(), mode: .specialist)
    }

    private func showQwenChat(context: FieldAgentContext, mode: QwenChatMode) {
        statusPopover?.performClose(nil)
        hideManagedWindows(except: .qwenChat)
        state.startNewQwenChat(with: context, mode: mode)
        presentQwenChatPanel()
    }

    private func presentQwenChatPanel() {
        hideManagedWindows(except: .qwenChat)

        if qwenChatPanel == nil {
            let rootView = QwenChatView()
                .environmentObject(self)
                .environmentObject(state)
            let panel = TheiaPromptPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 500, height: 600)
            configureWindowLevel(panel)
            panel.appearance = AppearanceMode.current.nsAppearance
            panel.contentView = NSHostingView(
                rootView: rootView.clipShape(RoundedRectangle(cornerRadius: 24))
            )
            panel.hasPersistentPlacement = restorePersistentFrame(
                for: panel,
                name: WindowFrameName.qwenChat
            )
            qwenChatPanel = panel
        }

        qwenChatPanel?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeQwenChat() {
        qwenChatPanel?.orderOut(nil)
    }

    func clearQwenChat() {
        qwenChatTask?.cancel()
        qwenChatTask = nil
        state.startNewQwenChat()
    }

    func selectQwenChatConversation(_ id: UUID) {
        qwenChatTask?.cancel()
        qwenChatTask = nil
        state.selectQwenChatConversation(id)
        statusPopover?.performClose(nil)
        chatHistoryPanel?.orderOut(nil)
        presentQwenChatPanel()
    }

    func showChatHistory() {
        statusPopover?.performClose(nil)
        hideManagedWindows(except: .chatHistory)
        if chatHistoryPanel == nil {
            let rootView = ChatHistoryView()
                .environmentObject(self)
                .environmentObject(state)
            let panel = TheiaPromptPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 560, height: 560)
            configureWindowLevel(panel)
            panel.appearance = AppearanceMode.current.nsAppearance
            panel.contentView = NSHostingView(
                rootView: rootView.clipShape(RoundedRectangle(cornerRadius: 24))
            )
            panel.hasPersistentPlacement = restorePersistentFrame(
                for: panel,
                name: WindowFrameName.chatHistory
            )
            chatHistoryPanel = panel
        }
        chatHistoryPanel?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeChatHistory() {
        chatHistoryPanel?.orderOut(nil)
    }

    func deleteQwenChatConversation(_ id: UUID) {
        if state.activeQwenChatConversationID == id {
            qwenChatTask?.cancel()
            qwenChatTask = nil
        }
        state.deleteQwenChatConversation(id)
    }

    func applyAppearancePreference(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: TheiaPreferenceKey.appearanceMode)
        let appearance = mode.nsAppearance
        NSApplication.shared.appearance = appearance
        statusPopover?.appearance = appearance
        analysisPanel?.appearance = appearance
        onboardingWindow?.appearance = appearance
        settingsWindow?.appearance = appearance
        promptResultsPanel?.appearance = appearance
        qwenChatPanel?.appearance = appearance
        chatHistoryPanel?.appearance = appearance

        let windows = [
            analysisPanel,
            onboardingWindow,
            settingsWindow,
            promptResultsPanel,
            qwenChatPanel,
            chatHistoryPanel,
            statusPopover?.contentViewController?.view.window
        ].compactMap { $0 }
        for window in windows {
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.contentView?.needsDisplay = true
        }
        objectWillChange.send()
    }

    func applyDeveloperUIPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: TheiaPreferenceKey.developerUIEnabled)
        if !enabled {
            analysisPanel?.orderOut(nil)
        }
        objectWillChange.send()
    }

    func applyWindowAlwaysOnTopPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: TheiaPreferenceKey.windowAlwaysOnTop)
        for window in managedWindows {
            configureWindowLevel(window)
        }
        objectWillChange.send()
    }

    func applyLocalModelPreference(_ modelName: String) {
        let selected = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        UserDefaults.standard.set(selected, forKey: TheiaPreferenceKey.qwenModel)
        guard selected != state.activeLocalModelName else { return }

        if state.currentStatus.isWorking { cancelAnalysis() }
        cancelAllPromptSummaryTasks()
        qwenChatTask?.cancel()
        localModelSwitchTask?.cancel()
        state.beginLocalModelSwitch(to: selected)
        let previous = state.activeLocalModelName

        localModelSwitchTask = Task { [weak self] in
            do {
                try await OllamaRuntimeManager.shared.prepare(model: selected)
                try Task.checkCancellation()
                await OllamaRuntimeManager.shared.unload(model: previous)
                try Task.checkCancellation()
                guard let self else { return }
                intentClassificationService = IntentClassificationService()
                intentPromptSuggestionService = IntentPromptSuggestionService()
                promptSummaryService = PromptSummaryService()
                qwenChatService = QwenChatService()
                qwenVisionPromptService = QwenVisionPromptService()
                state.finishLocalModelSwitch(to: selected)
            } catch is CancellationError {
                return
            } catch {
                self?.state.failLocalModelSwitch(
                    "Could not activate \(selected). \(error.localizedDescription)"
                )
            }
        }
    }

    func sendQwenChatMessage(_ rawMessage: String) {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = state.qwenChatImageAttachment
        guard (!message.isEmpty || attachment != nil), !state.isQwenChatResponding else { return }

        let context = state.qwenChatAgentContext ?? fieldAgentContextService.generalContext()
        state.prepareQwenChat(with: context, mode: state.qwenChatMode)
        let displayMessage: String
        if let attachment {
            let request = message.isEmpty
                ? "Inspect this screenshot, predict what I’m doing, and suggest the next useful steps."
                : message
            displayMessage = "\(request)\n\n📷 \(attachment.fileName)"
        } else {
            displayMessage = message
        }
        state.appendQwenChatMessage(
            QwenChatMessage(role: .user, text: String(displayMessage.prefix(4_000)))
        )
        state.qwenChatImageAttachment = nil
        state.qwenChatError = nil
        state.isQwenChatResponding = true
        let conversation = state.qwenChatMessages
        let conversationID = state.activeQwenChatConversationID

        qwenChatTask?.cancel()
        qwenChatTask = Task { [weak self] in
            guard let self else { return }
            var streamingMessageID: UUID?
            do {
                let responses = qwenChatService.streamedReply(
                    to: conversation,
                    agentContext: context,
                    screenshotPNGData: attachment?.pngData
                )
                for try await response in responses {
                    try Task.checkCancellation()
                    guard state.activeQwenChatConversationID == conversationID else { return }
                    let safeResponse = QwenVisibleOutputSanitizer.sanitize(response)
                    guard !safeResponse.isEmpty,
                          !QwenVisibleOutputSanitizer.containsMetaNarration(safeResponse)
                    else { continue }
                    if let streamingMessageID {
                        state.updateStreamingQwenResponse(id: streamingMessageID, text: safeResponse)
                    } else {
                        streamingMessageID = state.beginStreamingQwenResponse(safeResponse)
                    }
                }
                guard streamingMessageID != nil else { throw LocalModelError.invalidChat }
                state.finishStreamingQwenResponse()
                state.isQwenChatResponding = false
            } catch is CancellationError {
                if state.activeQwenChatConversationID == conversationID {
                    state.isQwenChatResponding = false
                }
            } catch {
                guard state.activeQwenChatConversationID == conversationID else { return }
                state.qwenChatError = "Qwen could not answer. \(error.localizedDescription)"
                state.isQwenChatResponding = false
            }
        }
    }

    func chooseQwenChatScreenshot() {
        guard !state.isQwenChatResponding else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach a screenshot"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let sourceData = try Data(contentsOf: url)
            guard let image = NSImage(data: sourceData),
                  let pngData = pngData(from: image)
            else {
                state.qwenChatError = "That image could not be prepared for Qwen3-VL."
                return
            }
            guard pngData.count <= 20 * 1_024 * 1_024 else {
                state.qwenChatError = "The screenshot is too large. Please choose an image under 20 MB."
                return
            }
            state.qwenChatImageAttachment = QwenChatImageAttachment(
                fileName: url.lastPathComponent,
                pngData: pngData,
                preview: image
            )
            state.qwenChatError = nil
        } catch {
            state.qwenChatError = "The screenshot could not be opened. \(error.localizedDescription)"
        }
    }

    func removeQwenChatScreenshot() {
        guard !state.isQwenChatResponding else { return }
        state.qwenChatImageAttachment = nil
    }

    func closePromptResults() {
        cancelAllPromptSummaryTasks()
        state.resetPromptSummary()
        guard let panel = promptResultsPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                self?.activePromptOrigin = nil
            }
        }
    }

    func openScreenRecordingSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording"
        ]

        guard let url = settingsURLs.compactMap(URL.init(string:)).first else { return }

        NSWorkspace.shared.open(url)
    }

    func showScreenRecordingPermissionGuide() {
        state.currentStatus = .permissionRequired
        state.latestError = """
        macOS requires Screen Recording permission to be granted manually. To make it persistent, run /Applications/Theia.app and enable that app in System Settings.
        """
        showAnalysisPanel()
        openScreenRecordingSettings()
    }

    func showSettings() {
        statusPopover?.performClose(nil)
        hideManagedWindows(except: .settings)

        if settingsWindow == nil {
            let rootView = TheiaSettingsView()
                .environmentObject(self)
                .environmentObject(state)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Theia Settings"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 560)
            configureWindowLevel(window)
            window.appearance = AppearanceMode.current.nsAppearance
            window.contentView = NSHostingView(rootView: rootView)
            restorePersistentFrame(for: window, name: WindowFrameName.settings)
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func restartInstalledApp() {
        guard FileManager.default.fileExists(atPath: installedAppURL.path) else {
            showMissingInstalledAppError()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: installedAppURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    self.state.latestError = "Could not restart /Applications/Theia.app. \(error.localizedDescription)"
                    self.showAnalysisPanel()
                    return
                }

                NSApplication.shared.terminate(nil)
            }
        }
    }

    func revealInstalledApp() {
        guard FileManager.default.fileExists(atPath: installedAppURL.path) else {
            showMissingInstalledAppError()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([installedAppURL])
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func revealAnalysisJSON() {
        guard let fileURL = state.analysisJSONFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func copyAnalysisJSON() {
        guard !state.analysisJSON.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.analysisJSON, forType: .string)
    }

    func openSearchInSafari(_ rawQuery: String) {
        let query = QwenVisibleOutputSanitizer.sanitize(rawQuery)
        guard !query.isEmpty else { return }

        guard let searchURL = SearchEngine.current.searchURL(for: query) else {
            state.latestError = "The search query could not be converted into a Safari URL."
            return
        }

        openURLInSafari(searchURL.absoluteString)
    }

    func openURLInSafari(_ rawURL: String) {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            state.latestError = "The selected result does not have a valid web address."
            return
        }

        guard let safariURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else {
            state.latestError = "Safari could not be found on this Mac."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: safariURL,
            configuration: configuration
        ) { _, error in
            if let error {
                Task { @MainActor in
                    self.state.latestError = "Safari could not open the search. \(error.localizedDescription)"
                }
            }
        }
    }

    func summarizePrompt(
        _ option: SuggestedSearchOption,
        for prompt: IntentPromptSuggestion,
        resultLimit: Int = 8
    ) {
        let selection = PromptSummarySelection(prompt: prompt, option: option)
        guard let report = state.analysisReport else {
            state.beginPromptSummary(selection)
            state.failPromptSummary(
                "The screen context is no longer available for this summary.",
                for: selection
            )
            return
        }
        let answerShape = prompt.action.answerShape(
            parentPrompt: prompt.text,
            option: option
        )
        let requestedSourceCount = answerShape == .namedList
            ? max(5, min(resultLimit, 10))
            : max(1, min(resultLimit, 3))

        let useLiveSearch: Bool
        switch InternetAccessPolicy.current {
        case .automatic:
            useLiveSearch = true
        case .never:
            useLiveSearch = false
        case .ask:
            let requirement = WebResearchRequirement(
                mode: .requiredForFreshness,
                title: "Ground This Qwen Answer with Live Search?",
                message: "Allow Theia to search the public web for up to \(requestedSourceCount) results, let Qwen summarize that evidence, and show a Safari link for every source?\n\nQuery: \(option.query)"
            )
            switch requestWebSearchConsent(requirement, cancelButtonTitle: "Cancel") {
            case .allow:
                useLiveSearch = true
            case .offline:
                useLiveSearch = false
            case .cancel:
                return
            }
        }

        promptSummaryTasks[selection.id]?.task.cancel()
        state.beginPromptSummary(selection)
        if promptResultsPanel?.isVisible != true {
            pendingPromptOrigin = menuBarIconFrame() ?? menuBarFallbackOrigin(on: NSScreen.main)
            showPromptResults()
        }

        let requestID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await promptSummaryService.summarize(
                    option: option,
                    for: prompt,
                    report: report,
                    useLiveSearch: useLiveSearch,
                    resultLimit: resultLimit
                )
                try Task.checkCancellation()
                guard promptSummaryTasks[selection.id]?.requestID == requestID else { return }
                guard state.promptSummaryExpansion(for: selection) != nil else { return }
                state.finishPromptSummary(summary, for: selection)
                promptSummaryTasks[selection.id] = nil
                restorePromptResultsAfterGenerationIfIdle()
            } catch is CancellationError {
                if promptSummaryTasks[selection.id]?.requestID == requestID {
                    promptSummaryTasks[selection.id] = nil
                    restorePromptResultsAfterGenerationIfIdle()
                }
                return
            } catch {
                guard promptSummaryTasks[selection.id]?.requestID == requestID else { return }
                guard state.promptSummaryExpansion(for: selection) != nil else { return }
                state.failPromptSummary(
                    "Qwen could not summarize this answer. \(error.localizedDescription)",
                    for: selection
                )
                promptSummaryTasks[selection.id] = nil
                restorePromptResultsAfterGenerationIfIdle()
            }
        }
        promptSummaryTasks[selection.id] = PromptSummaryTaskRecord(
            requestID: requestID,
            task: task
        )
        collapsePromptResultsDuringGeneration()
    }

    func continuePromptInQwen(
        _ selection: PromptSummarySelection,
        summary: PromptSummaryResult
    ) {
        qwenChatTask?.cancel()
        qwenChatTask = nil
        let parts = [summary.summary] + summary.keyPoints + summary.namedRecommendations
        let answer = parts
            .map(QwenVisibleOutputSanitizer.sanitize)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let context = fieldAgentContextService.continuingContext(
            from: activeFieldAgentContext(),
            parentPrompt: selection.prompt.text,
            selectedPath: selection.option.title,
            existingAnswer: answer
        )
        // Preserve the selected material as reference context without turning it
        // into inherited user/assistant history. Qwen starts from the same clean
        // conversation state and model path as every new chat.
        state.startNewQwenChat(with: context, mode: .specialist)
        statusPopover?.performClose(nil)
        hideManagedWindows(except: .qwenChat)
        presentQwenChatPanel()
    }

    func dismissPromptSummary(_ selection: PromptSummarySelection) {
        promptSummaryTasks[selection.id]?.task.cancel()
        promptSummaryTasks[selection.id] = nil
        state.dismissPromptSummary(selection)
        restorePromptResultsAfterGenerationIfIdle()
    }

    private func cancelAllPromptSummaryTasks() {
        promptSummaryTasks.values.forEach { $0.task.cancel() }
        promptSummaryTasks.removeAll()
        restorePromptResultsAfterGenerationIfIdle()
    }

    private func collapsePromptResultsDuringGeneration() {
        guard promptResultsFrameBeforeGeneration == nil,
              let panel = promptResultsPanel,
              panel.isVisible,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        promptResultsFrameBeforeGeneration = panel.frame
        // Avoid persisting the temporary off-screen position as the user's
        // chosen window placement.
        panel.setFrameAutosaveName("")
        let visible = screen.visibleFrame
        let exposedCorner: CGFloat = 76
        let tuckedFrame = NSRect(
            x: visible.maxX - exposedCorner,
            y: visible.minY - panel.frame.height + exposedCorner,
            width: panel.frame.width,
            height: panel.frame.height
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(tuckedFrame, display: true)
            panel.animator().alphaValue = 0.82
        }
    }

    private func restorePromptResultsAfterGenerationIfIdle() {
        guard promptSummaryTasks.isEmpty,
              let originalFrame = promptResultsFrameBeforeGeneration,
              let panel = promptResultsPanel
        else { return }
        promptResultsFrameBeforeGeneration = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(originalFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: {
            panel.setFrameAutosaveName(WindowFrameName.promptResults)
        }
    }

    private func relaunchInstalledCopyIfNeeded() -> Bool {
        let currentAppURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedAppURL = installedAppURL.resolvingSymlinksInPath().standardizedFileURL

        guard currentAppURL != expectedAppURL,
              FileManager.default.fileExists(atPath: expectedAppURL.path)
        else {
            return false
        }

        state.currentStatus = .permissionRequired
        state.latestError = """
        This copy of Theia is running from \(currentAppURL.path). Screen Recording permission should be granted to /Applications/Theia.app, so Theia is reopening the installed copy now.
        """

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: expectedAppURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    self.showAnalysisPanel()
                    self.state.latestError = "Could not open /Applications/Theia.app. \(error.localizedDescription)"
                }
                return
            }

            NSApplication.shared.terminate(nil)
        }

        return true
    }

    private func showMissingInstalledAppError() {
        state.currentStatus = .permissionRequired
        state.latestError = "The installed app was not found at /Applications/Theia.app. Build or copy Theia there, then try again."
        showAnalysisPanel()
    }

    private func runAnalysis(
        analysisID: UUID,
        sourceContext: ScreenSourceContext,
        targetWindowID: CGWindowID?
    ) async {
        guard isActiveAnalysis(analysisID) else { return }
        if !captureService.hasScreenRecordingPermission() {
            state.currentStatus = .requestingPermission

            guard captureService.requestScreenRecordingPermission() else {
                guard isActiveAnalysis(analysisID) else { return }
                state.currentStatus = .permissionRequired
                state.latestError = "Screen Recording permission was denied. Enable it in System Settings before trying again."
                finishAnalysis(analysisID)
                return
            }

            guard isActiveAnalysis(analysisID) else { return }
            state.currentStatus = .permissionRequired
            state.latestError = """
            Screen Recording permission was requested. macOS applies this permission after Theia restarts, so quit and reopen /Applications/Theia.app before analyzing again.
            """
            finishAnalysis(analysisID)
            return
        }

        guard captureService.hasScreenRecordingPermission() else {
            guard isActiveAnalysis(analysisID) else { return }
            state.currentStatus = .permissionRequired
            state.latestError = "Screen Recording permission is not active yet. Enable it in System Settings, then quit and reopen Theia."
            finishAnalysis(analysisID)
            return
        }

        guard isActiveAnalysis(analysisID) else { return }

        let frame: CapturedFrame

        state.currentStatus = .capturing
        do {
            frame = try await captureService.captureFrontmostWindow(
                preferredWindowID: targetWindowID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isActiveAnalysis(analysisID) else { return }
            state.latestError = "Screen capture failed. \(error.localizedDescription)"
            state.currentStatus = .failed
            finishAnalysis(analysisID)
            return
        }

        guard isActiveAnalysis(analysisID) else { return }

        state.lastImage = frame.image
        state.currentStatus = .recognizingText

        let document: OCRDocument
        do {
            document = try await ocrService.recognizeText(in: frame)
        } catch is CancellationError {
            return
        } catch {
            guard isActiveAnalysis(analysisID) else { return }
            state.latestError = "Vision OCR failed unexpectedly. \(error.localizedDescription)"
            state.currentStatus = .failed
            finishAnalysis(analysisID)
            return
        }

        guard isActiveAnalysis(analysisID) else { return }

        let text = document.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if QwenVisionRoutingPolicy.usesVisionForScreen(
            selectedModel: state.activeLocalModelName
        ) {
            state.ocrOutput = document.lines.map(\.text).joined(separator: "\n")
            state.currentStatus = .analyzingVision
            do {
                guard let imageData = pngData(from: frame.cgImage) else {
                    throw QwenVisionPromptError.imageEncodingFailed
                }
                let visionResult = try await qwenVisionPromptService.analyzeAndGeneratePrompts(
                    pngData: imageData,
                    sourceContext: sourceContext,
                    mode: .activityNextSteps
                )
                guard isActiveAnalysis(analysisID) else { return }
                let report = reportFromVision(
                    visionResult,
                    document: document,
                    sourceContext: sourceContext,
                    replacing: nil
                )
                publishAndSave(report, analysisID: analysisID)
            } catch is CancellationError {
                return
            } catch {
                guard isActiveAnalysis(analysisID) else { return }
                state.latestError = "Qwen3-VL could not analyze this screenshot. \(error.localizedDescription)"
                state.currentStatus = .failed
                finishAnalysis(analysisID)
            }
            return
        }

        guard !text.isEmpty else {
            // A diagram, photo, canvas, or other visual screen can legitimately
            // contain no OCR. Treat that as a vision-first capture instead of a
            // failed analysis.
            state.ocrOutput = "No reliable text was detected; Qwen3-VL inspected the visual content."
            state.currentStatus = .analyzingVision
            do {
                guard let imageData = pngData(from: frame.cgImage) else {
                    throw QwenVisionPromptError.imageEncodingFailed
                }
                let visionResult = try await qwenVisionPromptService.analyzeAndGeneratePrompts(
                    pngData: imageData,
                    sourceContext: sourceContext,
                    mode: .activityNextSteps
                )
                guard isActiveAnalysis(analysisID) else { return }
                let report = reportFromVision(
                    visionResult,
                    document: document,
                    sourceContext: sourceContext,
                    replacing: nil
                )
                publishAndSave(report, analysisID: analysisID)
            } catch is CancellationError {
                return
            } catch {
                guard isActiveAnalysis(analysisID) else { return }
                state.latestError = "The screen had no readable text, and Qwen3-VL could not inspect its visual content. \(error.localizedDescription)"
                state.currentStatus = .failed
                finishAnalysis(analysisID)
            }
            return
        }

        state.currentStatus = .analyzingContext
        let analyzedReport = await contextAnalysisService.analyze(
            document,
            sourceContext: sourceContext,
            intentClassifier: intentClassificationService,
            onClassificationProgress: { [weak self] progress in
                guard self?.activeAnalysisID == analysisID else { return }
                self?.state.classificationProgress = progress
            }
        )
        guard isActiveAnalysis(analysisID) else { return }

        // Replace the raw Vision dump with the human-reading-order version once
        // geometry-aware cleanup and heading reconstruction have completed.
        state.ocrOutput = analyzedReport.cleanedSegments.joined(separator: "\n")

        // Once rules, BERT, or text-Qwen has established a known activity, keep
        // the fast OCR/template result. A decorative product photo, diagram, or
        // thumbnail must not trigger a second full vision inference. Qwen3-VL is
        // automatic only when the classifier deliberately leaves the screen as
        // `Other`; users can still choose Qwen3-VL explicitly in Models or attach
        // the screenshot in chat when they want pixel-level explanation.
        let visionMode: QwenVisionPromptMode? = QwenVisionRoutingPolicy
            .usesVisionFallback(for: analyzedReport.intent.category)
            ? .otherFallback
            : nil

        if let visionMode {
            state.currentStatus = .analyzingVision
            do {
                guard let imageData = pngData(from: frame.cgImage) else {
                    throw QwenVisionPromptError.imageEncodingFailed
                }
                let visionResult = try await qwenVisionPromptService.analyzeAndGeneratePrompts(
                    pngData: imageData,
                    sourceContext: analyzedReport.sourceContext,
                    mode: visionMode,
                    ocrGroundingReport: analyzedReport
                )
                guard isActiveAnalysis(analysisID) else { return }
                let report = reportFromVision(
                    visionResult,
                    document: document,
                    sourceContext: analyzedReport.sourceContext,
                    replacing: analyzedReport
                )
                publishAndSave(report, analysisID: analysisID)
                return
            } catch is CancellationError {
                return
            } catch {
                guard isActiveAnalysis(analysisID) else { return }
                if analyzedReport.intent.category == .other {
                    state.latestError = "Qwen3-VL could not complete the open-ended screen response. \(error.localizedDescription)"
                }
            }
        }

        state.currentStatus = .generatingPrompts
        let promptGeneration: IntentPromptGeneration
        if analyzedReport.intent.category == .other {
            promptGeneration = intentPromptSuggestionService
                .generateUntemplatedOtherFallback(for: analyzedReport)
        } else {
            do {
                promptGeneration = try intentPromptSuggestionService
                    .generateFastTemplates(for: analyzedReport)
            } catch {
                promptGeneration = IntentPromptGeneration(
                    model: "Theia Templates",
                    prompts: [],
                    error: "The fast prompt templates could not be prepared. \(error.localizedDescription)"
                )
            }
        }

        guard isActiveAnalysis(analysisID) else { return }
        let report = analyzedReport.addingPromptGeneration(promptGeneration)
        publishAndSave(report, analysisID: analysisID)
    }

    private func publishAndSave(
        _ report: ScreenContextReport,
        analysisID: UUID
    ) {
        guard isActiveAnalysis(analysisID) else { return }
        state.analysisReport = report
        if qwenChatPanel?.isVisible == true, state.qwenChatMode == .specialist {
            state.prepareQwenChat(with: activeFieldAgentContext(), mode: .specialist)
        }
        showPromptResults()

        state.currentStatus = .savingResults
        do {
            let json = try analysisJSONService.encode(report)
            state.analysisJSON = json
            state.analysisJSONFileURL = try analysisJSONService.save(json)
        } catch {
            guard isActiveAnalysis(analysisID) else { return }
            state.latestError = "The screen was analyzed, but its JSON report could not be saved. \(error.localizedDescription)"
            state.currentStatus = .complete
            finishAnalysis(analysisID)
            return
        }

        guard isActiveAnalysis(analysisID) else { return }
        state.currentStatus = .complete
        finishAnalysis(analysisID)
    }

    private func reportFromVision(
        _ result: QwenVisionPromptResult,
        document: OCRDocument,
        sourceContext: ScreenSourceContext,
        replacing baseReport: ScreenContextReport?
    ) -> ScreenContextReport {
        let reportWithoutPrompts: ScreenContextReport
        if let baseReport {
            // Qwen3-VL enriches only the prompts on this path. The deterministic
            // pipeline's `Other` classification remains the saved source of truth.
            reportWithoutPrompts = baseReport
        } else {
            let attempt = ClassificationAttempt(
                method: .qwenVision,
                category: result.category,
                subcategory: result.subcategory,
                confidence: 0.90,
                accepted: true,
                evidence: result.visibleEvidence,
                error: nil
            )
            let intent = IntentClassification(
                category: result.category,
                subcategory: result.subcategory,
                confidence: 0.90,
                method: .qwenVision,
                identifiedSubject: result.subject,
                evidence: result.visibleEvidence,
                attempts: [attempt],
                learnedSignals: [],
                memoryStorePath: nil
            )
            let cleanedSegments = document.lines.map { line in
                line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            reportWithoutPrompts = ScreenContextReport(
                schemaVersion: "5.2",
                generatedAt: Date(),
                sourceContext: sourceContext,
                intent: intent,
                importantText: [],
                entities: ExtractedEntities(
                    products: [],
                    topics: [result.subject],
                    places: [],
                    dates: [],
                    brandsAndSites: [],
                    prices: [],
                    sizes: []
                ),
                categories: [
                    ExtractedCategory(name: "Visual evidence", items: result.visibleEvidence)
                ],
                cleanedSegments: cleanedSegments,
                statistics: AnalysisStatistics(
                    ocrLineCount: document.lines.count,
                    cleanedSegmentCount: cleanedSegments.count,
                    importantTextCount: result.visibleEvidence.count,
                    discardedLineCount: 0
                ),
                promptGeneration: nil,
                temporalFreshness: nil
            )
        }

        let agentContext = fieldAgentContextService.context(
            for: reportWithoutPrompts,
            subject: result.subject
        )
        return reportWithoutPrompts.addingPromptGeneration(
            IntentPromptGeneration(
                model: result.model,
                prompts: result.prompts,
                error: nil,
                agentContext: agentContext,
                screenInsight: result.screenSummary
            )
        )
    }

    private func pngData(from image: NSImage) -> Data? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }
        return pngData(from: cgImage)
    }

    private func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func isActiveAnalysis(_ analysisID: UUID) -> Bool {
        activeAnalysisID == analysisID && !Task.isCancelled
    }

    private func resolveWebResearchMode(
        for report: ScreenContextReport
    ) -> WebResearchMode? {
        guard let requirement = intentPromptSuggestionService.webResearchRequirement(for: report) else {
            return .disabled
        }

        switch InternetAccessPolicy.current {
        case .automatic:
            return requirement.mode
        case .never:
            return .disabled
        case .ask:
            state.currentStatus = .awaitingInternetPermission
            switch requestWebSearchConsent(requirement) {
            case .allow:
                return requirement.mode
            case .offline:
                return .disabled
            case .cancel:
                return nil
            }
        }
    }

    private func requestWebSearchConsent(
        _ requirement: WebResearchRequirement,
        cancelButtonTitle: String = "Cancel Analysis"
    ) -> WebSearchConsentDecision {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = requirement.title
        alert.informativeText = requirement.message
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Continue Offline")
        alert.addButton(withTitle: cancelButtonTitle)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .allow
        case .alertSecondButtonReturn:
            return .offline
        default:
            return .cancel
        }
    }

    private func finishAnalysis(_ analysisID: UUID) {
        guard activeAnalysisID == analysisID else { return }
        activeAnalysisID = nil
        analysisTask = nil
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) else { return }
        showOnboarding()
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = makeMenuBarIcon()
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Theia"
            button.target = self
            button.action = #selector(toggleStatusPopover)
        }

        let rootView = MenuBarView()
            .environmentObject(self)
            .environmentObject(state)
        let hostingController = NSHostingController(rootView: rootView)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.appearance = AppearanceMode.current.nsAppearance

        statusItem = item
        statusPopover = popover
    }

    private func makeMenuBarIcon() -> NSImage {
        let image = NSImage(named: "TheiaLogo") ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        image.accessibilityDescription = "Theia"
        return image
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button,
              let popover = statusPopover
        else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func menuBarIconFrame() -> NSRect? {
        guard let button = statusItem?.button,
              let window = button.window
        else { return nil }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    private func showOnboarding() {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) else { return }
        hideManagedWindows(except: .onboarding)
        if onboardingWindow == nil {
            let rootView = OnboardingView { [weak self] in
                self?.completeOnboarding()
            }
                .environmentObject(self)
                .environmentObject(state)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Theia"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 520)
            configureWindowLevel(window)
            window.appearance = AppearanceMode.current.nsAppearance
            window.contentView = NSHostingView(rootView: rootView)
            restorePersistentFrame(for: window, name: WindowFrameName.onboarding)
            onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func showPromptResults() {
        guard state.analysisReport?.promptGeneration != nil else { return }
        hideManagedWindows(except: .promptResults)

        if promptResultsPanel == nil {
            let rootView = PromptResultsView()
                .environmentObject(state)
                .environmentObject(self)
            let panel = TheiaPromptPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
                styleMask: [.borderless, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 560, height: 520)
            configureWindowLevel(panel)
            panel.appearance = AppearanceMode.current.nsAppearance
            panel.contentView = NSHostingView(
                rootView: rootView.clipShape(RoundedRectangle(cornerRadius: 26))
            )
            panel.hasPersistentPlacement = restorePersistentFrame(
                for: panel,
                name: WindowFrameName.promptResults,
                centerIfMissing: false
            )
            promptResultsPanel = panel
        }

        let originFrame = pendingPromptOrigin
            ?? menuBarIconFrame()
            ?? menuBarFallbackOrigin(on: NSScreen.main)
        guard let panel = promptResultsPanel,
              let screen = screen(containing: originFrame) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        if panel.hasPersistentPlacement {
            pendingPromptOrigin = nil
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let visibleFrame = screen.visibleFrame
        let targetSize = NSSize(
            width: min(540, visibleFrame.width - 48),
            height: min(590, visibleFrame.height - 60)
        )
        let targetFrame = promptTargetFrame(
            size: targetSize,
            visibleFrame: visibleFrame,
            origin: originFrame
        )
        let animationOrigin = originFrame ?? menuBarFallbackOrigin(on: screen) ?? targetFrame

        activePromptOrigin = animationOrigin
        pendingPromptOrigin = nil
        panel.hasPersistentPlacement = true
        panel.setFrame(animationOrigin.insetBy(dx: -2, dy: -2), display: true)
        panel.alphaValue = 0.18
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.46
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    @discardableResult
    private func restorePersistentFrame(
        for window: NSWindow,
        name: String,
        centerIfMissing: Bool = true
    ) -> Bool {
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if !restored, centerIfMissing {
            window.center()
        }
        return restored
    }

    private func promptTargetFrame(
        size: NSSize,
        visibleFrame: NSRect,
        origin: NSRect?
    ) -> NSRect {
        guard let origin,
              origin.midY > visibleFrame.midY
        else {
            return NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.minY + 26,
                width: size.width,
                height: size.height
            )
        }

        let horizontalMargin: CGFloat = 12
        let proposedX = origin.midX - size.width / 2
        let x = min(
            max(proposedX, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - size.width - horizontalMargin
        )
        let y = max(
            visibleFrame.minY + 12,
            min(origin.minY - size.height - 10, visibleFrame.maxY - size.height - 12)
        )
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func screen(containing rect: NSRect?) -> NSScreen? {
        guard let rect else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private func menuBarFallbackOrigin(on screen: NSScreen?) -> NSRect? {
        guard let screen else { return nil }
        let frame = screen.frame
        return NSRect(
            x: frame.maxX - 72,
            y: frame.maxY - 26,
            width: 24,
            height: 24
        )
    }

    private func showAnalysisPanel() {
        hideManagedWindows(except: .analysis)
        if analysisPanel == nil {
            let rootView = AnalysisWindow()
                .environmentObject(state)
                .environmentObject(self)

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Theia Analysis"
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 560, height: 440)
            configureWindowLevel(panel)
            panel.appearance = AppearanceMode.current.nsAppearance
            panel.contentView = NSHostingView(rootView: rootView)
            restorePersistentFrame(for: panel, name: WindowFrameName.developer)
            analysisPanel = panel
        }

        analysisPanel?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var managedWindows: [NSWindow] {
        [
            analysisPanel,
            onboardingWindow,
            settingsWindow,
            promptResultsPanel,
            qwenChatPanel,
            chatHistoryPanel
        ].compactMap { $0 }
    }

    private var windowsStayOnTop: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: TheiaPreferenceKey.windowAlwaysOnTop) != nil else {
            return true
        }
        return defaults.bool(forKey: TheiaPreferenceKey.windowAlwaysOnTop)
    }

    private func configureWindowLevel(_ window: NSWindow) {
        let pinned = windowsStayOnTop
        window.level = pinned ? .floating : .normal
        if let panel = window as? NSPanel {
            panel.isFloatingPanel = pinned
        }
    }

    private func hideManagedWindows(except page: ManagedPage) {
        let pages: [(ManagedPage, NSWindow?)] = [
            (.analysis, analysisPanel),
            (.onboarding, onboardingWindow),
            (.settings, settingsWindow),
            (.promptResults, promptResultsPanel),
            (.qwenChat, qwenChatPanel),
            (.chatHistory, chatHistoryPanel)
        ]
        for (candidate, window) in pages where candidate != page {
            window?.orderOut(nil)
        }
    }

    private func activeFieldAgentContext() -> FieldAgentContext {
        let report = state.analysisReport ?? (try? analysisJSONService.loadLatest())?.report
        guard let report else { return fieldAgentContextService.generalContext() }
        if let savedContext = report.promptGeneration?.agentContext {
            return savedContext
        }
        let subject = intentPromptSuggestionService.primarySubject(in: report)
        return fieldAgentContextService.context(for: report, subject: subject)
    }
}

private final class TheiaPromptPanel: NSPanel {
    var hasPersistentPlacement = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
