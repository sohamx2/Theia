import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var state: AppState
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue
    @AppStorage(TheiaPreferenceKey.developerUIEnabled) private var developerUIEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Theia")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(state.currentStatus.message)
                        .font(.caption)
                        .foregroundStyle(TheiaTheme.mutedInk)
                        .lineLimit(2)
                }

                Spacer()

                if state.currentStatus.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                if state.currentStatus.isWorking {
                    coordinator.cancelAnalysis()
                } else {
                    coordinator.analyzeScreen()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: state.currentStatus.isWorking ? "xmark.circle.fill" : "viewfinder")
                    Text(state.currentStatus.isWorking ? "Cancel Analysis" : "Analyze Screen")
                    Spacer()
                    Text("⌘⇧A")
                        .font(.caption2)
                        .foregroundStyle(TheiaTheme.actionText.opacity(0.62))
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(TheiaTheme.actionText)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(
                    LinearGradient(
                        colors: state.currentStatus.isWorking
                            ? [TheiaTheme.cancel, TheiaTheme.cancelPressed]
                            : [TheiaTheme.action, TheiaTheme.actionPressed],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button(action: coordinator.showLastAnalysis) {
                Label("Show Last Prompts", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("l")
            .disabled(state.currentStatus.isWorking)

            Button(action: coordinator.showGeneralQwenChat) {
                Label("New Chat with Qwen", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("c")

            HStack(spacing: 5) {
                Button(action: coordinator.showChatHistory) {
                    Label("Chat History", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    if state.qwenChatConversations.isEmpty {
                        Text("No saved conversations")
                    } else {
                        ForEach(state.qwenChatConversations.prefix(20)) { conversation in
                            Button {
                                coordinator.selectQwenChatConversation(conversation.id)
                            } label: {
                                Text("\(conversation.title) · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .frame(width: 24, height: 24)
                        .background(TheiaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent chats")
            }

            Divider()

            if developerUIEnabled {
                Button(action: coordinator.showDeveloperUI) {
                    Label("Developer UI", systemImage: "hammer")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Button(action: coordinator.showSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()

            Button(action: coordinator.quit) {
                Label("Quit Theia", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")

            Text(TheiaRelease.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(TheiaTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(15)
        .frame(width: 300)
        .background(TheiaTheme.background)
        .foregroundStyle(TheiaTheme.ink)
        .tint(TheiaTheme.action)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
    }
}
