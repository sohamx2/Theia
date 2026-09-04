import CoreGraphics
import SwiftUI

struct TheiaSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var state: AppState

    @AppStorage(TheiaPreferenceKey.experienceFocus) private var experienceFocus = "Everyday"
    @AppStorage(TheiaPreferenceKey.responseStyle) private var responseStyle = "Balanced"
    @AppStorage(TheiaPreferenceKey.qwenModel) private var qwenModel = "qwen3:4b"
    @AppStorage(TheiaPreferenceKey.qwenTextContextLength) private var qwenTextContextLength = QwenTextContextWindow.recommended.rawValue
    @AppStorage(TheiaPreferenceKey.qwenVisionContextLength) private var qwenVisionContextLength = QwenVisionContextWindow.recommended.rawValue
    @AppStorage(TheiaPreferenceKey.ollamaBaseURL) private var ollamaBaseURL = "http://127.0.0.1:11434"
    @AppStorage(TheiaPreferenceKey.internetAccessPolicy) private var internetAccessPolicyValue = InternetAccessPolicy.ask.rawValue
    @AppStorage(TheiaPreferenceKey.searchEngine) private var searchEngineValue = SearchEngine.google.rawValue
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue
    @AppStorage(TheiaPreferenceKey.developerUIEnabled) private var developerUIEnabled = false
    @AppStorage(TheiaPreferenceKey.windowAlwaysOnTop) private var windowAlwaysOnTop = true
    @AppStorage(TheiaPreferenceKey.subpromptsPerMainPrompt) private var subpromptsPerMainPrompt = VisibleSubpromptLimit.defaultValue

    @State private var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @State private var isShowingPromptTemplates = false

    private let controlWidth: CGFloat = 330
    private let ink = TheiaTheme.ink

    var body: some View {
        Group {
            if isShowingPromptTemplates {
                PromptTemplateSettingsView {
                    isShowingPromptTemplates = false
                }
            } else {
                settingsHome
            }
        }
    }

    private var settingsHome: some View {
        ZStack {
            TheiaTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    experienceSection
                    appearanceSection
                    siriSection
                    promptTemplatesSection
                    localAISection
                    permissionsSection
                    developerSection
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 30)
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .foregroundStyle(ink)
        .tint(TheiaTheme.action)
        .preferredColorScheme(selectedAppearanceMode.colorScheme)
        .onAppear {
            hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
            migrateInternetAccessPolicyIfNeeded()
            if !VisibleSubpromptLimit.allowedRange.contains(subpromptsPerMainPrompt) {
                subpromptsPerMainPrompt = VisibleSubpromptLimit.defaultValue
            }
        }
        .onChange(of: appearanceModeValue) { value in
            coordinator.applyAppearancePreference(AppearanceMode(rawValue: value) ?? .system)
        }
        .onChange(of: qwenModel) { coordinator.applyLocalModelPreference($0) }
        .onChange(of: developerUIEnabled) { coordinator.applyDeveloperUIPreference($0) }
        .onChange(of: windowAlwaysOnTop) { coordinator.applyWindowAlwaysOnTopPreference($0) }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            Text(TheiaRelease.displayName)
                .font(.caption.weight(.semibold))
        }
        .frame(minHeight: 42)
    }

    private var experienceSection: some View {
        settingsSection(title: "EXPERIENCE") {
            settingRow(title: "Focus") {
                Picker("Focus", selection: $experienceFocus) {
                    Text("Everyday").tag("Everyday")
                    Text("Work").tag("Work")
                    Text("Learning").tag("Learning")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Suggestion style") {
                Picker("Style", selection: $responseStyle) {
                    Text("Concise").tag("Concise")
                    Text("Balanced").tag("Balanced")
                    Text("Exploratory").tag("Exploratory")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var appearanceSection: some View {
        settingsSection(title: "WINDOW") {
            settingRow(title: "Color mode") {
                Picker("Appearance", selection: $appearanceModeValue) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Keep Theia on top") {
                Toggle("Keep Theia on top", isOn: $windowAlwaysOnTop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var siriSection: some View {
        settingsSection(title: "SIRI") {
            settingRow(title: "Siri") {
                alignedButton("Open Siri Settings", action: coordinator.openSiriSettings)
            }
            settingRow(title: "Shortcuts") {
                alignedButton("Open Shortcuts", action: coordinator.openShortcutsApp)
            }
        }
    }

    private var promptTemplatesSection: some View {
        settingsSection(title: "PROMPT GENERATION") {
            settingRow(title: "Paths per prompt") {
                Picker("Paths per prompt", selection: $subpromptsPerMainPrompt) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                    Text("Three").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Prompt templates") {
                alignedButton("Change Templates") {
                    isShowingPromptTemplates = true
                }
            }
        }
    }

    private var localAISection: some View {
        settingsSection(title: "LOCAL AI") {
            settingRow(title: "Model") {
                Picker("Model", selection: $qwenModel) {
                    ForEach(LocalAIModelTier.allCases, id: \.rawValue) { tier in
                        Text(tier.title).tag(tier.modelName)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Qwen text context") {
                Picker("Qwen text context", selection: $qwenTextContextLength) {
                    ForEach(QwenTextContextWindow.allCases, id: \.rawValue) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Qwen3-VL context") {
                Picker("Qwen3-VL context", selection: $qwenVisionContextLength) {
                    ForEach(QwenVisionContextWindow.allCases, id: \.rawValue) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Internet access") {
                Picker("Internet access", selection: $internetAccessPolicyValue) {
                    ForEach(InternetAccessPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Search engine") {
                Picker("Search engine", selection: $searchEngineValue) {
                    ForEach(SearchEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            settingRow(title: "Ollama address") {
                TextField("Ollama address", text: $ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            settingRow(title: "Theia") {
                alignedButton("Restart Theia", action: coordinator.restartInstalledApp)
            }

            if let pending = state.pendingLocalModelName {
                settingRow(title: "Model status") {
                    Text("Preparing \(LocalAIModelTier.tier(for: pending).modelDisplayName)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = state.localModelSwitchError {
                settingRow(title: "Model status") {
                    Text(error)
                        .foregroundStyle(TheiaTheme.danger)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var permissionsSection: some View {
        settingsSection(title: "PERMISSIONS") {
            settingRow(title: "Screen Recording") {
                Text(hasScreenRecordingPermission ? "Allowed" : "Not allowed")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            settingRow(title: "Screen Recording settings") {
                alignedButton("Open System Settings", action: coordinator.openScreenRecordingSettings)
            }
            settingRow(title: "Permission status") {
                alignedButton("Refresh") {
                    hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
                }
            }
        }
    }

    private var developerSection: some View {
        settingsSection(title: "DEVELOPER") {
            settingRow(title: "Developer UI") {
                Toggle("Developer UI", isOn: $developerUIEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if developerUIEnabled {
                settingRow(title: "Developer tools") {
                    alignedButton("Open Developer UI", action: coordinator.showDeveloperUI)
                }
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .tracking(1.1)
            content()
        }
        .padding(18)
        .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(TheiaTheme.border))
    }

    private func settingRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .frame(width: controlWidth, height: 32, alignment: .leading)
        }
    }

    private func alignedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 32)
    }

    private var selectedAppearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeValue) ?? .system
    }

    private func migrateInternetAccessPolicyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: TheiaPreferenceKey.internetAccessPolicy) == nil else {
            return
        }
        if defaults.object(forKey: TheiaPreferenceKey.webResearchEnabled) != nil {
            let legacyValue = defaults.string(forKey: TheiaPreferenceKey.webResearchEnabled) ?? "true"
            let disabledValues: Set<String> = ["0", "false", "no", "off"]
            internetAccessPolicyValue = disabledValues.contains(legacyValue.lowercased())
                ? InternetAccessPolicy.never.rawValue
                : InternetAccessPolicy.ask.rawValue
        }
    }
}
