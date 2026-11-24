import SwiftUI
import MatchTrackerKit

/// The three colors that mean something. The extension doesn't link the app's `Theme`; these are
/// the same values.
enum SurfacePalette {
    /// You and your team.
    static var us: Color { worn(\.tintOnDark, light: \.tintOnLight) }
    /// The opponent.
    static var them: Color { worn(\.themOnDark, light: \.themOnLight) }
    static let heart = dynamic(dark: (1.0, 0.416, 0.573), light: (0.722, 0.094, 0.322))

    static var cloth: Color { Cloth.shirt }
    static let ivory = Cloth.ivory

    private static func worn(_ dark: KeyPath<KitColors, KitColors.RGB>, light: KeyPath<KitColors, KitColors.RGB>) -> Color {
        let kit = KitColors.current
        let (dark, light) = (kit[keyPath: dark], kit[keyPath: light])
        return dynamic(dark: (dark.red, dark.green, dark.blue), light: (light.red, light.green, light.blue))
    }

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let components = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}

/// The app's cloth: a pinstripe, and a hem along the bottom.
struct WidgetCloth: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SurfacePalette.cloth))
            var stripes = Path()
            for x in stride(from: CGFloat(9), to: size.width, by: 18) {
                stripes.move(to: CGPoint(x: x, y: 0))
                stripes.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(stripes, with: .color(SurfacePalette.ivory.opacity(0.08)), lineWidth: 1)
            context.fill(Path(CGRect(x: 0, y: size.height - 4, width: size.width, height: 4)), with: .color(SurfacePalette.ivory))
        }
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
