import AppKit
import CoreGraphics
import ScreenCaptureKit

struct CapturedFrame {
    let cgImage: CGImage
    let image: NSImage
}

enum ScreenCaptureError: LocalizedError {
    case displayUnavailable
    case windowUnavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "The current display could not be identified."
        case .windowUnavailable:
            return "The frontmost application does not have a captureable window."
        case .captureFailed:
            return "macOS could not capture the frontmost window."
        }
    }
}

struct ScreenCaptureService {
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Resolves the frontmost normal window before Theia opens its analysis panel.
    /// The returned ID remains stable while the panel is being presented.
    func frontmostWindowID() -> CGWindowID? {
        captureableWindowIDs().first
    }

    /// Captures only the topmost application window, excluding Theia's own UI.
    func captureFrontmostWindow(preferredWindowID: CGWindowID? = nil) async throws -> CapturedFrame {
        guard let windowID = preferredWindowID ?? frontmostWindowID() else {
            throw ScreenCaptureError.windowUnavailable
        }

        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )

            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenCaptureError.windowUnavailable
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = max(1, Int((NSScreen.main?.backingScaleFactor ?? 2).rounded()))
            configuration.width = max(1, Int(window.frame.width) * scale)
            configuration.height = max(1, Int(window.frame.height) * scale)
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return makeFrame(from: cgImage)
        }

        return try captureLegacyWindow(windowID)
    }

    /// Kept for callers using the original MVP API. It now intentionally captures
    /// the frontmost window rather than all visible windows on the display.
    func captureCurrentDisplay() async throws -> CapturedFrame {
        try await captureFrontmostWindow()
    }

    @available(macOS, introduced: 10.6, obsoleted: 14.0)
    private func captureLegacyWindow(_ windowID: CGWindowID) throws -> CapturedFrame {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw ScreenCaptureError.captureFailed
        }

        return makeFrame(from: cgImage)
    }

    private func makeFrame(from cgImage: CGImage) -> CapturedFrame {
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return CapturedFrame(cgImage: cgImage, image: image)
    }

    private func captureableWindowIDs() -> [CGWindowID] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return windowList.compactMap { window -> CGWindowID? in
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let ownerName = window[kCGWindowOwnerName as String] as? String
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let bounds: CGRect?
            if let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any] {
                bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            } else {
                bounds = nil
            }

            guard layer == 0,
                  processID != 0,
                  processID != ownProcessID,
                  !isTransientSystemUI(ownerName: ownerName, processID: processID),
                  alpha > 0,
                  let windowID,
                  let bounds,
                  bounds.width >= 80,
                  bounds.height >= 80
            else {
                return nil
            }
            return CGWindowID(windowID)
        }
    }

    /// Siri briefly presents system UI above the app the user actually asked
    /// Theia to inspect. Excluding those transient surfaces keeps Siri-triggered
    /// analysis pointed at the underlying working window.
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
}
