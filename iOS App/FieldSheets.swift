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
                        .foregroundStyle(Theme.turf.opacity(0.15))
                        .stroke(Theme.turf, lineWidth: 2)
                    ForEach(corners.indices, id: \.self) { index in
                        Annotation("", coordinate: corners[index].clCoordinate) {
                            cornerHandle(index: index, proxy: proxy)
                        }
                    }
                }
            }
            .mapStyle(.imagery)
        }
        .overlay(alignment: .bottom) { guidanceBar }
        .navigationTitle("Adjust Corners")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if corners.isEmpty { corners = field.rectangle.corners }
        }
    }

    /// A dark guidance bar over the imagery: what to do, plus a turf Save capsule. Dragging a
    /// handle nudges low-confidence geometry into a trained observation.
    private var guidanceBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.turf)
                Text(draggingIndex == nil
                     ? "Drag any of the four corners to match the pitch."
                     : "Corner \((draggingIndex ?? 0) + 1) of 4")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            Button { save() } label: {
                Text("Save Corrections")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.turf)
            .clipShape(Capsule())
            .disabled(corners.count != 4)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func cornerHandle(index: Int, proxy: MapProxy) -> some View {
        let isDragging = draggingIndex == index
        return Circle()
            .fill(isDragging ? Theme.signal : Theme.turf)
            .frame(width: isDragging ? 34 : 30, height: isDragging ? 34 : 30)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            // Enlarge the touch target well beyond the visible dot.
            .padding(12)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if draggingIndex != index {
                            draggingIndex = index
                            Haptics.selection()
                        }
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
