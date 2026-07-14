// FieldsView.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// The Fields tab, modeled on AllTrails' award-winning map UI: a full-bleed hybrid map is the
/// hero, a single floating right-edge control column handles zoom + style, and every piece of
/// content and action lives in a persistent snapping bottom drawer (`FieldsDrawer`). All of the
/// original functionality — color-coded polygons, tap-to-detail, Add Field, Scan for Fields,
/// nearby seeding, and satellite proposals — is preserved and reachable from the drawer.
struct FieldsView: View {
    @EnvironmentObject private var fields: FieldsModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(NearbyFieldSeeder.self) private var seeder

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedFieldID: UUID?
    @State private var scanProposals: [OrientedRectangle] = []
    @State private var pendingProposal: IdentifiedRectangle?
    @State private var showingAddField = false
    @State private var isScanning = false
    @State private var useHybridStyle = true
    /// Owned locally so the built-in `MapUserLocationButton` has an authorization to work with;
    /// mirrors the seeder's when-in-use pattern without reaching into it.
    @State private var locationManager = CLLocationManager()

    /// Auto seed passes are throttled to avoid re-tiling on every tab switch (the scanned-region
    /// log already skips tiles scanned within 30 days).
    @AppStorage("lastNearbySeedAt") private var lastAutoSeed: Double = 0
    private let autoSeedInterval: TimeInterval = 30 * 60

    /// Scan proposals and seeder proposals are offered together.
    private var proposals: [OrientedRectangle] { scanProposals + seeder.proposals }

    var body: some View {
        NavigationStack {
            map
                .navigationTitle("Fields")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .sheet(isPresented: .constant(true)) { drawer }
                .onAppear {
                    frameFields()
                    requestLocationIfNeeded()
                    autoSeedIfNeeded()
                }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedFieldID) {
            ForEach(fields.fields) { field in
                MapPolygon(coordinates: field.rectangle.coordinateRing)
                    .foregroundStyle(field.source.color.opacity(0.25))
                    .stroke(field.source.color, style: strokeStyle(for: field))
                Marker(field.name, coordinate: field.rectangle.center.clCoordinate)
                    .tint(field.source.color)
                    .tag(field.id)
            }
            ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                MapPolygon(coordinates: proposal.coordinateRing)
                    .foregroundStyle(FieldSource.satellite.color.opacity(0.2))
                    .stroke(FieldSource.satellite.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .mapStyle(useHybridStyle ? .hybrid(elevation: .flat) : .standard(elevation: .flat))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .overlay(alignment: .trailing) { controlColumn }
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    /// Low-confidence geometry (few observations) reads as a dashed outline; confirmed fields are
    /// drawn solid. Matches the "low-confidence geometry" language in the detail sheet.
    private func strokeStyle(for field: FieldModel) -> StrokeStyle {
        field.observationCount < 3
            ? StrokeStyle(lineWidth: 2, dash: [6, 4])
            : StrokeStyle(lineWidth: 2)
    }

    // MARK: - Right-edge control column

    private var controlColumn: some View {
        VStack(spacing: 12) {
            mapControlButton("plus.magnifyingglass", label: "Zoom in") { zoom(by: 0.5) }
            mapControlButton("minus.magnifyingglass", label: "Zoom out") { zoom(by: 2) }
            mapControlButton(useHybridStyle ? "map" : "globe.americas.fill",
                             label: useHybridStyle ? "Switch to standard map" : "Switch to satellite map") {
                withAnimation(.easeInOut(duration: 0.2)) { useHybridStyle.toggle() }
                Haptics.selection()
            }
        }
        .padding(.trailing, 14)
        // Sit above the drawer's peek so the column never collides with it.
        .padding(.bottom, 132)
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
        .modifier(MapControlGlass())
        .accessibilityLabel(label)
    }

    // MARK: - Drawer

    private var drawer: some View {
        FieldsDrawer(
            fields: fields.fields,
            proposals: proposals,
            isScanning: isScanning,
            mapCenter: visibleRegion?.center,
            selectedFieldID: $selectedFieldID,
            pendingProposal: $pendingProposal,
            showingAddField: $showingAddField,
            onScan: { Task { await scan() } },
            onSeed: { Task { await seeder.seedAroundCurrentLocation() } },
            onSelectField: { field in focus(on: field) },
            onDismissProposals: { scanProposals = [] }
        )
        .environmentObject(fields)
        .environment(seeder)
        .presentationDetents([.height(96), .medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationBackground(Theme.background)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Camera

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

    private func focus(on field: FieldModel) {
        let region = field.rectangle.mapRegion
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraPosition = .region(region)
        }
        visibleRegion = region
        selectedFieldID = field.id
    }

    private func regionFallback() -> MKCoordinateRegion {
        if let first = fields.fields.first { return first.rectangle.mapRegion }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    }

    // MARK: - Actions

    private func scan() async {
        guard let region = visibleRegion else { return }
        isScanning = true
        defer { isScanning = false }
        let detected = await SatelliteFieldDetector().detectFields(in: region)
        scanProposals = detected.prefix(4).map { $0 }
    }

    /// Request when-in-use access the first time the tab appears so the built-in user-location
    /// button has something to work with (the plist usage strings already exist).
    private func requestLocationIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Kick off an automatic seed pass when the tab appears, gated on the opt-in toggle and existing
    /// location access, and throttled so tab switches don't re-tile the area.
    private func autoSeedIfNeeded() {
        guard settings.contributeDetectedFields, seeder.isLocationAuthorized, !seeder.isScanning else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAutoSeed > autoSeedInterval else { return }
        lastAutoSeed = now
        Task { await seeder.seedAroundCurrentLocation() }
    }

    private func frameFields() {
        guard let first = fields.fields.first, visibleRegion == nil else { return }
        cameraPosition = .region(first.rectangle.mapRegion)
    }
}

/// Liquid Glass circle on iOS 26; material fallback earlier. Replicated locally so the map
/// control column matches the settings gear without depending on that file's private modifier.
private struct MapControlGlass: ViewModifier {
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

/// Identifiable wrapper so detected rectangles can drive `ForEach` / `sheet(item:)`.
struct IdentifiedRectangle: Identifiable {
    let id = UUID()
    let rectangle: OrientedRectangle
}
