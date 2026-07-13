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

    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fields)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Which field is this track being played on? Scores candidate fields by the fraction
    /// of samples inside (with tolerance), tie-breaking by distance to center.
    public func bestMatch(for samples: [Coordinate2D]) -> FieldModel? {
        // STUB: fraction-inside scoring with a fixed tolerance, no center tie-break yet.
        guard !samples.isEmpty else { return nil }

        var best: (field: FieldModel, score: Double)?
        for field in fields {
            let projector = FieldProjector(rectangle: field.rectangle)
            let insideCount = samples.filter { projector.contains($0, toleranceMeters: 5) }.count
            let score = Double(insideCount) / Double(samples.count)
            if best == nil || score > best!.score {
                best = (field, score)
            }
        }

        guard let result = best, result.score >= 0.5 else { return nil }
        return result.field
    }

    /// Post-match learning hook: match the track against known fields. On a match, refine the
    /// stored rectangle and bump observationCount. With no match, try inference and return a
    /// `.proposed` FieldModel (source: .inferred) for user confirmation — NOT auto-saved.
    public func recordObservation(track: [TrackPoint]) -> FieldObservationResult {
        // STUB: match by fraction-inside; on match bump observationCount (no geometry
        // averaging yet); otherwise propose an inferred field without saving.
        let samples = track.map(\.coordinate)

        if let matched = bestMatch(for: samples) {
            if let index = fields.firstIndex(where: { $0.id == matched.id }) {
                fields[index].observationCount += 1
                try? persist()
                return .matched(fields[index])
            }
            return .matched(matched)
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
}

public enum FieldObservationResult: Sendable {
    case matched(FieldModel)   // existing field found; geometry refined in place
    case proposed(FieldModel)  // plausible new field inferred; caller asks user to confirm/save
    case none                  // track unusable for field inference
}
