import SwiftUI

struct ContextAnalysisView: View {
    let report: ScreenContextReport
    let json: String
    let fileURL: URL?
    let copyJSON: () -> Void
    let revealJSON: () -> Void
    let openSearch: (String) -> Void
    let summarize: (SuggestedSearchOption, IntentPromptSuggestion) -> Void

    @State private var isJSONExpanded = true
    @State private var isPromptDiagnosticsExpanded = false
    @State private var expandedPromptIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if report.sourceContext != .empty {
                sourceContextSection
            }

            intentSection

            if report.temporalFreshness != nil {
                temporalFreshnessSection
            }

            if report.promptGeneration != nil {
                promptSuggestionsSection
            }

            classificationPipelineSection
            importantTextSection

            if !report.categories.isEmpty {
                categoriesSection
            }

            jsonSection
        }
    }

    private var promptSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested Next Steps")
                .font(.headline)

            if let generation = report.promptGeneration {
                ForEach(generation.prompts) { suggestion in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: suggestion.id)
                    ) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(suggestion.rationale)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            ForEach(Array(suggestion.searchOptions.enumerated()), id: \.element.id) { index, option in
                                HStack(alignment: .center, spacing: 9) {
                                    Text("\(index + 1)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.cyan)
                                        .frame(width: 22, height: 22)
                                        .background(Color.cyan.opacity(0.12), in: Circle())

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.primary)

                                        Text(option.query)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    Button {
                                        summarize(option, suggestion)
                                    } label: {
                                        Text("AI Summary")
                                    }
                                    .controlSize(.small)

                                    Button {
                                        openSearch(option.query)
                                    } label: {
                                        Label("Safari", systemImage: "safari")
                                    }
                                    .controlSize(.small)
                                    .help("Search in a new Safari tab")
                                }
                                .padding(.vertical, 3)
                            }

                            if !suggestion.evidence.isEmpty {
                                Text("Based on: \(suggestion.evidence.joined(separator: " • "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 9)
                    } label: {
                        Text(suggestion.text)
                            .font(.body.weight(.medium))
                    }
                    .padding(12)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }

                if let error = generation.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if let diagnostics = generation.diagnostics, !diagnostics.isEmpty {
                    promptDiagnosticsSection(diagnostics)
                }

                let usedWebResearch = generation.diagnostics?.contains(where: {
                    $0.stage == .webResearch && $0.succeeded
                }) == true
                Text(usedWebResearch
                    ? "Generated locally with \(generation.model), grounded by bounded web research"
                    : "Generated locally with \(generation.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func promptDiagnosticsSection(
        _ diagnostics: [PromptStageDiagnostic]
    ) -> some View {
        DisclosureGroup(
            "Prompt Generation Diagnostics",
            isExpanded: $isPromptDiagnosticsExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: diagnostic.succeeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.succeeded ? .green : .orange)

                            Text(diagnostic.stage.rawValue.replacingOccurrences(of: "_", with: " "))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)

                            Spacer()

                            Text("\(diagnostic.durationMilliseconds) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text("Requested: \(diagnostic.requestedActions.map(\.rawValue).joined(separator: ", "))")
                            .font(.caption)
                            .textSelection(.enabled)

                        Text("Timeout: \(diagnostic.timeoutSeconds)s · Timed out: \(diagnostic.timedOut ? "yes" : "no")")
                            .font(.caption)
                            .foregroundStyle(diagnostic.timedOut ? .orange : .secondary)

                        if diagnostic.modelLoadMilliseconds != nil ||
                            diagnostic.promptEvaluationMilliseconds != nil ||
                            diagnostic.generationMilliseconds != nil {
                            let load = diagnostic.modelLoadMilliseconds.map { "\($0) ms" } ?? "n/a"
                            let prompt = diagnostic.promptEvaluationMilliseconds.map { "\($0) ms" } ?? "n/a"
                            let generation = diagnostic.generationMilliseconds.map { "\($0) ms" } ?? "n/a"
                            Text("Ollama: load \(load) · prompt \(prompt) · generation \(generation)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if diagnostic.inputTokenCount != nil || diagnostic.outputTokenCount != nil {
                            Text("Tokens: input \(diagnostic.inputTokenCount.map { String($0) } ?? "n/a") · output \(diagnostic.outputTokenCount.map { String($0) } ?? "n/a")")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if let errorType = diagnostic.errorType,
                           let errorMessage = diagnostic.errorMessage {
                            Text("Error: \(errorType) — \(errorMessage)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }

                        if !diagnostic.rejections.isEmpty {
                            DisclosureGroup("Validation Rejections (\(diagnostic.rejections.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(
                                        Array(diagnostic.rejections.enumerated()),
                                        id: \.offset
                                    ) { _, rejection in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(rejection.action ?? "unknown") · \(rejection.field)")
                                                .font(.caption.weight(.semibold))
                                            if let value = rejection.value {
                                                Text("Value: \(value)")
                                                    .font(.caption.monospaced())
                                                    .textSelection(.enabled)
                                            }
                                            Text(rejection.reason)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        .padding(7)
                                        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .padding(.top, 5)
                            }
                        }

                        if !diagnostic.decodedItems.isEmpty {
                            DisclosureGroup("Raw Drafts (\(diagnostic.decodedItems.count))") {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(diagnostic.decodedItems) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("#\(item.index + 1) · \(item.action ?? "unknown action")")
                                                .font(.caption.weight(.semibold))
                                            Text(item.rawJSON)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                        }
                                        .padding(7)
                                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .padding(.top, 5)
                            }
                        }

                        if let rawResponse = diagnostic.rawResponse {
                            diagnosticTextDisclosure("Raw Qwen Response", text: rawResponse)
                        }
                        diagnosticTextDisclosure("Exact Request Prompt", text: diagnostic.requestPrompt)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 8)
        }
    }

    private func diagnosticTextDisclosure(_ title: String, text: String) -> some View {
        DisclosureGroup(title) {
            ScrollView(.horizontal) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 5)
            }
            .frame(maxHeight: 220)
        }
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedPromptIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedPromptIDs.insert(id)
                } else {
                    expandedPromptIDs.remove(id)
                }
            }
        )
    }

    private var intentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task Understanding")
                .font(.headline)

            HStack(spacing: 10) {
                Text(intentLabel(report.intent))
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.12), in: Capsule())

                Text(report.intent.confidence, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)

                Text(report.intent.method.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }

            if let subject = report.intent.identifiedSubject, !subject.isEmpty {
                Text("Subject: \(subject)")
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }

            if !report.intent.evidence.isEmpty {
                Text("Evidence: \(report.intent.evidence.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func intentLabel(_ intent: IntentClassification) -> String {
        if let customCategoryName = intent.customCategoryName {
            return "\(customCategoryName) · Custom"
        }
        let category = intent.category.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        guard let subcategory = intent.subcategory else { return category }
        let detail = subcategory.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return "\(category) · \(detail)"
    }

    private var temporalFreshnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Knowledge Freshness")
                .font(.headline)

            if let freshness = report.temporalFreshness {
                HStack(spacing: 9) {
                    Label(
                        freshness.requiresLiveWebSearch ? "Live evidence needed" : "Within local knowledge window",
                        systemImage: freshness.requiresLiveWebSearch
                            ? "network.badge.shield.half.filled"
                            : "checkmark.shield.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(freshness.requiresLiveWebSearch ? .orange : .green)

                    Text(freshness.status.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }

                Text(freshness.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let trigger = freshness.trigger {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rule: \(trigger.rule)")
                        Text("Signal: \(trigger.signal)")
                        Text("Matching line: \(trigger.matchingLine)")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                HStack(spacing: 14) {
                    Text("Cutoff: \(freshness.knowledgeCutoff.formatted(date: .long, time: .omitted))")
                    if !freshness.detectedYears.isEmpty {
                        Text("Detected: \(freshness.detectedYears.map(String.init).joined(separator: ", "))")
                    }
                    Text(freshness.confidence, format: .percent.precision(.fractionLength(0)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceContextSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Captured Context")
                .font(.headline)

            if let applicationName = report.sourceContext.applicationName {
                Text("Application: \(applicationName)")
            }
            if let windowTitle = report.sourceContext.windowTitle {
                Text("Window: \(windowTitle)")
                    .textSelection(.enabled)
            }
            if !report.sourceContext.websites.isEmpty {
                Text("Website: \(report.sourceContext.websites.joined(separator: ", "))")
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private var classificationPipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Classification Pipeline")
                .font(.headline)

            ForEach(report.intent.attempts) { attempt in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(attempt.method.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)

                        if let category = attempt.category {
                            Text(category.rawValue.capitalized)
                        }

                        if let confidence = attempt.confidence {
                            Text(confidence, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                        }

                        Image(systemName: attempt.accepted ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(attempt.accepted ? .green : .secondary)
                    }

                    if let error = attempt.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }

            if !report.intent.learnedSignals.isEmpty {
                Text("Saved to local memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(report.intent.learnedSignals.map {
                    "\($0.kind.rawValue): \($0.value)"
                }.joined(separator: " • "))
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if let memoryStorePath = report.intent.memoryStorePath {
                Text("Persistent memory: \(memoryStorePath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var importantTextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Important Text")
                .font(.headline)

            ForEach(report.importantText.prefix(12)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.category.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.blue)
                        .frame(width: 88, alignment: .leading)

                    Text(item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Text(item.salienceScore, format: .number.precision(.fractionLength(2)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extracted Categories")
                .font(.headline)

            ForEach(report.categories) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(category.items.joined(separator: " • "))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var jsonSection: some View {
        DisclosureGroup("Analysis JSON", isExpanded: $isJSONExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let fileURL {
                    Text(fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Copy JSON", action: copyJSON)
                    Button("Reveal JSON File", action: revealJSON)
                        .disabled(fileURL == nil)
                }

                ScrollView([.horizontal, .vertical]) {
                    Text(json)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }
}
