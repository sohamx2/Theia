import AppKit
import CoreGraphics

struct SourceContextService {
    func capture() -> ScreenSourceContext {
        if let windowContext = frontmostWindowContext() {
            return windowContext.addingWebsites(
                activeBrowserWebsite(bundleIdentifier: windowContext.bundleIdentifier)
                    .map { [$0] } ?? []
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isTransientSystemUI(
                ownerName: application.localizedName,
                processID: application.processIdentifier
              )
        else {
            return .empty
        }

        let context = ScreenSourceContext(
            applicationName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: nil,
            websites: []
        )
        return context.addingWebsites(
            activeBrowserWebsite(bundleIdentifier: context.bundleIdentifier)
                .map { [$0] } ?? []
        )
    }

    private func frontmostWindowContext() -> ScreenSourceContext? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let processIdentifier = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String

            guard layer == 0,
                  processIdentifier != 0,
                  processIdentifier != ownProcessIdentifier,
                  ownerName != "Window Server",
                  !isTransientSystemUI(ownerName: ownerName, processID: processIdentifier)
            else { continue }

            let application = NSRunningApplication(processIdentifier: processIdentifier)
            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return ScreenSourceContext(
                applicationName: application?.localizedName ?? ownerName,
                bundleIdentifier: application?.bundleIdentifier,
                windowTitle: title?.isEmpty == false ? title : nil,
                websites: []
            )
        }
        return nil
    }

    private func isTransientSystemUI(ownerName: String?, processID: pid_t) -> Bool {
        let name = ownerName?.lowercased() ?? ""
        let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?
            .bundleIdentifier?
            .lowercased() ?? ""
        let ignoredNames: Set<String> = [
            "siri", "sirincservice", "control center", "notification center", "systemuiserver"
        ]
        return ignoredNames.contains(name) ||
            bundleIdentifier.hasPrefix("com.apple.siri") ||
            bundleIdentifier == "com.apple.assistantd" ||
            bundleIdentifier == "com.apple.controlcenter" ||
            bundleIdentifier == "com.apple.systemuiserver" ||
            bundleIdentifier == "com.apple.notificationcenterui"
    }

    /// Browser tabs and page content can contain many unrelated domains. Only
    /// the URL of the active tab is allowed to become website evidence.
    private func activeBrowserWebsite(bundleIdentifier: String?) -> String? {
        let source: String
        switch bundleIdentifier?.lowercased() {
        case "com.apple.safari":
            source = #"tell application id "com.apple.Safari" to if (count of windows) > 0 then return URL of current tab of front window"#
        case "com.apple.safaritechnologypreview":
            source = #"tell application id "com.apple.SafariTechnologyPreview" to if (count of windows) > 0 then return URL of current tab of front window"#
        case "com.google.chrome":
            source = #"tell application id "com.google.Chrome" to if (count of windows) > 0 then return URL of active tab of front window"#
        case "com.google.chrome.canary":
            source = #"tell application id "com.google.Chrome.canary" to if (count of windows) > 0 then return URL of active tab of front window"#
        case "com.microsoft.edgemac":
            source = #"tell application id "com.microsoft.edgemac" to if (count of windows) > 0 then return URL of active tab of front window"#
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        guard let value = NSAppleScript(source: source)?
            .executeAndReturnError(&errorInfo)
            .stringValue,
              errorInfo == nil
        else { return nil }
        return normalizedWebsite(from: value)
    }

    private func normalizedWebsite(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
