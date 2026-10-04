import HourGlassCore

/// What fills the screen.
enum SandMode: String, CaseIterable, Identifiable {
    /// Loose sand across the whole display.
    case sandbox
    /// A glass hourglass that keeps time.
    case hourglass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sandbox: "Sandbox"
        case .hourglass: "Hourglass"
        }
    }

    var shape: Container.Shape {
        switch self {
        case .sandbox: .screen
        case .hourglass: .hourglass
        }
    }
}

/// How big a grain is on screen, in pixels.
enum GrainSize: Int, CaseIterable, Identifiable {
    case fine = 2
    case medium = 3
    case coarse = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fine: "Fine"
        case .medium: "Medium"
        case .coarse: "Coarse"
        }
    }
}

/// The timer lengths the hourglass offers, in seconds.
enum HourglassDurations {
    static let all: [Int] = [30, 60, 120, 180, 300, 600, 900, 1200, 1800, 2700, 3600]
    static let standard = 60

    static func index(of seconds: Int) -> Int {
        all.firstIndex(of: seconds) ?? all.firstIndex(of: standard)!
    }

    static func label(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
    }
}

/// `@AppStorage` keys.
enum SettingsKey {
    static let mode = "mode"
    static let palette = "palette"
    static let grain = "grain"
    static let haptics = "haptics"
    static let fill = "fill"
    static let timer = "timerSeconds"
}

/// Formats a countdown as m:ss, or h:mm:ss past the hour.
func countdownText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
