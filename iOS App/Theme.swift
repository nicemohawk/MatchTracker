// Theme.swift
// MatchTracker
//
// Single source of truth for the app's visual identity: an athlete-tracker look that is
// performance-first and dark-first — near-black backgrounds, elevated cards with big radii
// and thin hairline strokes, Apple-system-anchored accents on tinted-translucent chips, and
// glassy overlays. Glow is rare (reserved for the hero workrate ring and the live pulse dot).
// Colors resolve per trait so both color schemes stay legible (dark is the identity; light
// deepens saturation rather than washing out to pastels).

import SwiftUI

enum Theme {
    // MARK: - Layout

    /// Horizontal content inset that MatchDetailView applies to section content via
    /// `.padding(.horizontal)` (the SwiftUI system default). `View.fullBleed()` negates exactly
    /// this so a hero element can span edge-to-edge without the container changing its padding.
    static let detailContentInset: CGFloat = 16

    // MARK: - Palette

    /// Builds a dynamic color from dark-scheme and light-scheme components.
    private static func dynamic(dark: (Double, Double, Double),
                                light: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// A tint at a scheme-dependent alpha. Dark keeps the bold identity opacity; light drops far
    /// lower so tinted washes stay a whisper instead of reading as a pastel/nursery fill.
    static func tintWash(_ color: Color, dark: Double, light: Double) -> Color {
        Color(uiColor: UIColor { traits in
            let resolved = UIColor(color).resolvedColor(with: traits)
            let alpha = traits.userInterfaceStyle == .light ? light : dark
            return resolved.withAlphaComponent(alpha)
        })
    }

    /// Tint-on-translucent chip fill: the hue at a low alpha over the surface. The house style for
    /// every status chip/capsule — never a solid saturated fill. Dark ~22%, light ~14%.
    static func chipFill(_ color: Color) -> Color {
        tintWash(color, dark: 0.22, light: 0.14)
    }

    /// Hairline stroke to match `chipFill` — the same hue, a touch stronger.
    static func chipStroke(_ color: Color) -> Color {
        tintWash(color, dark: 0.45, light: 0.30)
    }

    /// Near-black canvas in dark (#0C0D10), soft off-white in light.
    static let background = dynamic(dark: (0.047, 0.051, 0.063),
                                    light: (0.949, 0.957, 0.969))
    /// Elevated card fill (#16181D dark).
    static let surface = dynamic(dark: (0.086, 0.094, 0.114),
                                 light: (1.0, 1.0, 1.0))
    /// Slightly higher elevation (nested tiles on top of a surface, #1D2026 dark).
    static let surfaceElevated = dynamic(dark: (0.114, 0.125, 0.149),
                                         light: (0.965, 0.973, 0.984))
    /// Hairline stroke around cards.
    static let surfaceStroke = Color.white.opacity(0.08)

    // Semantic accents — anchored to Apple system hues so the palette reads premium, not arcade.
    /// Emerald (#30D158) — the app's primary tint / turf energy.
    static let turf = dynamic(dark: (0.188, 0.820, 0.345),
                              light: (0.024, 0.588, 0.239))
    /// Quiet teal-mint (#66D4CF) signal.
    static let signal = dynamic(dark: (0.400, 0.831, 0.812),
                                light: (0.0, 0.478, 0.463))
    /// Rose (#FF375F) — heart rate.
    static let heart = dynamic(dark: (1.0, 0.216, 0.373),
                               light: (0.835, 0.075, 0.243))
    /// Blue (#409CFF) — distance / pace.
    static let pace = dynamic(dark: (0.251, 0.612, 1.0),
                              light: (0.078, 0.412, 0.882))
    /// Amber-orange (#FF9F0A) — sprints.
    static let sprint = dynamic(dark: (1.0, 0.624, 0.039),
                                light: (0.812, 0.451, 0.0))
    /// Goals / positive. Aliased to `turf` — wins are green — but kept as a named symbol for
    /// API stability so call sites reading `Theme.goal` need not change.
    static let goal = turf
    /// Neutral gray (#98989D) — bench / draws read neutral, not amber.
    static let bench = dynamic(dark: (0.596, 0.596, 0.616),
                               light: (0.400, 0.400, 0.420))
    /// Red (#FF453A) — a loss, distinct from `heart`'s rose so score chips don't collide.
    static let loss = dynamic(dark: (1.0, 0.271, 0.227),
                              light: (0.812, 0.126, 0.086))
    /// Card yellow (#FFD60A) — reserved for yellow cards, where amber must read as a caution.
    static let cardYellow = dynamic(dark: (1.0, 0.839, 0.039),
                                    light: (0.694, 0.541, 0.0))

    // MARK: - Signature gradients

    /// Turf → signal linear flow, used for hero accents and live borders.
    static var turfFlow: LinearGradient {
        LinearGradient(colors: [turf, signal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Faint turf → signal wash for the detail hero card. Dark keeps the ~10% tinted glow; light
    /// drops to ~5% over the white surface so the card reads as a neutral panel, not mint.
    static var heroWash: LinearGradient {
        LinearGradient(colors: [tintWash(turf, dark: 0.10, light: 0.05),
                                tintWash(signal, dark: 0.10, light: 0.05)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
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
        LinearGradient(colors: [tintWash(tint, dark: 0.28, light: 0.07), tint.opacity(0.0)],
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
    /// Opt a section element OUT of the match-detail scroll container's horizontal content
    /// padding so it draws edge-to-edge (full bleed). MatchDetailView keeps applying
    /// `.padding(.horizontal)` (system default, 16pt) to section content; this cancels exactly
    /// that inset for a single hero element while supporting content stays padded. Additive,
    /// non-destructive — the container's padding is untouched.
    func fullBleed() -> some View {
        padding(.horizontal, -Theme.detailContentInset)
    }

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

    /// Colored glow shadow. Use sparingly — reserved for the hero workrate ring and the live
    /// pulse dot; status chips, badges, and pitch marks take a plain faint shadow instead.
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
                    // Light: near-white tile with only a hint of tint; dark keeps the 12% wash.
                    Theme.tintWash(tint, dark: 0.12, light: 0.06)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.tintWash(tint, dark: 0.35, light: 0.20), lineWidth: 1)
            )
    }
}
