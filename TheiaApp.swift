import AppKit
import AppIntents
import SwiftUI

final class TheiaApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = AppearanceMode.current.nsAppearance
        NSApplication.shared.applicationIconImage = NSImage(named: "TheiaLogo")
    }

    func applicationWillTerminate(_ notification: Notification) {
        OllamaRuntimeManager.shared.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let commands = urls.compactMap(TheiaCommandURL.command)
        guard !commands.isEmpty else { return }
        Task { @MainActor in
            commands.forEach(TheiaSiriCommandRouter.submit)
        }
    }
}

@main
struct TheiaApp: App {
    @NSApplicationDelegateAdaptor(TheiaApplicationDelegate.self) private var applicationDelegate
    @StateObject private var coordinator = AppCoordinator()
    @AppStorage(TheiaPreferenceKey.appearanceMode) private var appearanceModeValue = AppearanceMode.system.rawValue

    init() {
        // Register before the application finishes launching so Siri and
        // Shortcuts can index Theia on the first run after installation.
        if #available(macOS 13.0, *) {
            TheiaAppShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.state)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceModeValue) ?? .system).colorScheme)
        }
    }
}
