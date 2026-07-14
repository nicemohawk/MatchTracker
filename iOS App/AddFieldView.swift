// AddFieldView.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// Add a field by dropping four corner pins on a satellite map. Tap to place up to four corners;
/// the live polygon previews the fitted rectangle. A floating control column (zoom + locate)
/// matches the Fields map, and the bottom panel follows the app's dark-first design language.
struct AddFieldView: View {
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    @State private var corners: [CLLocationCoordinate2D] = []
    @State private var name = "New Field"
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    /// Owned locally so `MapUserLocationButton` / the locate control have an authorization to work
    /// with; mirrors the Fields map's when-in-use pattern.
    @State private var locationManager = CLLocationManager()

    private var fittedRectangle: OrientedRectangle? {
        guard corners.count == 4 else { return nil }
        return FieldGeometry.fitOrientedRectangle(to: corners.map(Coordinate2D.init))
    }

    private var canSave: Bool {
        fittedRectangle != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapSection
                controls
            }
            .background(Theme.background)
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            // The bar floats over satellite imagery — force light-on-dark chrome so the title
            // stays readable regardless of the system appearance.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.bench)
                }
            }
            .onAppear(perform: requestLocationIfNeeded)
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(Array(corners.enumerated()), id: \.offset) { index, coordinate in
                    Annotation("\(index + 1)", coordinate: coordinate) {
                        Image(systemName: "\(index + 1).circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, Theme.turf)
                            .shadow(radius: 2)
                    }
                }
                if corners.count >= 3 {
                    MapPolygon(coordinates: corners)
                        .foregroundStyle(Theme.turf.opacity(0.2))
                        .stroke(Theme.turf, lineWidth: 2)
                }
                if let fittedRectangle {
                    MapPolygon(coordinates: fittedRectangle.coordinateRing)
                        .foregroundStyle(Theme.turf.opacity(0.15))
                        .stroke(Theme.turf, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .mapStyle(.hybrid(elevation: .flat))
            .mapControls { MapUserLocationButton() }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .onTapGesture { location in
                guard corners.count < 4,
                      let coordinate = proxy.convert(location, from: .local) else { return }
                corners.append(coordinate)
                Haptics.selection()
            }
            .overlay(alignment: .trailing) { controlColumn }
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 12) {
            mapControlButton("plus.magnifyingglass", label: "Zoom in") { zoom(by: 0.5) }
            mapControlButton("minus.magnifyingglass", label: "Zoom out") { zoom(by: 2) }
            mapControlButton("location.fill", label: "Center on my location") {
                withAnimation(.easeInOut(duration: 0.4)) {
                    cameraPosition = .userLocation(fallback: .automatic)
                }
                Haptics.selection()
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 16)
    }

    private func mapControlButton(_ systemImage: String,
                                  label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .modifier(AddFieldControlGlass())
        .accessibilityLabel(label)
    }

    private func zoom(by factor: Double) {
        let region = visibleRegion ?? regionFallback()
        let minSpan = 0.0009
        let maxSpan = 1.2
        let latitudeDelta = min(max(region.span.latitudeDelta * factor, minSpan), maxSpan)
        let longitudeDelta = min(max(region.span.longitudeDelta * factor, minSpan), maxSpan)
        let zoomed = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(zoomed)
        }
        visibleRegion = zoomed
    }

    private func regionFallback() -> MKCoordinateRegion {
        if let first = corners.first {
            return MKCoordinateRegion(center: first,
                                      span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003))
        }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    }

    // MARK: - Controls panel

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            progressHeader

            TextField("Field name", text: $name)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button {
                    if !corners.isEmpty {
                        corners.removeLast()
                        Haptics.selection()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Theme.bench)
                .disabled(corners.isEmpty)

                Button(role: .destructive) {
                    corners.removeAll()
                    Haptics.selection()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Theme.loss)
                .disabled(corners.isEmpty)
            }

            Button(action: save) {
                Text("Save Field")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.turf)
            .clipShape(Capsule())
            .disabled(!canSave)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.surfaceStroke)
                .frame(height: 1)
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < corners.count ? Theme.turf : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                        .animation(.easeInOut(duration: 0.2), value: corners.count)
                }
            }
            Text(instruction)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var instruction: String {
        switch corners.count {
        case 0: return "Tap the map to place the first corner."
        case 4: return "All 4 corners placed. Name it, then save."
        default: return "Corner \(corners.count + 1) of 4 — tap the next field corner."
        }
    }

    // MARK: - Location

    private func requestLocationIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
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

/// Liquid Glass circle on iOS 26; material fallback earlier. Replicated locally to match the
/// Fields map control column without depending on that file's private modifier.
private struct AddFieldControlGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.surfaceStroke, lineWidth: 1))
        }
    }
}
