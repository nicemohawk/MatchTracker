import CoreGraphics
import Foundation
import os

/// The colors the app is dressed in. A kit is two colors somebody chose; every shade drawn is made
/// from them at a fixed lightness, so any team's colors are as readable as any other's.
public struct KitColors: Hashable, Sendable {
    /// What's stored and sent: a preset's name, or "#RRGGBB".
    public let id: String

    /// The shirt, and the knit's two quietest yarns.
    public let cloth, ground: RGB
    /// Where somebody played, least to most. The last is always ivory.
    public let yarns: [RGB]
    /// You and your team, on dark and on light.
    public let tintOnDark, tintOnLight: RGB
    public let canvasDark, surfaceDark, elevatedDark: RGB
    public let themOnDark, themOnLight: RGB
    /// A best.
    public let trimOnDark, trimOnLight: RGB

    public struct RGB: Hashable, Sendable {
        public let red, green, blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

        /// WCAG relative luminance.
        public var luminance: Double {
            let linear = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }

        public func contrast(with other: RGB) -> Double {
            let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
            return (high + 0.05) / (low + 0.05)
        }

        public var hex: String {
            "#" + [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        }

        public init?(hex: String) {
            guard hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            self.init(Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
    }

    public static let ivory = RGB(0.961, 0.933, 0.867)

    // MARK: Presets

    public struct Preset: Identifiable, Sendable {
        public let id: String
        public let title: String
        let cloth, yarn: OKLCH
    }

    public static let presets: [Preset] = [
        Preset(id: "green", title: "Bottle Green", cloth: OKLCH(0.318, 0.054, 166), yarn: OKLCH(0.79, 0.13, 155)),
        Preset(id: "royal", title: "Royal Blue", cloth: OKLCH(0.36, 0.145, 264), yarn: OKLCH(0.79, 0.11, 255)),
        Preset(id: "navy", title: "Navy", cloth: OKLCH(0.27, 0.075, 262), yarn: OKLCH(0.79, 0.09, 235)),
        Preset(id: "sky", title: "Sky Blue", cloth: OKLCH(0.43, 0.085, 235), yarn: OKLCH(0.83, 0.10, 228)),
        Preset(id: "purple", title: "Purple", cloth: OKLCH(0.34, 0.135, 300), yarn: OKLCH(0.79, 0.12, 303)),
        Preset(id: "claret", title: "Claret", cloth: OKLCH(0.31, 0.105, 12), yarn: OKLCH(0.80, 0.10, 235)),
        Preset(id: "red", title: "Red", cloth: OKLCH(0.42, 0.165, 27), yarn: OKLCH(0.79, 0.13, 25)),
        Preset(id: "orange", title: "Orange", cloth: OKLCH(0.45, 0.125, 45), yarn: OKLCH(0.80, 0.14, 60)),
        Preset(id: "gold", title: "Black and Gold", cloth: OKLCH(0.235, 0.015, 90), yarn: OKLCH(0.84, 0.15, 90)),
        Preset(id: "black", title: "Black", cloth: OKLCH(0.245, 0.004, 260), yarn: OKLCH(0.82, 0.008, 260))
    ]

    public static let standard = KitColors(id: "green")!

    /// - Parameter id: A preset's name, or a color as "#RRGGBB". Nil for anything else.
    public init?(id: String) {
        if let preset = Self.presets.first(where: { $0.id == id }) {
            self.init(id: id, cloth: preset.cloth, yarn: preset.yarn)
        } else if let chosen = RGB(hex: id) {
            let color = OKLCH(chosen)
            // Yellows and whites make mud or glare as a shirt, so they're worn as the trim on black.
            let isPale = color.lightness > 0.75 && (color.chroma < 0.04 || (70...125).contains(color.hue))
            let cloth = isPale ? OKLCH(0.24, min(color.chroma, 0.012), color.hue)
                               : OKLCH(min(max(color.lightness * 0.75, 0.25), 0.42), min(color.chroma, 0.17), color.hue)
            self.init(id: id, cloth: cloth, yarn: OKLCH(0.81, min(color.chroma, 0.14), color.hue))
        } else {
            return nil
        }
    }

    private init(id: String, cloth: OKLCH, yarn: OKLCH) {
        self.id = id
        self.cloth = cloth.rgb
        ground = cloth.moved(to: cloth.lightness + 0.04).rgb
        yarns = [OKLCH(cloth.lightness + 0.10, cloth.chroma * 1.15, cloth.hue).rgb,
                 OKLCH(max(cloth.lightness + 0.2, 0.535), max(yarn.chroma * 0.8, cloth.chroma * 0.8), yarn.hue).rgb,
                 OKLCH(0.755, yarn.chroma * 0.95, yarn.hue).rgb,
                 Self.ivory]
        tintOnDark = yarn.moved(to: max(yarn.lightness, 0.78)).rgb
        tintOnLight = OKLCH(0.43, max(yarn.chroma, cloth.chroma), yarn.chroma < 0.02 ? cloth.hue : yarn.hue).rgb
        let wash = min(cloth.chroma, 0.06)
        canvasDark = OKLCH(0.172, wash * 0.28, cloth.hue).rgb
        surfaceDark = OKLCH(0.232, wash * 0.40, cloth.hue).rgb
        elevatedDark = OKLCH(0.276, wash * 0.42, cloth.hue).rgb
        // Red is the opponent's, unless it's yours.
        let isRed = yarn.chroma > 0.06 && OKLCH.distance(yarn.hue, 27) < 42
        themOnDark = isRed ? RGB(0.620, 0.757, 0.922) : RGB(1.0, 0.478, 0.400)
        themOnLight = isRed ? RGB(0.137, 0.337, 0.561) : RGB(0.690, 0.165, 0.110)
        // And copper is a best, unless the kit already is.
        let isCopper = yarn.chroma > 0.06 && OKLCH.distance(yarn.hue, 62) < 34
        trimOnDark = isCopper ? RGB(0.620, 0.847, 0.929) : RGB(0.914, 0.627, 0.400)
        trimOnLight = isCopper ? RGB(0.086, 0.365, 0.451) : RGB(0.561, 0.278, 0.094)
    }

    // MARK: Worn

    private static let key = "kitColors"
    private static let worn = OSAllocatedUnfairLock(initialState: stored)

    private static var stored: KitColors {
        defaults.string(forKey: key).flatMap(KitColors.init) ?? .standard
    }

    private static var defaults: UserDefaults { UserDefaults(suiteName: AppGroup.identifier) ?? .standard }

    /// What's being worn, in this process and the others in the app's group. Read from anywhere.
    public static var current: KitColors { worn.withLock { $0 } }

    /// Whether anybody chose, rather than being handed the standard kit.
    public static var isChosen: Bool { defaults.string(forKey: key) != nil }

    public static func wear(_ kit: KitColors) {
        defaults.set(kit.id, forKey: key)
        worn.withLock { $0 = kit }
    }

    /// For a process that may have outlived the last choice, as widgets' do.
    public static func refresh() {
        let kit = stored
        worn.withLock { $0 = kit }
    }
}

/// Lightness, chroma and hue as they're seen, so a lightness is as bright in one hue as in another.
struct OKLCH: Hashable, Sendable {
    let lightness, chroma, hue: Double

    init(_ lightness: Double, _ chroma: Double, _ hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    func moved(to lightness: Double) -> OKLCH { OKLCH(lightness, chroma, hue) }

    static func distance(_ hue: Double, _ other: Double) -> Double {
        let difference = abs(hue - other).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    init(_ color: KitColors.RGB) {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear(color.red), linear(color.green), linear(color.blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let degrees = atan2(bb, a) * 180 / .pi
        self.init(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, hypot(a, bb), degrees < 0 ? degrees + 360 : degrees)
    }

    /// The nearest color a screen can show, giving up strength before lightness or hue.
    var rgb: KitColors.RGB {
        var chroma = chroma
        for _ in 0..<40 {
            let values = Self.linearRGB(lightness, chroma, hue)
            if values.allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) { break }
            chroma *= 0.95
        }
        let values = Self.linearRGB(lightness, chroma, hue).map { value -> Double in
            let clamped = min(max(value, 0), 1)
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return KitColors.RGB(values[0], values[1], values[2])
    }

    private static func linearRGB(_ lightness: Double, _ chroma: Double, _ hue: Double) -> [Double] {
        let a = chroma * cos(hue * .pi / 180), b = chroma * sin(hue * .pi / 180)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    }
}
