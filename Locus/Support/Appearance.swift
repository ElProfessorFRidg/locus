import SwiftUI

/// Which colour scheme Locus runs in.
///
/// The app used to force dark unconditionally, which suits a dark map and reads
/// well behind glass — but on iOS 26 an app that ignores the system appearance
/// stands out for the wrong reason, and a light-mode map in daylight is easier
/// to see. Dark stays the default so nothing changes for anyone who liked it.
enum LocusAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    /// `nil` hands the decision back to iOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    static let defaultsKey = "locus.appearance"
}
