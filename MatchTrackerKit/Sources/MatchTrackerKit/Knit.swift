import CoreGraphics

/// Heat as it's worked into cloth: V-shaped stitches, in five yarns from barely there to ivory.
public enum Knit {
    /// How far apart rows sit, as a share of a stitch's width.
    public static let rise: CGFloat = 0.8
    private static let mostColumns = 30
    /// A finer stitch than this shimmers in the sun rather than reading as cloth.
    private static let finest: CGFloat = 9

    public static var cloth: CGColor { KitColors.current.cloth.cgColor }
    /// The weave itself, where nobody went.
    public static var ground: CGColor { KitColors.current.ground.cgColor }
    public static var yarns: [CGColor] { KitColors.current.yarns.map(\.cgColor) }

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
}
