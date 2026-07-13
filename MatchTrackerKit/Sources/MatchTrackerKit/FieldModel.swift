import Foundation

public enum FieldSource: String, Codable, Sendable {
    case trained    // user walked the touchline (or drew on a map)
    case inferred   // derived automatically from match GPS tracks
    case satellite  // detected in Apple Maps satellite imagery on-device
    case community  // received from backend, aggregated across users
}

public struct FieldModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var outline: [Coordinate2D]       // raw trained outline (may be empty for inferred fields)
    public var rectangle: OrientedRectangle  // fitted
    public var source: FieldSource
    public var observationCount: Int         // matches that confirmed/refined this field
    public var sportID: String?              // nil == soccer (SportProfile.id)

    // `sportID` is optional so the synthesized Codable stays decode-compatible with field JSON
    // written before multi-sport support (the key is simply absent in old records).
    public init(id: UUID, name: String, createdAt: Date, outline: [Coordinate2D], rectangle: OrientedRectangle, source: FieldSource, observationCount: Int, sportID: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.outline = outline
        self.rectangle = rectangle
        self.source = source
        self.observationCount = observationCount
        self.sportID = sportID
    }

    // OrientedRectangle is Equatable-but-not-Hashable per the binding API, so hash on id
    // (Identifiable) while Equatable stays synthesized across all stored properties.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
