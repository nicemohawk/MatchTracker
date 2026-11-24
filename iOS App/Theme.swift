// Theme.swift
// MatchTracker
//
// The app's visual identity, kept small on purpose: system backgrounds, system type, one green.
// Dark is the identity; light is the same layout on system grouped backgrounds. The chip and tile
// helpers predate DESIGN.md and survive only for the sideline video screens.

import SwiftUI

enum Theme {
    /// The comfortable reading measure content is capped to at regular width (iPad, wide split
    /// views). Around this width a single column of cards / body copy stays legible instead of
    /// stretching edge-to-edge across ~1000+pt. See `View.readableWidth(_:)`.
    static let readableContentWidth: CGFloat = 700

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

    /// Legacy: tinted chip fill. DESIGN.md has no chips.
    static func chipFill(_ color: Color) -> Color {
        tintWash(color, dark: 0.22, light: 0.14)
    }

    /// Legacy: stroke to match `chipFill`.
    static func chipStroke(_ color: Color) -> Color {
        tintWash(color, dark: 0.45, light: 0.30)
    }

    /// The canvas behind cards and forms.
    static let background = Color(.systemGroupedBackground)
    /// A card or form row on `background`.
    static let surface = Color(.secondarySystemGroupedBackground)
    /// One step above `surface`.
    static let surfaceElevated = Color(.tertiarySystemGroupedBackground)
    /// Hairlines and empty tracks. Visible in both schemes, unlike white at 8%.
    static let surfaceStroke = Color(.separator)
    /// Labels that support a value. A concrete color rather than the hierarchical `.secondary`,
    /// so an outer tint can't turn it into a faint wash of itself.
    static let secondaryLabel = Color(.secondaryLabel)
    /// Text on a filled `turf` button: black on the bright dark-mode green, white on the deep one.
    static let onTurf = dynamic(dark: (0, 0, 0), light: (1, 1, 1))

    /// You and your team, and the app's tint. The light value holds 4.5:1 as text on white.
    static let turf = dynamic(dark: (0.188, 0.820, 0.345),
                              light: (0.0, 0.490, 0.200))
    /// Legacy: teal. DESIGN.md gives color three jobs and this isn't one of them.
    static let signal = dynamic(dark: (0.400, 0.831, 0.812),
                                light: (0.0, 0.478, 0.463))
    /// Rose (#FF375F) — heart rate.
    static let heart = dynamic(dark: (1.0, 0.216, 0.373),
                               light: (0.835, 0.075, 0.243))
    /// Legacy: blue, as `signal`.
    static let pace = dynamic(dark: (0.251, 0.612, 1.0),
                              light: (0.078, 0.412, 0.882))
    /// Legacy: amber, as `signal`. Still the warm end of intensity ramps.
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

/// A section title with an optional line under it.
struct SectionHeaderBar: View {
    let title: String
    /// Legacy: titles are primary text; the tint is unused.
    var tint: Color = Theme.turf
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Typography helpers

extension Text {
    /// The one big number on a screen.
    func heroNumeral() -> some View {
        modifier(HeroNumeral())
    }

    /// A supporting number.
    func statNumeral() -> some View {
        font(.system(.title2, design: .rounded).weight(.bold))
            .monospacedDigit()
    }

    /// The label beside or under a number.
    func captionLabel() -> some View {
        font(.subheadline)
            .foregroundStyle(Theme.secondaryLabel)
    }
}

/// Larger than any text style, so it scales by `ScaledMetric` and shrinks before it wraps.
private struct HeroNumeral: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .font(.system(size: min(size, 96), weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - View modifiers

extension View {
    /// Constrain content to a comfortable reading measure and center it in the wider canvas — the
    /// Apple Fitness / Strava iPad discipline of a readable column rather than a stretched phone
    /// layout. Applies ONLY at the regular horizontal size class (iPad, wide split views); a no-op
    /// at compact width, where content already fills the screen. Attach a full-width background
    /// AFTER this modifier if the surface behind should still span edge-to-edge.
    func readableWidth(_ maxWidth: CGFloat = Theme.readableContentWidth) -> some View {
        modifier(ReadableContentWidth(maxWidth: maxWidth))
    }

    /// Readable-width treatment for a `Form` / `List`, which — unlike a VStack — ignore a `maxWidth`
    /// frame and always fill their container. Instead we inset the form with symmetric horizontal
    /// padding derived from the live container width, so its rows center in a `maxWidth` column at
    /// regular width. A no-op at compact width. Attach any full-width background AFTER this modifier.
    func readableFormWidth(_ maxWidth: CGFloat = Theme.readableContentWidth) -> some View {
        modifier(ReadableFormWidth(maxWidth: maxWidth))
    }

    /// A flat card. No stroke and no shadow; the background contrast is the edge.
    func themedCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(ThemedCard(cornerRadius: cornerRadius))
    }

    /// Legacy: a plain surface. The tint is unused.
    func metricTile(tint: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(MetricTile(tint: tint, cornerRadius: cornerRadius))
    }

    /// A screen's main action, pinned below scrolling content. The system's scroll edge on iOS 26,
    /// a bar before that.
    @ViewBuilder
    func bottomActionBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        let bar = content()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .readableWidth(560)
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { bar }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar.background(.bar) }
        }
    }

}

/// Caps content to a readable measure and centers it, but only at the regular horizontal size
/// class. The outer `.frame(maxWidth: .infinity)` re-expands the layout so the capped content
/// centers in the wider canvas rather than hugging the leading edge. See `View.readableWidth(_:)`.
struct ReadableContentWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

/// Insets a `Form` / `List` with symmetric horizontal padding so its rows center in a `maxWidth`
/// column at regular width — a padding-based alternative to a `maxWidth` frame, which List ignores.
/// The `.frame(maxWidth: .infinity)` keeps the padded form spanning the full container so the
/// background reader measures the true available width (not the already-inset content). See
/// `View.readableFormWidth(_:)`.
struct ReadableFormWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var maxWidth: CGFloat
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        let inset = horizontalSizeClass == .regular ? max(0, (containerWidth - maxWidth) / 2) : 0
        content
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in containerWidth = newValue }
                }
            )
    }
}

struct ThemedCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct MetricTile: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Buttons

/// The one filled action on a screen: full width, 50 points or taller, legible on either green.
struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? Theme.onTurf : Theme.secondaryLabel)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(isEnabled ? Theme.turf : Color(.tertiarySystemFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryActionStyle {
    static var primaryAction: PrimaryActionStyle { PrimaryActionStyle() }
}
