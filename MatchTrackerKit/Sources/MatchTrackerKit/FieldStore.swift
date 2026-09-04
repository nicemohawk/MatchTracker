import Foundation

/// JSON persistence + matching. Storage dir injected (app group container in apps, temp in tests).
public final class FieldStore {
    private let directory: URL
    private let fileURL: URL
    public private(set) var fields: [FieldModel]

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("fields.json")
        self.fields = []
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fields = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        fields = try decoder.decode([FieldModel].self, from: data)
    }

    public func save(_ field: FieldModel) throws {        // insert or replace by id
        if let index = fields.firstIndex(where: { $0.id == field.id }) {
            fields[index] = field
        } else {
            fields.append(field)
        }
        try persist()
    }

    public func delete(id: UUID) throws {
        fields.removeAll { $0.id == id }
        try persist()
    }

    /// Replace the whole field list with a single persist — for mirroring an authoritative
    /// list (e.g. from the paired phone) without one encode + disk write per field.
    public func replaceAll(_ fields: [FieldModel]) throws {
        self.fields = fields
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fields)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Tolerance (meters) used when scoring how much of a track falls inside a candidate field.
    private static let matchToleranceMeters = 10.0

    /// Which field is this track being played on? Scores candidate fields by the fraction
    /// of samples inside (with 10 m tolerance), tie-breaking by mean distance to center — this
    /// disambiguates side-by-side and rotated/overlapping fields. Returns nil if best < 0.5.
    public func bestMatch(for samples: [Coordinate2D]) -> FieldModel? {
        let usable = samples.filter(isPlausibleCoordinate)
        guard !usable.isEmpty else { return nil }

        var best: (field: FieldModel, score: Double, meanDistance: Double)?
        for field in fields {
            let projector = FieldProjector(rectangle: field.rectangle)
            let insideCount = usable.filter { projector.contains($0, toleranceMeters: Self.matchToleranceMeters) }.count
            let score = Double(insideCount) / Double(usable.count)

            let frame = ENUFrame(reference: field.rectangle.center)
            let meanDistance = mean(usable.map { hypot(Double(frame.project($0).x), Double(frame.project($0).y)) })

            if let current = best {
                let scoreDelta = score - current.score
                let better = scoreDelta > 1e-9 || (abs(scoreDelta) <= 1e-9 && meanDistance < current.meanDistance)
                if better { best = (field, score, meanDistance) }
            } else {
                best = (field, score, meanDistance)
            }
        }

        guard let result = best, result.score >= 0.5 else { return nil }
        return result.field
    }

    /// Post-match learning hook: match the track against known fields. On a match, refine the
    /// stored rectangle (observation-count-weighted average of center/size/heading) and bump
    /// observationCount. With no match, try inference and return a `.proposed` FieldModel
    /// (source: .inferred) for user confirmation — NOT auto-saved.
    public func recordObservation(track: [TrackPoint]) -> FieldObservationResult {
        let samples = track.map(\.coordinate)

        if let matched = bestMatch(for: samples),
           let index = fields.firstIndex(where: { $0.id == matched.id }) {
            if let observed = FieldGeometry.inferFieldRectangle(from: track) {
                fields[index].rectangle = Self.weightedAverage(
                    existing: fields[index].rectangle,
                    existingWeight: Double(max(fields[index].observationCount, 1)),
                    observed: observed
                )
            }
            fields[index].observationCount += 1
            try? persist()
            return .matched(fields[index])
        }

        guard let rectangle = FieldGeometry.inferFieldRectangle(from: track) else {
            return .none
        }

        let proposed = FieldModel(
            id: UUID(),
            name: "New Field",
            createdAt: Date(),
            outline: [],
            rectangle: rectangle,
            source: .inferred,
            observationCount: 1
        )
        return .proposed(proposed)
    }

    /// Observation-count-weighted blend of the stored rectangle with a freshly observed one.
    /// Center/length/width are linear averages; heading is averaged in the folded 0..<180
    /// domain via a doubled-angle unit-vector mean (so 179° and 1° average near 0°, not 90°).
    private static func weightedAverage(existing: OrientedRectangle, existingWeight: Double, observed: OrientedRectangle) -> OrientedRectangle {
        let totalWeight = existingWeight + 1
        let center = Coordinate2D(
            latitude: (existing.center.latitude * existingWeight + observed.center.latitude) / totalWeight,
            longitude: (existing.center.longitude * existingWeight + observed.center.longitude) / totalWeight
        )
        let length = (existing.lengthMeters * existingWeight + observed.lengthMeters) / totalWeight
        let width = (existing.widthMeters * existingWeight + observed.widthMeters) / totalWeight

        let existingRadians = existing.headingDegrees * 2 * .pi / 180
        let observedRadians = observed.headingDegrees * 2 * .pi / 180
        let sumX = cos(existingRadians) * existingWeight + cos(observedRadians)
        let sumY = sin(existingRadians) * existingWeight + sin(observedRadians)
        let heading = foldHeading(atan2(sumY, sumX) * 180 / .pi / 2)

        return makeOrientedRectangle(center: center, lengthMeters: length, widthMeters: width, headingDegrees: heading)
    }
}

public enum FieldObservationResult: Sendable {
    case matched(FieldModel)   // existing field found; geometry refined in place
    case proposed(FieldModel)  // plausible new field inferred; caller asks user to confirm/save
    case none                  // track unusable for field inference
}
