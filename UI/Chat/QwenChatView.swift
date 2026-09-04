import AppKit
import SwiftUI

struct QwenChatView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var state: AppState
    @State private var draft = ""
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue
    @AppStorage(TheiaPreferenceKey.windowAlwaysOnTop) private var windowAlwaysOnTop = true

    private let cyan = TheiaTheme.action
    private let amber = TheiaTheme.gold
    private let ink = TheiaTheme.ink
    private let mutedInk = TheiaTheme.mutedInk

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(TheiaTheme.border)
            conversation
            composer
        }
        .frame(minWidth: 500, minHeight: 600)
        .background(
            TheiaTheme.background
        )
        .foregroundStyle(TheiaTheme.ink)
        .tint(TheiaTheme.action)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
    }

    private var header: some View {
        HStack(spacing: 13) {
            TheiaMark(size: 40)
                .background(TheiaTheme.surfaceStrong, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Chat with Qwen")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text(state.qwenChatMode == .general
                    ? "general local assistant"
                    : state.qwenChatAgentContext?.specialistRole ?? "specialist local assistant")
                    .font(.caption)
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
            .foregroundStyle(mutedInk)
            .help(windowAlwaysOnTop ? "Let other windows appear above Theia" : "Keep Theia above other windows")

            Button(action: coordinator.showChatHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(TheiaTheme.surfaceStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Local chat history")

            if let context = state.qwenChatAgentContext {
                Text(state.qwenChatMode == .general ? "GENERAL" : context.field.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(cyan.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(cyan.opacity(0.22), lineWidth: 1))
            }

            Button(action: coordinator.closeQwenChat) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(TheiaTheme.surfaceStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(mutedInk)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 13) {
                    if state.qwenChatMode == .specialist,
                       let context = state.qwenChatAgentContext {
                        contextCard(context)
                    }

                    ForEach(state.qwenChatMessages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if state.isQwenChatResponding {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text(state.qwenChatMode == .general
                                ? "Qwen is thinking…"
                                : "Qwen is thinking in \(state.qwenChatAgentContext?.field ?? "context")…")
                                .font(.caption)
                                .foregroundStyle(mutedInk)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("qwen-loading")
                    }

                    if let error = state.qwenChatError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(18)
            }
            .onChange(of: state.qwenChatMessages.count) { _ in
                if let lastID = state.qwenChatMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.qwenChatMessages.last?.text.count ?? 0) { _ in
                if let lastID = state.qwenChatMessages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: state.isQwenChatResponding) { responding in
                guard responding else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("qwen-loading", anchor: .bottom)
                }
            }
        }
    }

    private func contextCard(_ context: FieldAgentContext) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("ACTIVE CONTEXT", systemImage: "scope")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Spacer()
                Text(context.sourceKind)
                    .font(.caption2)
                    .foregroundStyle(mutedInk)
            }
            Text(QwenVisibleOutputSanitizer.sanitize(context.activeSubject))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
            Text(context.userStage)
                .font(.caption)
                .foregroundStyle(mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            if let continuation = context.continuationContext {
                Text(QwenVisibleOutputSanitizer.sanitize(continuation.selectedPath))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.9))
                Text(QwenVisibleOutputSanitizer.sanitize(continuation.existingAnswer))
                    .font(.caption)
                    .foregroundStyle(mutedInk)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(TheiaTheme.border, lineWidth: 1)
        )
    }

    private func messageBubble(_ message: QwenChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                Text(message.role == .assistant
                    ? QwenVisibleOutputSanitizer.sanitize(message.text)
                    : message.text)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(mutedInk.opacity(0.72))
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    message.role == .user ? cyan.opacity(0.16) : TheiaTheme.surfaceStrong,
                    in: RoundedRectangle(cornerRadius: 15)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(
                            message.role == .user ? cyan.opacity(0.28) : TheiaTheme.border,
                            lineWidth: 1
                        )
                )
            if message.role == .assistant { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let assumptions = state.qwenChatAgentContext?.assumptions,
               let first = assumptions.first {
                Text(first)
                    .font(.caption2)
                    .foregroundStyle(mutedInk.opacity(0.82))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let attachment = state.qwenChatImageAttachment {
                HStack(spacing: 10) {
                    Image(nsImage: attachment.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("Qwen3-VL will load automatically")
                            .font(.caption2)
                            .foregroundStyle(mutedInk)
                    }
                    Spacer()
                    Button(action: coordinator.removeQwenChatScreenshot) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(mutedInk)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isQwenChatResponding)
                }
                .padding(9)
                .background(TheiaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(TheiaTheme.border))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: coordinator.chooseQwenChatScreenshot) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(TheiaTheme.surfaceStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mutedInk)
                .disabled(state.isQwenChatResponding)
                .help("Attach a screenshot (uses Qwen3-VL)")

                ChatComposerTextView(text: $draft, onSubmit: send)
                    .frame(minHeight: 42, maxHeight: 92)
                    .background(TheiaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(TheiaTheme.border, lineWidth: 1)
                    )

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TheiaTheme.actionText)
                        .frame(width: 38, height: 38)
                        .background(cyan, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend || state.isQwenChatResponding)
                .opacity(!canSend || state.isQwenChatResponding ? 0.42 : 1)
            }

            HStack {
                Text("↩ Send · ⇧↩ New line")
                    .font(.caption2)
                    .foregroundStyle(mutedInk.opacity(0.7))
                Spacer()
                Button("New Chat", action: coordinator.clearQwenChat)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(mutedInk)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(TheiaTheme.surface.opacity(0.7))
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty || state.qwenChatImageAttachment != nil
    }

    private func send() {
        guard canSend, !state.isQwenChatResponding else { return }
        let message = trimmedDraft.isEmpty
            ? "Inspect this screenshot, predict what I’m doing, and suggest the next useful steps."
            : trimmedDraft
        draft = ""
        coordinator.sendQwenChatMessage(message)
    }
}

