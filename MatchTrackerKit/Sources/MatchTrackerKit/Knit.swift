import CoreGraphics

/// Heat as it's worked into cloth: V-shaped stitches, in five yarns from barely there to ivory.
public enum Knit {
    /// How far apart rows sit, as a share of a stitch's width.
    public static let rise: CGFloat = 0.8
    private static let mostColumns = 30
    /// A finer stitch than this shimmers in the sun rather than reading as cloth.
    private static let finest: CGFloat = 9

    public static let cloth = color(0.043, 0.231, 0.173)
    /// The weave itself, where nobody went.
    public static let ground = color(0.055, 0.263, 0.200)
    public static let yarns = [color(0.078, 0.341, 0.251), color(0.180, 0.490, 0.333), color(0.553, 0.733, 0.447), color(0.961, 0.933, 0.867)]

    public static func columns(across pixels: CGFloat) -> Int { min(mostColumns, max(6, Int(pixels / finest))) }

    public static func yarn(for level: Float) -> Int? {
        switch level {
        case ..<0.16: return nil
        case ..<0.38: return 0
        case ..<0.60: return 1
        case ..<0.82: return 2
        default: return 3
        }
    }

    public static func addStitch(to path: CGMutablePath, column: Int, row: Int, width: CGFloat, origin: CGPoint = .zero) {
        let x = origin.x + CGFloat(column) * width, y = origin.y + CGFloat(row) * width * rise
        let height = width * 1.02
        path.addLines(between: [
            CGPoint(x: x + width * 0.06, y: y), CGPoint(x: x + width * 0.36, y: y), CGPoint(x: x + width * 0.5, y: y + height * 0.36),
            CGPoint(x: x + width * 0.64, y: y), CGPoint(x: x + width * 0.94, y: y), CGPoint(x: x + width * 0.94, y: y + height * 0.34),
            CGPoint(x: x + width * 0.5, y: y + height), CGPoint(x: x + width * 0.06, y: y + height * 0.34)
        ])
        path.closeSubpath()
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
