import SwiftUI

struct TheiaMark: View {
    var size: CGFloat = 96
    var animated = false

    var body: some View {
        Image("TheiaLogo")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityLabel("Theia")
    }
}

struct OnboardingView: View {
    let complete: () -> Void

    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var page = 0
    @AppStorage(TheiaPreferenceKey.experienceFocus) private var selectedFocus = "Everyday"
    @AppStorage(TheiaPreferenceKey.responseStyle) private var selectedStyle = "Balanced"
    @State private var isVisible = false
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                HStack {
                    if page > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { page -= 1 }
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TheiaTheme.blue)
                    }

                    Spacer()

                    if page > 0 {
                        Text("\(page) of 3")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(TheiaTheme.mutedInk)
                    }
                }
                .frame(height: 34)

                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: focusPage
                    case 2: stylePage
                    default: voicePage
                    }
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                Spacer(minLength: 24)

                if page > 0 {
                    pageIndicator
                }
            }
            .padding(34)
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 560)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.985)
        .tint(TheiaTheme.action)
        .foregroundStyle(TheiaTheme.ink)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { isVisible = true }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 18)

            TheiaMark(size: 132, animated: true)
                .shadow(color: TheiaTheme.blue.opacity(0.18), radius: 35)

            VStack(spacing: 2) {
                Text("Welcome to Theia")
                    .font(.custom("Snell Roundhand", size: 56))
                    .foregroundStyle(TheiaTheme.ink)

                Text("A thoughtful second look at whatever is on your screen.")
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(TheiaTheme.mutedInk)
            }

            Button("Begin") {
                withAnimation(.easeInOut(duration: 0.35)) { page = 1 }
            }
            .buttonStyle(TheiaPrimaryButtonStyle())
            .padding(.top, 12)

            Spacer(minLength: 12)
        }
    }

    private var focusPage: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 9) {
                Text("What should Theia notice?")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Choose a starting point. You can change this later in Settings.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(TheiaTheme.mutedInk)
                    .frame(maxWidth: 530, alignment: .leading)
            }

            HStack(spacing: 12) {
                selectionCard("Everyday", icon: "sparkles", detail: "A useful mix")
                selectionCard("Work", icon: "briefcase.fill", detail: "Focus and research")
                selectionCard("Learning", icon: "book.closed.fill", detail: "Explain and explore")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.35)) { page = 2 }
                }
                .buttonStyle(TheiaPrimaryButtonStyle())
            }
        }
        .foregroundStyle(TheiaTheme.ink)
        .padding(.horizontal, 22)
        .padding(.top, 30)
    }

    private var stylePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Make it feel like yours")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Pick how Theia should shape its suggestions. You can change this later in Settings.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(TheiaTheme.mutedInk)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            VStack(spacing: 10) {
                styleRow("Concise", detail: "Short, direct next steps", icon: "text.alignleft")
                styleRow("Balanced", detail: "Context with clear choices", icon: "slider.horizontal.3")
                styleRow("Exploratory", detail: "More paths and possibilities", icon: "point.3.connected.trianglepath.dotted")
            }

            Spacer()

            HStack {
                Label("Screen understanding stays on this Mac", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(TheiaTheme.mutedInk)
                Spacer()
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.35)) { page = 3 }
                }
                    .buttonStyle(TheiaPrimaryButtonStyle())
            }
        }
        .foregroundStyle(TheiaTheme.ink)
        .padding(.horizontal, 22)
        .padding(.top, 24)
    }

    private var voicePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Ask Siri to use Theia")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Connect Siri through a one-time local shortcut, with no voice calibration and no continuously open microphone.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(TheiaTheme.mutedInk)
                    .frame(maxWidth: 590, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(TheiaTheme.blue)
                        .frame(width: 48, height: 48)
                        .background(TheiaTheme.surfaceStrong, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create a local Siri shortcut")
                            .font(.headline)
                        Text("Open Shortcuts, add Theia’s screen-analysis action, and name it “Ask Theia to Analyze My Screen.” macOS requires this user shortcut before Siri can run a local app action by name.")
                            .font(.caption)
                            .foregroundStyle(TheiaTheme.mutedInk)
                    }
                }

                HStack(spacing: 10) {
                    Button("Open Siri Settings") {
                        coordinator.openSiriSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Shortcuts") {
                        coordinator.openShortcutsApp()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .background(TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(TheiaTheme.border))

            Text("Siri owns speech recognition and its privacy indicators. Theia receives only the resolved shortcut request and never opens your microphone.")
                .font(.caption)
                .foregroundStyle(TheiaTheme.mutedInk)

            Spacer()

            HStack {
                Spacer()
                Button("Start using Theia", action: complete)
                    .buttonStyle(TheiaPrimaryButtonStyle())
            }
        }
        .foregroundStyle(TheiaTheme.ink)
        .padding(.horizontal, 22)
        .padding(.top, 24)
    }

    private var onboardingBackground: some View {
        ZStack {
            TheiaTheme.background
            Circle()
                .fill(TheiaTheme.blue.opacity(0.10))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: 300, y: -230)
            Circle()
                .fill(TheiaTheme.gold.opacity(0.12))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: -330, y: 250)
        }
        .ignoresSafeArea()
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(1...3, id: \.self) { index in
                Capsule()
                    .fill(index == page ? TheiaTheme.blue : TheiaTheme.mutedInk.opacity(0.25))
                    .frame(width: index == page ? 22 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.25), value: page)
            }
        }
        .frame(height: 14)
    }

    private func selectionCard(_ title: String, icon: String, detail: String) -> some View {
        Button {
            selectedFocus = title
        } label: {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(selectedFocus == title ? TheiaTheme.gold : TheiaTheme.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(TheiaTheme.mutedInk)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(18)
            .background(
                selectedFocus == title ? TheiaTheme.surfaceStrong : TheiaTheme.surface,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(selectedFocus == title ? TheiaTheme.gold.opacity(0.8) : TheiaTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func styleRow(_ title: String, detail: String, icon: String) -> some View {
        Button {
            selectedStyle = title
        } label: {
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selectedStyle == title ? TheiaTheme.gold : TheiaTheme.blue.opacity(0.8))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(TheiaTheme.mutedInk)
                }
                Spacer()
                Image(systemName: selectedStyle == title ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedStyle == title ? TheiaTheme.gold : TheiaTheme.mutedInk.opacity(0.25))
            }
            .padding(.horizontal, 17)
            .frame(height: 64)
            .background(selectedStyle == title ? TheiaTheme.surfaceStrong : TheiaTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }
}

private struct TheiaPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(TheiaTheme.actionText)
            .padding(.horizontal, 24)
            .frame(height: 42)
            .background(
                configuration.isPressed ? TheiaTheme.actionPressed : TheiaTheme.action,
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