struct ChatHistoryView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var state: AppState
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue
    @State private var pendingDeletionID: UUID?

    var body: some View {
        ZStack {
            TheiaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(TheiaTheme.border)
                content
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .foregroundStyle(TheiaTheme.ink)
        .tint(TheiaTheme.action)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { pendingDeletionID != nil },
                set: { if !$0 { pendingDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Chat", role: .destructive) {
                if let id = pendingDeletionID {
                    coordinator.deleteQwenChatConversation(id)
                }
                pendingDeletionID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("This removes the conversation from local history on this Mac.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TheiaMark(size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("Chat History")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(TheiaTheme.ink)
                Text("Conversations with at least one message you sent")
                    .font(.caption)
                    .foregroundStyle(TheiaTheme.mutedInk)
            }
            Spacer()
            Button(action: coordinator.closeChatHistory) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .frame(width: 30, height: 30)
                    .background(TheiaTheme.surfaceStrong, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TheiaTheme.mutedInk)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if state.qwenChatConversations.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(TheiaTheme.action)
                Text("No saved chats")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(TheiaTheme.ink)
                Text("A conversation appears here after you send its first message.")
                    .font(.caption)
                    .foregroundStyle(TheiaTheme.mutedInk)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.qwenChatConversations) { conversation in
                        historyRow(conversation)
                    }
                }
                .padding(18)
            }
        }
    }

    private func historyRow(_ conversation: QwenChatConversation) -> some View {
        HStack(spacing: 12) {
            Button {
                coordinator.selectQwenChatConversation(conversation.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: conversation.mode == .general ? "bubble.left" : "scope")
                        .foregroundStyle(TheiaTheme.action)
                        .frame(width: 34, height: 34)
                        .background(TheiaTheme.surfaceStrong, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(conversation.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(TheiaTheme.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(TheiaTheme.mutedInk)
                        }
                        Text(previewText(for: conversation))
                            .font(.caption)
                            .foregroundStyle(TheiaTheme.mutedInk)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                pendingDeletionID = conversation.id
            } label: {
                Image(systemName: "trash")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Delete chat")
        }
        .padding(13)
        .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(TheiaTheme.border))
    }

    private var footer: some View {
        HStack {
            Label("Stored locally with timestamps", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(TheiaTheme.mutedInk)
            Spacer()
            Button("New Chat") {
                coordinator.showGeneralQwenChat()
            }
            .buttonStyle(.borderedProminent)
            .tint(TheiaTheme.action)
            .foregroundStyle(TheiaTheme.actionText)
        }
        .padding(18)
        .background(TheiaTheme.surface.opacity(0.75))
    }

    private func previewText(for conversation: QwenChatConversation) -> String {
        conversation.messages.first(where: { $0.role == .user })?.text ?? ""
    }
}

private struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView

        init(parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}
