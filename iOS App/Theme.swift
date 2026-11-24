// Theme.swift
// MatchTracker
//
// The app's visual identity, kept small on purpose: bottle-green cloth, ivory, and the system's own type
// at its widest for names and its narrowest for numbers. What's marked
// "Legacy" predates DESIGN.md and survives only for the sideline camera.

import SwiftUI
import MatchTrackerKit

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
    static let background = dynamic(dark: (0.039, 0.071, 0.055), light: (0.953, 0.933, 0.882))
    /// A card or form row on `background`.
    static let surface = dynamic(dark: (0.075, 0.125, 0.102), light: (1.0, 0.988, 0.961))
    /// One step above `surface`.
    static let surfaceElevated = dynamic(dark: (0.110, 0.169, 0.141), light: (0.965, 0.949, 0.906))
    /// Hairlines and empty tracks. Visible in both schemes, unlike white at 8%.
    static let surfaceStroke = Color(.separator)
    /// Labels that support a value. A concrete color rather than the hierarchical `.secondary`,
    /// so an outer tint can't turn it into a faint wash of itself.
    static let secondaryLabel = dynamic(dark: (0.663, 0.710, 0.655), light: (0.333, 0.376, 0.310))
    /// Bottle green, the same cloth by day and by night. One piece of it per screen.
    static let cloth = Cloth.green
    /// What's written on cloth.
    static let ivory = Cloth.ivory
    /// Copper: a best, or the match being looked at. Always beside a word that says so.
    static let trim = dynamic(dark: (0.914, 0.627, 0.400), light: (0.561, 0.278, 0.094))
    /// Copper on cloth, whatever the scheme.
    static let trimOnCloth = Cloth.copper
    static let draw = dynamic(dark: (0.784, 0.745, 0.647), light: (0.392, 0.361, 0.290))
    /// Text on a filled `turf` button: black on the bright dark-mode green, white on the deep one.
    static let onTurf = dynamic(dark: (0.039, 0.071, 0.055), light: (0.961, 0.933, 0.867))

    /// You and your team, and the app's tint. The light value holds 4.5:1 as text on white.
    static let turf = dynamic(dark: (0.435, 0.827, 0.604),
                              light: (0.039, 0.400, 0.259))
    /// Legacy: teal. DESIGN.md gives color three jobs and this isn't one of them.
    static let signal = dynamic(dark: (0.400, 0.831, 0.812),
                                light: (0.0, 0.478, 0.463))
    /// Rose (#FF375F) — heart rate.
    static let heart = dynamic(dark: (1.0, 0.416, 0.573),
                               light: (0.722, 0.094, 0.322))
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
    static let bench = draw
    /// Red (#FF453A) — a loss, distinct from `heart`'s rose so score chips don't collide.
    static let loss = dynamic(dark: (1.0, 0.478, 0.400),
                              light: (0.690, 0.165, 0.110))
    /// Card yellow (#FFD60A) — reserved for yellow cards, where amber must read as a caution.
    static let cardYellow = dynamic(dark: (1.0, 0.839, 0.039),
                                    light: (0.694, 0.541, 0.0))

    // MARK: - Pitch canvas colors

    /// Deep green-black turf top color (for a vertical gradient with `pitchTurfBottom`).
    static let pitchTurfTop = cloth
    static let pitchTurfBottom = Color(red: 0.031, green: 0.180, blue: 0.133)
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

// MARK: - Typography helpers

extension Font {
    /// Names and titles: wide, like the back of a shirt.
    static func name(_ style: Font.TextStyle) -> Font { .system(style, weight: .heavy).width(.expanded) }
    /// Numbers in rows and columns: narrow, so they line up and leave room.
    static func figure(_ style: Font.TextStyle) -> Font { .system(style, weight: .semibold).width(.condensed) }
}

// MARK: - Cloth

/// Where something will be: a piece of cloth just begun, with the last row unfinished.
struct ClothSwatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.cloth))
            let columns = 14, width = size.width / CGFloat(columns), rise = width * Knit.rise
            let rows = Int((size.height / rise).rounded(.up)), begun = rows - 11
            let paths = Knit.yarns.map { _ in CGMutablePath() }, ground = CGMutablePath()
            for row in 0..<rows {
                for column in 0..<columns where row > begun || (row == begun && column < 9) {
                    // Worked outward from the middle of the hem, as heat would be.
                    let distance = hypot(Double(column) - 6.5, Double(rows - 1 - row) * 1.1)
                    let path = distance < 3 ? paths[3] : distance < 5.5 ? paths[2] : distance < 8 ? paths[1] : paths[0]
                    Knit.addStitch(to: path, column: column, row: row, width: width)
                }
                for column in 0..<columns where row < begun || (row == begun && column >= 9) {
                    Knit.addStitch(to: ground, column: column, row: row, width: width)
                }
            }
            context.fill(Path(ground), with: .color(Color(cgColor: Knit.ground)))
            for (path, yarn) in zip(paths, Knit.yarns) { context.fill(Path(path), with: .color(Color(cgColor: yarn))) }
        }
        .frame(width: 96, height: 132)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

extension View {
    /// The app's own paper behind a scrolling screen. Forms and sheets keep the system's.
    func canvasBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.background.ignoresSafeArea())
    }
}

/// Large titles in the names' type. Only the type: the bar itself stays the system's.
enum BarType {
    @MainActor
    static func apply() {
        let large = UIFont.systemFont(ofSize: 33, weight: .heavy, width: .expanded)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
    }
}

extension Text {
    /// The one big number on a screen.
    func heroNumeral() -> some View {
        modifier(HeroNumeral())
    }

}

/// Larger than any text style, so it scales by `ScaledMetric` and shrinks before it wraps.
private struct HeroNumeral: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .font(.system(size: min(size, 96), weight: .heavy).width(.compressed))
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
                .scrollEdgeEffectStyle(.hard, for: .bottom)
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

/// `.borderedProminent` with a label that can be read on the bright green of dark mode.
struct ProminentActionStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(isEnabled ? Theme.onTurf : Theme.secondaryLabel)
        }
        .buttonStyle(.borderedProminent)
    }
}

extension PrimitiveButtonStyle where Self == ProminentActionStyle {
    static var prominentAction: ProminentActionStyle { ProminentActionStyle() }
}
