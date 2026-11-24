import XCTest
@testable import MatchTrackerKit

final class KitColorsTests: XCTestCase {
    private let cream = KitColors.RGB(0.953, 0.933, 0.882)

    private var everyKit: [KitColors] {
        let chosen = stride(from: 0.0, to: 360, by: 10).flatMap { hue in
            [(0.3, 0.1), (0.5, 0.2), (0.65, 0.25), (0.85, 0.12), (0.95, 0.03), (0.15, 0.02)].map { OKLCH($0.0, $0.1, hue).rgb.hex }
        }
        return (KitColors.presets.map(\.id) + chosen + ["#000000", "#FFFFFF", "#FFFF00", "#00FF00", "#FF0000", "#0000FF"])
            .compactMap(KitColors.init)
    }

    func testEveryKitIsReadable() {
        for kit in everyKit {
            XCTAssertGreaterThan(KitColors.ivory.contrast(with: kit.cloth), 5.5, "ivory on \(kit.id)'s cloth")
            XCTAssertGreaterThan(kit.tintOnDark.contrast(with: kit.canvasDark), 7, "tint on \(kit.id)'s canvas")
            XCTAssertGreaterThan(kit.tintOnDark.contrast(with: kit.surfaceDark), 6, "tint on \(kit.id)'s surface")
            XCTAssertGreaterThan(kit.tintOnDark.contrast(with: kit.cloth), 3.2, "tint on \(kit.id)'s cloth")
            XCTAssertGreaterThan(kit.tintOnLight.contrast(with: cream), 4.5, "tint of \(kit.id) on cream")
            XCTAssertGreaterThan(kit.themOnDark.contrast(with: kit.canvasDark), 6, "opponent on \(kit.id)'s canvas")
        }
    }

    func testHeatGetsBrighterYarnByYarn() {
        for kit in everyKit {
            let ladder = ([kit.cloth, kit.ground] + kit.yarns).map(\.luminance)
            XCTAssertEqual(ladder, ladder.sorted(), kit.id)
            XCTAssertGreaterThan(kit.yarns[3].contrast(with: kit.yarns[2]), 1.4, kit.id)
        }
    }

    func testARedTeamsOpponentIsNotRed() {
        XCTAssertGreaterThan(KitColors(id: "red")!.themOnDark.blue, KitColors(id: "red")!.themOnDark.red)
        XCTAssertGreaterThan(KitColors(id: "green")!.themOnDark.red, KitColors(id: "green")!.themOnDark.blue)
    }

    func testOnlyPresetsAndColorsAreKits() {
        XCTAssertNil(KitColors(id: "plaid"))
        XCTAssertNil(KitColors(id: "#12345"))
        XCTAssertNil(KitColors(id: "#GGGGGG"))
        XCTAssertNil(KitColors(id: "#+12345"))
        XCTAssertEqual(KitColors(id: "#1A2B3C")?.id, "#1A2B3C")
    }

    func testTheStandardKitIsBottleGreen() {
        let kit = KitColors.standard
        XCTAssertEqual(kit.cloth.red, 0.043, accuracy: 0.03)
        XCTAssertEqual(kit.cloth.green, 0.231, accuracy: 0.03)
        XCTAssertEqual(kit.cloth.blue, 0.173, accuracy: 0.03)
    }
}
