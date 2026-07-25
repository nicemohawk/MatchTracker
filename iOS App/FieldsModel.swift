// FieldsModel.swift
// MatchTracker

import Foundation
import CoreLocation
import MatchTrackerKit

/// Observable wrapper around the Kit `FieldStore`, backed by the app-group directory.
/// Phone is the field database of record; the watch mirrors this list via WatchConnectivity.
@MainActor
final class FieldsModel: ObservableObject {
    let store: FieldStore
    @Published private(set) var fields: [FieldModel] = []

    /// Called after any local change so the connectivity layer can push the updated list to the watch.
    var onFieldsChanged: (() -> Void)?

    init(directory: URL = AppGroup.fieldsDirectory) {
        store = FieldStore(directory: directory)
        reload()
    }

    func reload() {
        try? store.load()
        fields = store.fields
    }

    func field(id: UUID) -> FieldModel? {
        fields.first { $0.id == id }
    }

    /// Placeholder names every save path can produce; a field carrying one gets a real name
    /// resolved from its location (sports facility → park/area → street) asynchronously.
    private static let placeholderNames: Set<String> = ["", "New Field", "Match Field"]

    func save(_ field: FieldModel, pushToWatch: Bool = true) {
        try? store.save(field)
        fields = store.fields
        if pushToWatch { onFieldsChanged?() }
        if Self.placeholderNames.contains(field.name) {
            autoName(fieldID: field.id, center: field.rectangle.center.clCoordinate)
        }
    }

    /// Best-effort rename of a placeholder-named field once a real name resolves. Re-checks the
    /// name before writing so a user rename that landed in the meantime always wins.
    private func autoName(fieldID: UUID, center: CLLocationCoordinate2D) {
        Task { [weak self] in
            guard let resolved = await FieldNamer.suggestedName(for: center),
                  let self,
                  var current = self.field(id: fieldID),
                  Self.placeholderNames.contains(current.name) else { return }
            current.name = resolved
            self.save(current)
        }
    }

    func delete(id: UUID) {
        try? store.delete(id: id)
        fields = store.fields
        onFieldsChanged?()
    }

    /// Encoded field list for the WatchConnectivity application context.
    func encodedFields() -> Data? {
        try? MatchTrackerJSON.encoder().encode(fields)
    }
}
