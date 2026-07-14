//
//  WatchTheme.swift
//  MatchTracker Watch App
//
//  The watch-side mirror of iOS `Theme` — the SAME semantic palette so both platforms read as
//  one product. watchOS is an always-dark environment, so colors resolve to the dark-scheme
//  values directly (no trait-based dynamic provider). Backgrounds are pure black by watch
//  convention; `surface`/`surfaceElevated` fill cards and tiles. Everything here is a reskin +
//  interaction-feedback toolkit: palette, typography, tinted button styles, a confirmation
//  flash, and WKInterfaceDevice haptics. No behavior or WorkoutManager API lives here.
//

import SwiftUI
import WatchKit

enum WatchTheme {
    // MARK: - Palette (dark-scheme values, matching iOS Theme)

    /// Near-black canvas (#0C0D10). On watch we render scenes on pure black; this stays available
    /// for the rare panel that wants the app's signature near-black instead of system black.
    static let background = Color(red: 0.047, green: 0.051, blue: 0.063)
    /// Elevated card fill (#16181D).
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.114)
    /// Nested tile fill on top of a surface (#1D2026).
    static let surfaceElevated = Color(red: 0.114, green: 0.125, blue: 0.149)
    /// Hairline stroke around cards.
    static let surfaceStroke = Color.white.opacity(0.10)

    /// Emerald (#30D158) — primary tint / turf energy / goals-for.
    static let turf = Color(red: 0.188, green: 0.820, blue: 0.345)
    /// Quiet teal-mint (#66D4CF) signal.
    static let signal = Color(red: 0.400, green: 0.831, blue: 0.812)
    /// Rose (#FF375F) — heart rate.
    static let heart = Color(red: 1.0, green: 0.216, blue: 0.373)
    /// Blue (#409CFF) — distance / pace.
    static let pace = Color(red: 0.251, green: 0.612, blue: 1.0)
    /// Amber-orange (#FF9F0A) — sprints.
    static let sprint = Color(red: 1.0, green: 0.624, blue: 0.039)
    /// Neutral gray (#98989D) — bench / off-pitch reads neutral.
    static let bench = Color(red: 0.596, green: 0.596, blue: 0.616)
    /// Red (#FF453A) — a loss / goals-against, distinct from heart's rose.
    static let loss = Color(red: 1.0, green: 0.271, blue: 0.227)
    /// Card yellow (#FFD60A) — cautions / yellow cards.
    static let cardYellow = Color(red: 1.0, green: 0.839, blue: 0.039)
    /// Goals / positive — aliased to turf for API stability.
    static let goal = turf

    // MARK: - Tint washes (mirror iOS chip conventions, dark values)

    /// Tint-on-translucent fill: the hue at a low alpha. The house style for every tinted surface.
    static func chipFill(_ color: Color) -> Color { color.opacity(0.22) }
    /// Hairline stroke to match `chipFill` — same hue, a touch stronger.
    static func chipStroke(_ color: Color) -> Color { color.opacity(0.45) }

    // MARK: - Signature gradients

    /// Turf → signal flow, used for the hero Start button.
    static var turfFlow: LinearGradient {
        LinearGradient(colors: [turf, signal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Haptics

/// Thin wrapper over WKInterfaceDevice so event/control feedback reads semantically at call sites.
enum WatchHaptics {
    static func success() { WKInterfaceDevice.current().play(.success) }
    static func failure() { WKInterfaceDevice.current().play(.failure) }
    static func notify()  { WKInterfaceDevice.current().play(.notification) }
    static func click()   { WKInterfaceDevice.current().play(.click) }
    static func stop()    { WKInterfaceDevice.current().play(.stop) }

    /// The haptic that best fits a logged event — positive moments get a success tap, opponent
    /// goals a failure buzz, cards/fouls a notification, everything else a light click.
    static func forEvent(positive: Bool, caution: Bool, negative: Bool) {
        if negative { failure() }
        else if caution { notify() }
        else if positive { success() }
        else { click() }
    }
}

// MARK: - Typography helpers

extension Text {
    /// Big rounded hero numeral (score, countdown) sized for the watch face.
    func watchHeroNumeral() -> some View {
        font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
    }

    /// Medium rounded stat numeral for summary/metric values.
    func watchStatNumeral() -> some View {
        font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
    }

    /// Uppercase, tracked caption label above/below numerals.
    func watchCaptionLabel() -> some View {
        font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(1.1)
    }
}

// MARK: - Card / tile modifiers

extension View {
    /// Elevated card: surface fill, hairline stroke, watch-scaled radius.
    func watchCard(cornerRadius: CGFloat = 14) -> some View {
        background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(WatchTheme.surfaceStroke, lineWidth: 1)
            )
    }

    /// Metric/stat tile: elevated surface with a semantic tint wash and a thin tinted stroke.
    func watchTile(tint: Color, cornerRadius: CGFloat = 12) -> some View {
        background(
            ZStack {
                WatchTheme.surfaceElevated
                tint.opacity(0.12)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Button styles

/// Fat-finger event/control tile: a tinted translucent fill with a hairline tinted stroke and a
/// short spring press-scale. Semantic tint tells the player what they tapped without reading.
struct WatchTileButtonStyle: ButtonStyle {
    var tint: Color
    var minHeight: CGFloat = 56
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.black : tint)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                ZStack {
                    if prominent {
                        shape.fill(tint.gradient)
                    } else {
                        shape.fill(WatchTheme.chipFill(tint))
                        shape.strokeBorder(WatchTheme.chipStroke(tint), lineWidth: 1)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Round Apple-Workout-style control: a tinted circle with the glyph inside; the caller draws the
/// label beneath. Presses spring inward.
struct WatchControlButtonStyle: ButtonStyle {
    var tint: Color
    var diameter: CGFloat = 52

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background {
                Circle().fill(WatchTheme.chipFill(tint))
                Circle().strokeBorder(WatchTheme.chipStroke(tint), lineWidth: 1.5)
            }
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Confirmation flash

/// A brief centered checkmark + label the player sees the instant an event registers, so they
/// know it landed without looking closely. Springs in, fades out — driven by the owning view.
struct ConfirmationFlash: View {
    let text: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = WatchTheme.turf

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
