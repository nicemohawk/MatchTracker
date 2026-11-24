import Foundation
import MatchTrackerKit

extension WidgetSnapshot {
    /// The gallery's example.
    static var sample: WidgetSnapshot {
        let calendar = Calendar.current
        func day(_ daysAgo: Int, _ us: Int, _ them: Int, opponent: String?) -> MatchDigest {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            var digest = MatchDigest(id: UUID(), startDate: start, endDate: start.addingTimeInterval(72 * 60),
                                     format: .match)
            digest.goalsUs = us
            digest.goalsThem = them
            digest.opponent = opponent
            digest.distanceMeters = 7400
            digest.topSpeedMetersPerSecond = 7.4
            digest.myGoals = us > 2 ? 1 : 0
            return digest
        }
        let columns = PortraitHeat.thumbnailColumns, rows = PortraitHeat.thumbnailRows
        var latest = day(1, 3, 1, opponent: "Rovers")
        latest.heat = (0..<(columns * rows)).map { index -> Float in
            let x = Double(index % columns) / Double(columns) - 0.36
            let y = Double(index / columns) / Double(rows) - 0.42
            return Float(min(1, exp(-(x * x * 22 + y * y * 14)) + 0.4 * exp(-(pow(x - 0.25, 2) * 30 + pow(y - 0.25, 2) * 30))))
        }
        return make(from: [latest, day(8, 2, 2, opponent: nil), day(15, 1, 0, opponent: nil),
                           day(22, 0, 2, opponent: nil), day(29, 4, 1, opponent: nil)])
    }
}
