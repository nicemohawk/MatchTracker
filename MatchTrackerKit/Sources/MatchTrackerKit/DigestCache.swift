import Foundation

// MARK: - Digest cache

/// Every match's digest as it sits on disk, with enough about what each was computed from to tell
/// when it no longer holds.
public struct DigestCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var digest: MatchDigest
        /// The record it was computed from (`MatchRecord.digestStamp`); "" without one.
        public var recordStamp: String
        /// Where the match was played, and the fields saved around there at the time.
        public var center: Coordinate2D?
        public var fieldStamp: String

        public init(digest: MatchDigest, record: MatchRecord?, center: Coordinate2D?, fields: [FieldModel]) {
            self.digest = digest
            self.recordStamp = record?.digestStamp ?? ""
            self.center = center
            self.fieldStamp = DigestCache.fieldStamp(near: center, fields: fields)
        }
    }

    public var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) {
        self.entries = entries
    }

    /// Reading keeps whatever still decodes, so one bad entry doesn't cost the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        entries = container.allKeys.reduce(into: [:]) { result, key in
            guard let id = UUID(uuidString: key.stringValue) else { return }
            result[id] = try? container.decode(Entry.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (id, entry) in entries {
            try container.encode(entry, forKey: Key(stringValue: id.uuidString))
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Whether a match's digest can still be shown as it is.
    public func isCurrent(_ id: UUID, record: MatchRecord?, fields: [FieldModel]) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.digest.version == MatchDigest.currentVersion
            && entry.recordStamp == record?.digestStamp ?? ""
            && entry.fieldStamp == Self.fieldStamp(near: entry.center, fields: fields)
    }

    /// The fields that could claim a match played here.
    static func fieldStamp(near center: Coordinate2D?, fields: [FieldModel]) -> String {
        guard let center else { return "" }
        let nearby = fields
            .filter { haversineMeters($0.rectangle.center, center) < 300 }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { field in
                let rectangle = field.rectangle
                // Rounded: geometry survives a JSON round trip only to the last bit or so.
                return String(format: "%@ %@ %.6f %.6f %.1f %.1f %.1f", field.id.uuidString, field.name,
                              rectangle.center.latitude, rectangle.center.longitude, rectangle.lengthMeters,
                              rectangle.widthMeters, rectangle.headingDegrees)
            }
        return stableHash(Data(nearby.joined(separator: "\n").utf8))
    }
}

public extension MatchRecord {
    /// Changes whenever a digest of this record would.
    var digestStamp: String {
        var stripped = self
        stripped.headings = nil
        stripped.track = nil
        stripped.notes = nil
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = .sortedKeys
        return "\(track?.count ?? 0)-" + stableHash((try? encoder.encode(stripped)) ?? Data())
    }
}

/// FNV-1a. `Hasher` is seeded per launch, so it can't be compared with what's on disk.
private func stableHash(_ data: Data) -> String {
    let hash = data.reduce(into: UInt64(0xcbf2_9ce4_8422_2325)) { hash, byte in
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
