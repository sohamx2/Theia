import SwiftUI

struct PromptResultsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var coordinator: AppCoordinator
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue
    @AppStorage(TheiaPreferenceKey.windowAlwaysOnTop) private var windowAlwaysOnTop = true
    @AppStorage(TheiaPreferenceKey.subpromptsPerMainPrompt) private var subpromptLimit = VisibleSubpromptLimit.defaultValue

    private let ink = TheiaTheme.ink
    private let mutedInk = TheiaTheme.mutedInk
    private let card = TheiaTheme.surfaceStrong
    private let cyan = TheiaTheme.action

    var body: some View {
        ZStack {
            TheiaTheme.background
            .ignoresSafeArea()

            Circle()
                .fill(cyan.opacity(0.07))
                .frame(width: 360, height: 360)
                .blur(radius: 85)
                .offset(x: 245, y: -270)

            VStack(spacing: 0) {
                header

                if let prompts = state.analysisReport?.promptGeneration?.prompts,
                   !prompts.isEmpty {
                    promptList(prompts)
                } else {
                    emptyState
                }

                footer
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 690)
        .foregroundStyle(TheiaTheme.ink)
        .tint(TheiaTheme.action)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            TheiaMark(size: 46)
                .background(TheiaTheme.surfaceStrong, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("A few paths forward")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text(headerSubtitle)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(mutedInk)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                windowAlwaysOnTop.toggle()
                coordinator.applyWindowAlwaysOnTopPreference(windowAlwaysOnTop)
            } label: {
                Label(windowAlwaysOnTop ? "Unpin" : "Pin", systemImage: windowAlwaysOnTop ? "pin.slash" : "pin")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(TheiaTheme.surfaceStrong, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink.opacity(0.78))
            .help(windowAlwaysOnTop ? "Let other windows appear above Theia" : "Keep Theia above other windows")

            Button(action: coordinator.closePromptResults) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(TheiaTheme.surfaceStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink.opacity(0.62))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    private var headerSubtitle: String {
        "Expand a path, or ask Siri to show it by number, letter, or name."
    }

    private func promptList(_ prompts: [IntentPromptSuggestion]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let insight = state.analysisReport?.promptGeneration?.screenInsight,
                   !insight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("WHAT QWEN SEES", systemImage: "sparkles")
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(cyan)
                        Text(QwenVisibleOutputSanitizer.sanitize(insight))
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(ink.opacity(0.86))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(cyan.opacity(0.22), lineWidth: 1)
                    )
                }

                if let warning = state.analysisReport?.promptGeneration?.error {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }

                ForEach(Array(prompts.enumerated()), id: \.element.id) { promptIndex, prompt in
                    let precedingCount = prompts.prefix(promptIndex).reduce(0) {
                        $0 + min(visibleSubpromptLimit, $1.searchOptions.count)
                    }
                    promptCard(prompt, precedingOptionCount: precedingCount)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private func promptCard(
        _ prompt: IntentPromptSuggestion,
        precedingOptionCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Text(QwenVisibleOutputSanitizer.sanitize(prompt.text))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)
            }

            if prompt.searchOptions.isEmpty {
                Button("Search this prompt") {
                    coordinator.openSearchInSafari(prompt.text)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(prompt.searchOptions.prefix(visibleSubpromptLimit).enumerated()), id: \.element.id) { optionIndex, option in
                        promptChoice(
                            option,
                            voiceIndex: precedingOptionCount + optionIndex,
                            prompt: prompt
                        )
                    }
                }
            }
        }
        .padding(15)
        .background(card.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(TheiaTheme.border, lineWidth: 1)
        )
    }

    private var visibleSubpromptLimit: Int {
        max(1, min(subpromptLimit, 3))
    }

    private func promptChoice(
        _ option: SuggestedSearchOption,
        voiceIndex: Int,
        prompt: IntentPromptSuggestion
    ) -> some View {
        let selection = PromptSummarySelection(prompt: prompt, option: option)
        let expansion = state.promptSummaryExpansion(for: selection)
        let isExpanded = expansion != nil
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(SiriCommandInterpreter.pathIdentifier(for: voiceIndex))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ink)
                    .frame(width: 40, height: 23)
                    .background(cyan.opacity(0.11), in: Capsule())
                    .help("Siri command: Ask Theia to show \(voiceIndex + 1)")

                Text(QwenVisibleOutputSanitizer.sanitize(option.title))
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.88))
                    .lineLimit(2)

                Spacer(minLength: 6)

                Button {
                    if isExpanded {
                        coordinator.dismissPromptSummary(selection)
                    } else {
                        coordinator.summarizePrompt(option, for: prompt)
                    }
                } label: {
                    Label(isExpanded ? "Hide" : "Expand", systemImage: isExpanded ? "chevron.up" : "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(cyan)

                Button {
                    coordinator.openSearchInSafari(option.query)
                } label: {
                    Image(systemName: "safari")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Search in Safari: \(option.query)")
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 43)

            if isExpanded {
                Divider().opacity(0.55)
                summaryContent(selection: selection, expansion: expansion)
                    .padding(13)
            }
        }
        .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private func summaryContent(
        selection: PromptSummarySelection,
        expansion: PromptSummaryExpansionState?
    ) -> some View {
        if expansion?.isGenerating == true {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(cyan)
                Text("Qwen is preparing the answer and checking available sources…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let summary = expansion?.summary {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(QwenVisibleOutputSanitizer.sanitize(summary.title))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Spacer()
                    Text(summary.isLiveWebGrounded ? "LIVE-GROUNDED" : "LOCAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(summary.isLiveWebGrounded ? Color.green : mutedInk)
                }

                Button("Continue in Qwen") {
                    coordinator.continuePromptInQwen(selection, summary: summary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !summary.summary.isEmpty {
                    Text(QwenVisibleOutputSanitizer.sanitize(summary.summary))
                        .font(.system(size: 13.5, design: .rounded))
                        .foregroundStyle(ink.opacity(0.84))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }

                if !summary.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { index, point in
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.orange)
                                    .frame(width: 19, height: 19)
                                    .background(Color.orange.opacity(0.11), in: Circle())
                                Text(QwenVisibleOutputSanitizer.sanitize(point))
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(ink.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !summary.query.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(mutedInk)
                        Text(QwenVisibleOutputSanitizer.sanitize(summary.query))
                            .font(.caption.monospaced())
                            .foregroundStyle(mutedInk)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Search") {
                            coordinator.openSearchInSafari(summary.query)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                    }
                    .padding(10)
                    .background(card.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                }

                if !summary.webResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.answerShape == .namedList
                            ? "NAMED RESULTS"
                            : "TOP SOURCES")
                            .font(.caption2.weight(.bold))
                            .tracking(1.0)
                            .foregroundStyle(ink)
                        ForEach(summary.webResults.prefix(10)) { result in
                            webResultRow(result)
                        }
                    }
                } else {
                    Label("No live sources were used. Open the query in Safari to verify current details.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(mutedInk)
                }
            }
        } else {
            summaryErrorState(selection: selection, error: expansion?.error)
        }
    }

    private func summaryErrorState(
        selection: PromptSummarySelection,
        error: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.orange)
            Text(error ?? "The summary could not be generated.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again") {
                coordinator.summarizePrompt(selection.option, for: selection.prompt)
            }
            .buttonStyle(.borderedProminent)
            .tint(cyan)
            .foregroundStyle(TheiaTheme.actionText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func webResultRow(_ result: WebSearchResult) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(result.rank)")
                .font(.caption2.weight(.bold))
                .frame(width: 19, height: 19)
                .background(cyan.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(QwenVisibleOutputSanitizer.sanitize(result.title))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                Text(result.sourceHost)
                    .font(.caption2)
                    .foregroundStyle(cyan)
                if !result.snippet.isEmpty {
                    Text(QwenVisibleOutputSanitizer.sanitize(result.snippet))
                        .font(.caption)
                        .foregroundStyle(mutedInk)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 5)
            Button {
                coordinator.openURLInSafari(result.url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Open \(result.title) in Safari")
        }
        .padding(9)
        .background(card.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(cyan)
            Text("No prompts were generated")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            if let error = state.analysisReport?.promptGeneration?.error ?? state.latestError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(mutedInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Spacer()
        }
        .padding(30)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(TheiaRelease.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(mutedInk)

            if !state.promptSummaryExpansions.isEmpty {
                Text("\(state.promptSummaryExpansions.count) expanded answer\(state.promptSummaryExpansions.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(mutedInk.opacity(0.78))
            } else {
                Text(promptGenerationSourceLabel)
                    .font(.caption2)
                    .foregroundStyle(mutedInk.opacity(0.78))
            }

            Spacer()

            Button {
                coordinator.showSpecializedQwenChat()
            } label: {
                Label("New Specialist Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Analyze Again", action: coordinator.analyzeScreen)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(TheiaTheme.surface.opacity(0.75))
    }

    private var promptGenerationSourceLabel: String {
        if state.analysisReport?.promptGeneration?.model == "Theia Templates" {
            return "Instant template · expand any path for Qwen"
        }
        let usedWebResearch = state.analysisReport?.promptGeneration?.diagnostics?.contains {
            $0.stage == .webResearch && $0.succeeded
        } == true
        return usedWebResearch ? "Qwen grounded with live search" : "Generated locally with Qwen"
    }

}
