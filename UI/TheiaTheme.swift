import AppKit
import SwiftUI

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum TheiaTheme {
    static let silverTop = adaptive(
        light: NSColor(calibratedRed: 0.76, green: 0.78, blue: 0.81, alpha: 1),
        dark: NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.12, alpha: 1)
    )
    static let silverBottom = adaptive(
        light: NSColor(calibratedRed: 0.53, green: 0.57, blue: 0.62, alpha: 1),
        dark: NSColor(calibratedRed: 0.035, green: 0.04, blue: 0.05, alpha: 1)
    )
    static let metalHighlight = adaptive(
        light: NSColor(calibratedRed: 0.87, green: 0.89, blue: 0.91, alpha: 1),
        dark: NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
    )
    static let metalMid = adaptive(
        light: NSColor(calibratedRed: 0.64, green: 0.68, blue: 0.72, alpha: 1),
        dark: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.095, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.86, alpha: 0.96),
        dark: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.96)
    )
    static let surfaceStrong = adaptive(
        light: NSColor(calibratedRed: 0.89, green: 0.91, blue: 0.93, alpha: 0.98),
        dark: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 0.98)
    )
    static let ink = adaptive(
        light: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.19, alpha: 1),
        dark: NSColor.white
    )
    static let mutedInk = adaptive(
        light: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.23, alpha: 1),
        dark: NSColor.white
    )
    static let border = adaptive(
        light: NSColor.black.withAlphaComponent(0.16),
        dark: NSColor.white.withAlphaComponent(0.13)
    )
    static let blue = adaptive(
        light: NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.45, alpha: 1),
        dark: NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.82, alpha: 1)
    )
    static let blueDeep = adaptive(
        light: NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.27, alpha: 1),
        dark: NSColor(calibratedRed: 0.18, green: 0.38, blue: 0.58, alpha: 1)
    )
    static let gold = Color(red: 0.78, green: 0.55, blue: 0.15)
    static let goldBright = Color(red: 0.96, green: 0.72, blue: 0.25)
    static let action = adaptive(
        light: NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.45, alpha: 1),
        dark: NSColor(calibratedRed: 0.62, green: 0.43, blue: 0.13, alpha: 1)
    )
    static let actionPressed = adaptive(
        light: NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.27, alpha: 1),
        dark: NSColor(calibratedRed: 0.45, green: 0.29, blue: 0.07, alpha: 1)
    )
    static let actionText = adaptive(
        light: NSColor.white,
        dark: NSColor.white
    )
    static let cancel = adaptive(
        light: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.31, alpha: 1),
        dark: NSColor(calibratedRed: 0.46, green: 0.22, blue: 0.23, alpha: 1)
    )
    static let cancelPressed = adaptive(
        light: NSColor(calibratedRed: 0.40, green: 0.19, blue: 0.21, alpha: 1),
        dark: NSColor(calibratedRed: 0.32, green: 0.13, blue: 0.15, alpha: 1)
    )
    static let danger = Color(red: 0.68, green: 0.20, blue: 0.17)

    static var background: LinearGradient {
        LinearGradient(
            colors: [silverTop, metalMid, metalHighlight, metalMid, silverBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
