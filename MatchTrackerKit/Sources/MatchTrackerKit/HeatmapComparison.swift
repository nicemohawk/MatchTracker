// HeatmapComparison.swift
// MatchTrackerKit
//
// Per-cell comparison between two heatmap grids — the "how did this match differ from my
// season average" render. Unlike a heatmap (which is peak-normalized to 1.0), a difference
// keeps a symmetric -1...1 scale so that zero stays meaningful: a cell that matches the
// other grid reads as exactly zero, positive means "more than the other", negative "less".

import Foundation

public extension HeatmapGrid {
    /// Per-cell difference (self − other), for "how did this match differ" renders.
    /// Grids must share dimensions (returns nil otherwise). Cells are the raw normalized
    /// differences in -1...1 (NOT re-peak-normalized — symmetric scale keeps zero meaningful).
    func difference(from other: HeatmapGrid) -> HeatmapDifference? {
        guard columns == other.columns, rows == other.rows,
              cells.count == other.cells.count else { return nil }

        var differences = [Double](repeating: 0, count: cells.count)
        for index in cells.indices {
            differences[index] = cells[index] - other.cells[index]
        }
        return HeatmapDifference(columns: columns, rows: rows, cells: differences)
    }
}

public struct HeatmapDifference: Sendable {
    public var columns: Int
    public var rows: Int
    public var cells: [Double]        // -1...1, row-major
    public var maximumMagnitude: Double  // for legend scaling, >= some epsilon

    /// Floor for `maximumMagnitude` so opacity scaling (value / maximumMagnitude) never divides
    /// by (near) zero when two grids are almost identical.
    public static let magnitudeEpsilon = 0.001

    public init(columns: Int, rows: Int, cells: [Double]) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
        let peak = cells.reduce(0) { Swift.max($0, Swift.abs($1)) }
        self.maximumMagnitude = Swift.max(peak, Self.magnitudeEpsilon)
    }

    public subscript(column: Int, row: Int) -> Double {
        let index = row * columns + column
        guard index >= 0, index < cells.count else { return 0 }
        return cells[index]
    }
}
