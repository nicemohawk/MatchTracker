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
                    NavigationLink {
                        CornerEditorView(field: field) { dismiss() }
                    } label: {
                        Label("Adjust Corners", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                } footer: {
                    Text(field.observationCount < 3
                         ? "Low-confidence geometry (\(field.observationCount) observation\(field.observationCount == 1 ? "" : "s")) — nudging corners locks it in as trained."
                         : "Manual corrections count as high-weight trained observations.")
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

/// Drag the four corner pins on satellite imagery to correct a field's geometry. Saving refits
/// the rectangle and records the correction as a high-weight trained observation.
struct CornerEditorView: View {
    let field: FieldModel
    var onSaved: () -> Void
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    @State private var corners: [Coordinate2D] = []
    @State private var draggingIndex: Int?

    var body: some View {
        MapReader { proxy in
            Map(initialPosition: .region(field.rectangle.mapRegion)) {
                if corners.count == 4 {
                    MapPolygon(coordinates: corners.map(\.clCoordinate))
                        .foregroundStyle(Color.yellow.opacity(0.15))
                        .stroke(.yellow, lineWidth: 2)
                    ForEach(corners.indices, id: \.self) { index in
                        Annotation("", coordinate: corners[index].clCoordinate) {
                            cornerHandle(index: index, proxy: proxy)
                        }
                    }
                }
            }
            .mapStyle(.imagery)
        }
        .navigationTitle("Adjust Corners")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(corners.count != 4)
            }
        }
        .onAppear {
            if corners.isEmpty { corners = field.rectangle.corners }
        }
    }

    private func cornerHandle(index: Int, proxy: MapProxy) -> some View {
        Circle()
            .fill(draggingIndex == index ? Color.orange : Color.yellow)
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        draggingIndex = index
                        if let coordinate = proxy.convert(value.location, from: .global) {
                            corners[index] = Coordinate2D(latitude: coordinate.latitude,
                                                          longitude: coordinate.longitude)
                        }
                    }
                    .onEnded { _ in draggingIndex = nil }
            )
    }

    private func save() {
        guard let rectangle = FieldGeometry.fitOrientedRectangle(to: corners) else { return }
        var updated = field
        updated.rectangle = rectangle
        updated.outline = corners
        updated.source = .trained
        updated.observationCount += 1
        fields.save(updated)
        dismiss()
        onSaved()
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
