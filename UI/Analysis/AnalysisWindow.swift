import SwiftUI

struct AnalysisWindow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSection

                if state.currentStatus == .permissionRequired {
                    PermissionView(
                        openSettings: coordinator.openScreenRecordingSettings,
                        restartInstalledApp: coordinator.restartInstalledApp,
                        revealInstalledApp: coordinator.revealInstalledApp
                    )
                }

                if let error = state.latestError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let image = state.lastImage {
                    screenshotSection(image)
                }

                if state.currentStatus == .complete || !state.ocrOutput.isEmpty {
                    OCRPreviewView(text: state.ocrOutput)
                }

                if !state.classificationProgress.isEmpty && state.analysisReport == nil {
                    Divider()
                    liveClassificationSection
                }

                if let report = state.analysisReport, !state.analysisJSON.isEmpty {
                    Divider()

                    ContextAnalysisView(
                        report: report,
                        json: state.analysisJSON,
                        fileURL: state.analysisJSONFileURL,
                        copyJSON: coordinator.copyAnalysisJSON,
                        revealJSON: coordinator.revealAnalysisJSON,
                        openSearch: coordinator.openSearchInSafari,
                        summarize: { option, prompt in
                            coordinator.summarizePrompt(option, for: prompt)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var liveClassificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Classification Pipeline")
                .font(.headline)

            ForEach(state.classificationProgress) { stage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: stageSymbol(stage))
                            .foregroundStyle(stageColor(stage))

                        Text(stage.method.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)

                        Text(stageLabel(stage))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let attempt = stage.attempt,
                           let category = attempt.category,
                           let confidence = attempt.confidence {
                            let subcategory = attempt.subcategory.map {
                                " · \($0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)"
                            } ?? ""
                            Text("\(category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)\(subcategory) · \(confidence.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.callout.weight(.medium))
                        }
                    }

                    if let attempt = stage.attempt, !attempt.evidence.isEmpty {
                        Text("Evidence: \(attempt.evidence.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let error = stage.attempt?.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func stageLabel(_ stage: ClassificationStageProgress) -> String {
        switch stage.state {
        case .pending: return "Pending"
        case .running: return "Running…"
        case .completed:
            return stage.attempt?.accepted == true ? "Accepted" : "Completed; below threshold"
        case .failed: return "Failed; continuing"
        case .skipped: return "Not needed"
        }
    }

    private func stageSymbol(_ stage: ClassificationStageProgress) -> String {
        switch stage.state {
        case .pending: return "clock"
        case .running: return "ellipsis.circle"
        case .completed:
            return stage.attempt?.accepted == true ? "checkmark.circle.fill" : "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func stageColor(_ stage: ClassificationStageProgress) -> Color {
        switch stage.state {
        case .running: return .blue
        case .completed:
            return stage.attempt?.accepted == true ? .green : .orange
        case .failed: return .orange
        case .pending, .skipped: return .secondary
        }
    }

    private var statusSection: some View {
        HStack(spacing: 10) {
            if state.currentStatus.isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
            }

            Text(state.currentStatus.message)
                .font(.title3.weight(.semibold))
        }
    }

    private func screenshotSection(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frontmost Window")
                .font(.headline)

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 320)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusSymbol: String {
        switch state.currentStatus {
        case .complete:
            return "checkmark.circle.fill"
        case .permissionRequired:
            return "lock.trianglebadge.exclamationmark"
        case .failed:
            return "xmark.octagon.fill"
        default:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch state.currentStatus {
        case .complete:
            return .green
        case .permissionRequired:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}
