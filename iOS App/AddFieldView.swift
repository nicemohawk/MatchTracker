// AddFieldView.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

/// Draw a new field, starting from wherever the Fields map was looking or from a detected outline.
struct AddFieldView: View {
    var initialRegion: MKCoordinateRegion?
    /// A detected outline to correct before saving.
    var detected: OrientedRectangle?
    /// Called with the saved field.
    var onAdded: (FieldModel) -> Void = { _ in }

    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FieldOutlineEditor(title: "Add Field",
                               initialCorners: detected?.coordinateRing ?? [],
                               initialRegion: detected?.mapRegion ?? initialRegion,
                               showsCancel: true) { corners, rectangle in
                // "New Field" is a placeholder the model replaces with the place's name.
                let field = FieldModel(id: UUID(), name: "New Field", createdAt: Date(),
                                       outline: corners.map(Coordinate2D.init), rectangle: rectangle,
                                       source: .trained, observationCount: 0)
                fields.save(field)
                dismiss()
                onAdded(field)
            }
        }
    }
}
