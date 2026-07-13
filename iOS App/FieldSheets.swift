// FieldSheets.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

/// Detail sheet for a saved field: rename, inspect source/dimensions, delete.
struct FieldDetailSheet: View {
    let field: FieldModel
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Field name", text: $name)
                }
                Section("Details") {
                    LabeledContent("Source") {
                        Label(field.source.label, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(field.source.color)
                    }
                    LabeledContent("Dimensions",
                                   value: "\(Int(field.rectangle.lengthMeters)) × \(Int(field.rectangle.widthMeters)) m")
                    LabeledContent("Heading", value: "\(Int(field.rectangle.headingDegrees))°")
                    LabeledContent("Observations", value: "\(field.observationCount)")
                    LabeledContent("Created", value: field.createdAt.formatted(date: .abbreviated, time: .omitted))
                }
                Section {
                    Button(role: .destructive) {
                        fields.delete(id: field.id)
                        dismiss()
                    } label: {
                        Label("Delete Field", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(field.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var updated = field
                        updated.name = name
                        fields.save(updated)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { name = field.name }
        }
    }
}

/// Confirm and name a satellite-detected field proposal before saving.
struct AcceptProposalSheet: View {
    let rectangle: OrientedRectangle
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Detected Field"

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Field name", text: $name)
                }
                Section("Detected") {
                    LabeledContent("Dimensions",
                                   value: "\(Int(rectangle.lengthMeters)) × \(Int(rectangle.widthMeters)) m")
                    LabeledContent("Source", value: "Satellite imagery")
                }
                Section {
                    MapPreview(rectangle: rectangle, color: FieldSource.satellite.color)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("New Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let field = FieldModel(
                            id: UUID(), name: name, createdAt: Date(), outline: [],
                            rectangle: rectangle, source: .satellite, observationCount: 0
                        )
                        fields.save(field)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Small non-interactive satellite map framing a rectangle outline.
struct MapPreview: View {
    let rectangle: OrientedRectangle
    var color: Color = .blue

    var body: some View {
        Map(initialPosition: .region(rectangle.mapRegion), interactionModes: []) {
            MapPolygon(coordinates: rectangle.coordinateRing)
                .foregroundStyle(color.opacity(0.25))
                .stroke(color, lineWidth: 2)
        }
        .mapStyle(.hybrid)
    }
}
