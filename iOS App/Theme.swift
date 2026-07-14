// Theme.swift
// MatchTracker
//
// Single source of truth for the app's visual identity: an athlete-tracker look that is
// performance-first and dark-first — near-black backgrounds, elevated cards with big radii
// and thin luminous strokes, electric neon accents, and glassy overlays. Colors resolve per
// trait so both color schemes stay legible (dark is the identity; light deepens saturation
// rather than washing out to pastels).

import SwiftUI

enum Theme {
    // MARK: - Palette

    /// Builds a dynamic color from dark-scheme and light-scheme components.
    private static func dynamic(dark: (Double, Double, Double),
                                light: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Near-black canvas in dark, soft off-white in light.
    static let background = dynamic(dark: (0.043, 0.051, 0.063),
                                    light: (0.953, 0.961, 0.976))
    /// Elevated card fill.
    static let surface = dynamic(dark: (0.078, 0.090, 0.110),
                                 light: (1.0, 1.0, 1.0))
    /// Slightly higher elevation (nested tiles on top of a surface).
    static let surfaceElevated = dynamic(dark: (0.110, 0.125, 0.149),
                                         light: (0.965, 0.973, 0.984))
    /// Hairline stroke around cards.
    static let surfaceStroke = Color.white.opacity(0.08)

    // Semantic accents — used consistently app-wide.
    /// Electric green — the app's primary tint / turf energy.
    static let turf = dynamic(dark: (0.204, 0.961, 0.631),
                              light: (0.043, 0.643, 0.396))
    /// Cyan signal.
    static let signal = dynamic(dark: (0.243, 0.859, 1.0),
                                light: (0.0, 0.541, 0.702))
    /// Neon coral — heart rate.
    static let heart = dynamic(dark: (1.0, 0.361, 0.478),
                               light: (0.898, 0.157, 0.310))
    /// Electric blue — distance / pace.
    static let pace = dynamic(dark: (0.302, 0.486, 1.0),
                              light: (0.169, 0.353, 0.918))
    /// Magenta-orange — sprints.
    static let sprint = dynamic(dark: (1.0, 0.478, 0.239),
                                light: (0.878, 0.325, 0.078))
    /// Lime — goals / positive.
    static let goal = dynamic(dark: (0.784, 1.0, 0.302),
                              light: (0.435, 0.612, 0.043))
    /// Amber — bench / caution.
    static let bench = dynamic(dark: (1.0, 0.741, 0.239),
                               light: (0.831, 0.549, 0.043))

    // MARK: - Signature gradients

    /// Turf → signal linear flow, used for hero accents and live borders.
    static var turfFlow: LinearGradient {
        LinearGradient(colors: [turf, signal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Angular sweep for the workrate score ring.
    static var scoreRing: AngularGradient {
        AngularGradient(colors: [turf, signal, pace, turf],
                        center: .center)
    }

    // MARK: - Pitch canvas colors

    /// Deep green-black turf top color (for a vertical gradient with `pitchTurfBottom`).
    static let pitchTurfTop = Color(red: 0.055, green: 0.176, blue: 0.129)
    static let pitchTurfBottom = Color(red: 0.020, green: 0.086, blue: 0.071)
    /// Pitch markings — luminous white.
    static let pitchLines = Color.white.opacity(0.70)

    /// Vertical turf gradient used to fill pitch canvases.
    static var pitchGradient: LinearGradient {
        LinearGradient(colors: [pitchTurfTop, pitchTurfBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Section header gradients

    /// Subtle top-anchored wash in a semantic hue — the signature "gradient header" that opens
    /// each detail section, so users learn to read the app by color.
    static func headerGradient(_ tint: Color) -> LinearGradient {
        LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.0)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Semantic hue for each match-detail section.
    static func sectionTint(_ section: String) -> Color {
        switch section {
        case "Heatmap": return sprint
        case "Runs": return sprint
        case "Workrate": return turf
        case "Position": return pace
        case "Events": return goal
        case "Video": return signal
        default: return turf
        }
    }
}

// MARK: - Haptics

/// Lightweight haptic feedback for meaningful selections (kept cheap and optional).
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Section header

/// The signature section opener: an uppercase title over a soft semantic gradient wash.
struct SectionHeaderBar: View {
    let title: String
    var tint: Color = Theme.turf
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).captionLabel().foregroundStyle(tint)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Typography helpers

extension Text {
    /// Big rounded hero numeral (score, headline metric).
    func heroNumeral() -> some View {
        self.font(.system(size: 56, weight: .bold, design: .rounded))
            .monospacedDigit()
    }

    /// Medium rounded stat numeral.
    func statNumeral() -> some View {
        self.font(.system(size: 26, weight: .bold, design: .rounded))
            .monospacedDigit()
    }

    /// Uppercase, tracked caption label used above/below numerals.
    func captionLabel() -> some View {
        self.font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - View modifiers

extension View {
    /// Elevated card: surface fill, 22pt radius, hairline stroke, soft shadow.
    func themedCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(ThemedCard(cornerRadius: cornerRadius))
    }

    /// Glassy overlay card (.ultraThinMaterial) for sheets and floating panels.
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    /// Metric tile: elevated surface with a semantic tint wash and thin tinted stroke.
    func metricTile(tint: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(MetricTile(tint: tint, cornerRadius: cornerRadius))
    }

    /// Neon glow shadow in the given color.
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.5), radius: radius)
    }
}

struct ThemedCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
    }
}

struct MetricTile: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Theme.surfaceElevated
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
