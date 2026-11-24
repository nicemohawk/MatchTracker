import SwiftUI
import MatchTrackerKit

/// The three colors that mean something. The extension doesn't link the app's `Theme`; these are
/// the same values.
enum SurfacePalette {
    /// You and your team.
    static let us = dynamic(dark: (0.188, 0.820, 0.345), light: (0.024, 0.510, 0.208))
    /// The opponent.
    static let them = dynamic(dark: (1.0, 0.271, 0.227), light: (0.812, 0.126, 0.086))
    static let heart = dynamic(dark: (1.0, 0.365, 0.494), light: (0.835, 0.075, 0.243))

    static let pitchTop = Color(red: 0.055, green: 0.176, blue: 0.129)
    static let pitchBottom = Color(red: 0.020, green: 0.086, blue: 0.071)

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let components = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}

extension MatchDigest.Result {
    var color: Color {
        switch self {
        case .won: return SurfacePalette.us
        case .drawn: return .secondary
        case .lost: return SurfacePalette.them
        }
    }
}

/// The match clock: ticking by itself while play is on, still when it isn't.
struct MatchClock: View {
    let state: LiveMatchState
    var isStale = false

    var body: some View {
        if state.isClockRunning && !isStale {
            // Apple's timer text stops at the end of its range; no match lasts eight hours.
            Text(timerInterval: state.clockStart...state.clockStart.addingTimeInterval(8 * 3600), countsDown: false)
        } else {
            Text(MatchTrackerFormat.hoursMinutesSeconds(state.elapsed))
        }
    }
}

extension LiveMatchState {
    /// On the pitch with the ball rolling: the one status that's green.
    var isPlaying: Bool { onPitch == true && !isAtBreak && isClockRunning }

    var statusSymbol: String {
        if hasEnded { return "flag.checkered" }
        if isAtBreak || isPaused { return "pause.fill" }
        switch onPitch {
        case true?: return "figure.soccer"
        case false?: return "chair"
        case nil: return "applewatch"
        }
    }
}
