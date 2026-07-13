// FieldsModel.swift
// MatchTracker

import Foundation
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

    func save(_ field: FieldModel, pushToWatch: Bool = true) {
        try? store.save(field)
        fields = store.fields
        if pushToWatch { onFieldsChanged?() }
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
