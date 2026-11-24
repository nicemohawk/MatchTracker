import XCTest
@testable import MatchTrackerKit

final class HeatmapComparisonTests: XCTestCase {

    func testDimensionMismatchReturnsNil() {
        let a = HeatmapGrid(columns: 2, rows: 2, cells: [0, 0, 0, 0])
        let b = HeatmapGrid(columns: 3, rows: 2, cells: [0, 0, 0, 0, 0, 0])
        XCTAssertNil(a.difference(from: b))

        let c = HeatmapGrid(columns: 2, rows: 3, cells: [0, 0, 0, 0, 0, 0])
        XCTAssertNil(a.difference(from: c))
    }

    func testMatchingDimensionsReturnsDifference() {
        let a = HeatmapGrid(columns: 2, rows: 2, cells: [1.0, 0.5, 0.0, 0.25])
        let b = HeatmapGrid(columns: 2, rows: 2, cells: [0.5, 0.5, 0.5, 0.0])
        let diff = a.difference(from: b)
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.columns, 2)
        XCTAssertEqual(diff?.rows, 2)
    }

    func testKnownCellMath() {
        // self − other, row-major.
        let a = HeatmapGrid(columns: 2, rows: 2, cells: [1.0, 0.5, 0.0, 0.25])
        let b = HeatmapGrid(columns: 2, rows: 2, cells: [0.5, 0.5, 0.5, 0.0])
        let diff = a.difference(from: b)!
        XCTAssertEqual(diff[0, 0], 0.5, accuracy: 1e-9)   // 1.0 - 0.5
        XCTAssertEqual(diff[1, 0], 0.0, accuracy: 1e-9)   // 0.5 - 0.5
        XCTAssertEqual(diff[0, 1], -0.5, accuracy: 1e-9)  // 0.0 - 0.5
        XCTAssertEqual(diff[1, 1], 0.25, accuracy: 1e-9)  // 0.25 - 0.0
        XCTAssertEqual(diff.cells, [0.5, 0.0, -0.5, 0.25])
    }

    func testSymmetricRange() {
        // Difference is NOT re-peak-normalized: values stay in the raw -1...1 band and are
        // symmetric — swapping the operands negates every cell.
        let a = HeatmapGrid(columns: 2, rows: 1, cells: [1.0, 0.2])
        let b = HeatmapGrid(columns: 2, rows: 1, cells: [0.3, 0.9])
        let forward = a.difference(from: b)!
        let backward = b.difference(from: a)!
        for index in forward.cells.indices {
            XCTAssertEqual(forward.cells[index], -backward.cells[index], accuracy: 1e-9)
            XCTAssertLessThanOrEqual(abs(forward.cells[index]), 1.0)
        }
        XCTAssertEqual(forward.maximumMagnitude, backward.maximumMagnitude, accuracy: 1e-9)
    }

    func testMaximumMagnitudeIsLargestAbsoluteCell() {
        let a = HeatmapGrid(columns: 3, rows: 1, cells: [1.0, 0.0, 0.1])
        let b = HeatmapGrid(columns: 3, rows: 1, cells: [0.2, 0.7, 0.1])
        let diff = a.difference(from: b)!
        // cells = [0.8, -0.7, 0.0] → max magnitude 0.8
        XCTAssertEqual(diff.maximumMagnitude, 0.8, accuracy: 1e-9)
    }

    func testMaximumMagnitudeHasEpsilonFloor() {
        // Identical grids → all-zero difference, but maximumMagnitude never hits zero so
        // opacity scaling (value / maximumMagnitude) stays finite.
        let a = HeatmapGrid(columns: 2, rows: 2, cells: [0.4, 0.4, 0.4, 0.4])
        let diff = a.difference(from: a)!
        XCTAssertTrue(diff.cells.allSatisfy { $0 == 0 })
        XCTAssertGreaterThanOrEqual(diff.maximumMagnitude, HeatmapDifference.magnitudeEpsilon)
    }

    func testSubscriptOutOfBoundsReturnsZero() {
        let a = HeatmapGrid(columns: 2, rows: 2, cells: [0.1, 0.2, 0.3, 0.4])
        let b = HeatmapGrid(columns: 2, rows: 2, cells: [0, 0, 0, 0])
        let diff = a.difference(from: b)!
        XCTAssertEqual(diff[5, 5], 0)
        XCTAssertEqual(diff[-1, 0], 0)
    }
}
