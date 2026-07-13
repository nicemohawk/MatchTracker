// AddFieldView.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

/// Add a field by dropping (and adjusting) four corner pins on a satellite map.
/// Tap to place up to four corners; the live polygon previews the fitted rectangle.
struct AddFieldView: View {
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    @State private var corners: [CLLocationCoordinate2D] = []
    @State private var name = "New Field"
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    private var fittedRectangle: OrientedRectangle? {
        guard corners.count == 4 else { return nil }
        return FieldGeometry.fitOrientedRectangle(to: corners.map(Coordinate2D.init))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        ForEach(Array(corners.enumerated()), id: \.offset) { index, coordinate in
                            Annotation("\(index + 1)", coordinate: coordinate) {
                                Image(systemName: "\(index + 1).circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white, .blue)
                            }
                        }
                        if corners.count >= 3 {
                            MapPolygon(coordinates: corners)
                                .foregroundStyle(.blue.opacity(0.2))
                                .stroke(.blue, lineWidth: 2)
                        }
                        if let fittedRectangle {
                            MapPolygon(coordinates: fittedRectangle.coordinateRing)
                                .foregroundStyle(.green.opacity(0.15))
                                .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                    }
                    .mapStyle(.hybrid(elevation: .flat))
                    .onTapGesture { location in
                        guard corners.count < 4,
                              let coordinate = proxy.convert(location, from: .local) else { return }
                        corners.append(coordinate)
                    }
                }

                controls
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).disabled(fittedRectangle == nil)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text(instruction).font(.footnote).foregroundStyle(.secondary)
            TextField("Field name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    if !corners.isEmpty { corners.removeLast() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(corners.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    corners.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(corners.isEmpty)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var instruction: String {
        switch corners.count {
        case 0: return "Tap each of the four field corners on the map."
        case 4: return "Adjust with Undo, or Save the fitted rectangle."
        default: return "\(4 - corners.count) more corner\(4 - corners.count == 1 ? "" : "s") to place."
        }
    }

    private func save() {
        guard let rectangle = fittedRectangle else { return }
        let field = FieldModel(
            id: UUID(),
            name: name,
            createdAt: Date(),
            outline: corners.map(Coordinate2D.init),
            rectangle: rectangle,
            source: .trained,
            observationCount: 0
        )
        fields.save(field)
        dismiss()
    }
}
