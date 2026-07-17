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
    @State private var cameraPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion?

    /// Opens framed on the region the user was already viewing on the Fields map — they've
    /// usually just centered their pitch there, so re-framing from scratch would be hostile.
    init(initialRegion: MKCoordinateRegion? = nil) {
        if let initialRegion {
            _cameraPosition = State(initialValue: .region(initialRegion))
            _visibleRegion = State(initialValue: initialRegion)
        } else {
            _cameraPosition = State(initialValue: .userLocation(fallback: .automatic))
        }
    }
    /// Bumped continuously while the camera moves so the adjust-phase handle overlay (whose
    /// positions come from `proxy.convert`) re-renders in lockstep with the map.
    @State private var cameraTick = 0
    /// Corner index currently being dragged in the adjust phase (drives the grab affordance).
    @State private var grabbedCorner: Int?
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
            .onAppear {
                requestLocationIfNeeded()
#if DEBUG
                seedCornersIfRequested()
#endif
            }
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                // Numbered pins guide placement; in the adjust phase (4 corners down) the
                // draggable handle overlay replaces them.
                if corners.count < 4 {
                    ForEach(Array(corners.enumerated()), id: \.offset) { index, coordinate in
                        Annotation("\(index + 1)", coordinate: coordinate) {
                            Image(systemName: "\(index + 1).circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, Theme.turf)
                                .shadow(radius: 2)
                        }
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
            // No MapUserLocationButton: the control column below already has a locate button, and
            // the system one renders top-right where it collides with the status bar (user report).
            .mapControls { }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
                cameraTick &+= 1
            }
            .onTapGesture { location in
                guard corners.count < 4,
                      let coordinate = proxy.convert(location, from: .local) else { return }
                corners.append(coordinate)
                Haptics.selection()
            }
            // The handle overlay is a SIBLING above the Map, not an annotation inside it, so a
            // handle's drag gesture never fights the map's pan — touches on a handle stop at the
            // handle; everywhere else falls through to the map.
            .overlay { adjustHandles(proxy: proxy) }
            .overlay(alignment: .trailing) { controlColumn }
            .coordinateSpace(name: Self.mapSpace)
        }
    }

    private static let mapSpace = "addFieldMap"

    /// Adjust phase: once all four corners are down, each becomes a draggable handle so a
    /// misplaced tap can be fixed before saving (user request). Positions derive from the map
    /// camera every frame via `proxy.convert`; `cameraTick` keeps them glued during pans/zooms.
    @ViewBuilder
    private func adjustHandles(proxy: MapProxy) -> some View {
        if corners.count == 4 {
            ZStack {
                // Reading cameraTick makes this overlay re-evaluate while the camera moves.
                let _ = cameraTick
                ForEach(Array(corners.enumerated()), id: \.offset) { index, coordinate in
                    if let point = proxy.convert(coordinate, to: .local) {
                        cornerHandle(index: index)
                            .position(point)
                            .gesture(
                                DragGesture(minimumDistance: 0,
                                            coordinateSpace: .named(Self.mapSpace))
                                    .onChanged { value in
                                        if grabbedCorner != index {
                                            grabbedCorner = index
                                            Haptics.selection()
                                        }
                                        if let moved = proxy.convert(value.location, from: .local) {
                                            corners[index] = moved
                                        }
                                    }
                                    .onEnded { _ in grabbedCorner = nil }
                            )
                    }
                }
            }
            .allowsHitTesting(true)
        }
    }

    private func cornerHandle(index: Int) -> some View {
        ZStack {
            Circle()
                .fill(Theme.turf.opacity(grabbedCorner == index ? 0.45 : 0.28))
            Circle()
                .strokeBorder(Theme.turf, lineWidth: 2)
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 1)
        }
        .frame(width: 34, height: 34)
        .scaleEffect(grabbedCorner == index ? 1.25 : 1)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        // A generous grab target beyond the visible circle — corners are fine-motor targets.
        .contentShape(Circle().inset(by: -12))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: grabbedCorner)
        .accessibilityLabel("Corner \(index + 1) — drag to adjust")
    }

    private var controlColumn: some View {
        VStack(spacing: 12) {
            mapControlButton("location.fill", label: "Center on my location") {
                withAnimation(.easeInOut(duration: 0.4)) {
                    cameraPosition = .userLocation(fallback: .automatic)
                }
                Haptics.selection()
            }
            mapControlButton("plus.magnifyingglass", label: "Zoom in") { zoom(by: 0.5) }
            mapControlButton("minus.magnifyingglass", label: "Zoom out") { zoom(by: 2) }
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
        // ~44 m of latitude at minimum — tight enough to place a corner on the line where the
        // imagery resolves it, matching the Adjust Field editor.
        let minSpan = 0.0004
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
        case 4: return "Drag any corner to fine-tune. Name it, then save."
        default: return "Corner \(corners.count + 1) of 4 — tap the next field corner."
        }
    }

    // MARK: - Location

    private func requestLocationIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

#if DEBUG
    /// UI-test hook: "-AddFieldSeedCorners" places four corners around the visible center so the
    /// adjust phase (draggable handles) can be captured deterministically — synthetic XCUI taps
    /// don't reliably reach the Map's tap gesture. DEBUG builds only.
    private func seedCornersIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-AddFieldSeedCorners"),
              corners.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard corners.isEmpty, let region = visibleRegion else { return }
            let latInset = region.span.latitudeDelta * 0.22
            let lonInset = region.span.longitudeDelta * 0.22
            let center = region.center
            corners = [
                CLLocationCoordinate2D(latitude: center.latitude + latInset, longitude: center.longitude - lonInset),
                CLLocationCoordinate2D(latitude: center.latitude + latInset, longitude: center.longitude + lonInset),
                CLLocationCoordinate2D(latitude: center.latitude - latInset, longitude: center.longitude + lonInset),
                CLLocationCoordinate2D(latitude: center.latitude - latInset, longitude: center.longitude - lonInset),
            ]
        }
    }
#endif

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
// Internal (not private): FieldBoundsEditor's zoom controls share this exact chrome.
struct AddFieldControlGlass: ViewModifier {
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
