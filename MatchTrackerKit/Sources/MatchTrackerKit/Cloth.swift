#if canImport(SwiftUI)
import SwiftUI

/// A shirt number: tall, narrow and cut through once. For the few numbers a screen is about; below
/// 44 points the cut would only be noise.
public struct KitNumber: View {
    let text: String
    let size: CGFloat

    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    public init(_ text: String, size: CGFloat = 64) {
        self.text = text
        self.size = size
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0

    private var rendered: CGFloat { min(size * scale, size * 1.6) }

    public var body: some View {
        letters(isDigits: true)
            // The two halves slide home when the number arrives or changes.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: arrivals) { number, slip in
                if rendered < 44 {
                    number
                } else {
                    number.mask { Half(isUpper: true) }.offset(x: -slip)
                        .overlay { number.mask { Half(isUpper: false) }.offset(x: slip).accessibilityHidden(true) }
                }
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(rendered * 0.14)
                    SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                }
            }
            .overlay { letters(isDigits: false).accessibilityHidden(true) }
            .onAppear { if !reduceMotion { arrivals += 1 } }
            .onChange(of: text) { if !reduceMotion { arrivals += 1 } }
    }

    /// The numerals, or everything between them, with the other left clear so both lay out alike.
    /// A cut dash would read as an equals sign.
    private func letters(isDigits: Bool) -> some View {
        text.reduce(Text(verbatim: "")) { line, character in
            let letter = Text(verbatim: String(character))
            return line + (character.isNumber == isDigits ? letter : letter.foregroundStyle(.clear))
        }
        .font(Self.font(size: rendered))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }

    /// Heavy and as narrow as the system's type goes, unless told otherwise.
    public static func font(size: CGFloat, width: Font.Width = .compressed) -> Font {
        #if os(watchOS)
        // The watch's own face comes in one width. The text styles' does not.
        let traits: [UIFontDescriptor.TraitKey: CGFloat] = [.weight: UIFont.Weight.heavy.rawValue, .width: width.value]
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title2).addingAttributes([.traits: traits])
        return Font(UIFont(descriptor: descriptor, size: size) as CTFont)
        #else
        return .system(size: size, weight: .heavy).width(width)
        #endif
    }

    /// One side of the cut. It falls three fifths down a numeral, where the fewest of them have a
    /// stroke end, so it leaves no slivers, and low enough not to read as a strikethrough.
    private struct Half: Shape {
        let isUpper: Bool

        func path(in rect: CGRect) -> Path {
            let cut = rect.minY + rect.height * 0.555, gap = max(rect.height * 0.029, 1.5)
            return Path(isUpper
                ? CGRect(x: rect.minX - 8, y: rect.minY - 8, width: rect.width + 16, height: cut - rect.minY + 8)
                : CGRect(x: rect.minX - 8, y: cut + gap, width: rect.width + 16, height: rect.maxY - cut - gap + 8))
        }
    }
}

/// The one piece of kit on a screen: bottle green, a pinstripe, and a hem.
public struct Cloth: View {
    public static let green = Color(cgColor: Knit.cloth)
    /// What's written on cloth.
    public static let ivory = Color(cgColor: Knit.yarns[3])
    /// A best, always beside a word that says so.
    public static let copper = Color(red: 0.914, green: 0.627, blue: 0.400)

    let cornerRadius: CGFloat
    let hasPinstripe: Bool
    let hasHem: Bool
    let isBest: Bool

    /// - Parameter isBest: A copper hem, when there's something to be proud of.
    public init(cornerRadius: CGFloat = 22, hasPinstripe: Bool = true, hasHem: Bool = true, isBest: Bool = false) {
        self.cornerRadius = cornerRadius
        self.hasPinstripe = hasPinstripe
        self.hasHem = hasHem
        self.isBest = isBest
    }

    @Environment(\.colorSchemeContrast) private var contrast

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.green))
            if hasPinstripe, contrast == .standard {
                var stripes = Path()
                for x in stride(from: CGFloat(9), to: size.width, by: 18) {
                    stripes.move(to: CGPoint(x: x, y: 0))
                    stripes.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(stripes, with: .color(Self.ivory.opacity(0.08)), lineWidth: 1)
            }
            guard hasHem else { return }
            context.fill(Path(CGRect(x: 0, y: size.height - 11, width: size.width, height: 4)), with: .color(Self.ivory))
            context.fill(Path(CGRect(x: 0, y: size.height - 4, width: size.width, height: 4)),
                         with: .color(isBest ? Self.copper : Self.ivory.opacity(0.35)))
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
#endif
