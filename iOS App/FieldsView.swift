// FieldsView.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// The Fields tab: a full-bleed hybrid map is the hero (color-coded polygons, markers, dashed
/// satellite proposals), overlaid with standard floating controls — a trailing control column
/// (locate, zoom, map style), a bottom-leading list pill that opens a standard `.sheet`
/// (`FieldsListSheet`), and a bottom-trailing action stack (Add Field, Scan). The old custom drawer
/// is gone; nothing covers or crowds the tab bar. Scanning is never silent: it drives a top result
/// banner and, when sharing is on, folds in nearby community seeding around the user.
struct FieldsView: View {
    @EnvironmentObject private var fields: FieldsModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(NearbyFieldSeeder.self) private var seeder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedFieldID: UUID?
    @State private var scanProposals: [OrientedRectangle] = []
    @State private var showingAddField = false
    @State private var showingList = false
    @State private var isScanning = false
    @State private var useHybridStyle = true
    @State private var scanBanner: ScanBanner?
    @State private var bannerToken = UUID()
    @State private var locationProvider = MapLocationProvider()

    /// Auto seed passes are throttled to avoid re-tiling on every tab switch (the scanned-region
    /// log already skips tiles scanned within 30 days).
    @AppStorage("lastNearbySeedAt") private var lastAutoSeed: Double = 0
    /// The empty-state hint is dismissible and stays dismissed.
    @AppStorage("fieldsEmptyHintDismissed") private var emptyHintDismissed = false
    private let autoSeedInterval: TimeInterval = 30 * 60

    /// Scan proposals and seeder proposals are offered together.
    private var proposals: [OrientedRectangle] { scanProposals + seeder.proposals }

    var body: some View {
        NavigationStack {
            ZStack {
                map
            }
            .overlay(alignment: .trailing) { controlColumn }
            .overlay(alignment: .bottomLeading) { listPill }
            .overlay(alignment: .bottomTrailing) { actionStack }
            .overlay(alignment: .bottom) { emptyHint }
            .overlay(alignment: .top) { bannerOverlay }
            // No title: the tab bar already says "Fields" and the map speaks for itself — a
            // floating title over satellite imagery only costs legibility (Apple Maps ships none).
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingList) {
                FieldsListSheet(
                    fields: fields.fields,
                    proposals: proposals,
                    mapCenter: visibleRegion?.center,
                    onSelectField: { field in
                        focus(on: field)
                        showingList = false
                    },
                    onDismissProposals: { scanProposals = [] }
                )
                .environmentObject(fields)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .fullScreenCover(isPresented: $showingAddField) {
                // Hand over the region the user just framed — no jarring re-frame to their
                // location (which on first run can be a continent-level fallback).
                AddFieldView(initialRegion: visibleRegion)
            }
            .onAppear {
                frameFields()
                locationProvider.requestAuthorizationIfNeeded()
                autoSeedIfNeeded()
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedFieldID) {
            UserAnnotation()
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
        // The locate control lives in the trailing column now — keep only the unobtrusive compass
        // and scale.
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .onChange(of: selectedFieldID) { _, newValue in
            // A tap on a map marker focuses that field; keep the camera behavior consistent with
            // selecting from the list.
            guard let id = newValue, let field = fields.field(id: id) else { return }
            focus(on: field)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    /// Low-confidence geometry (few observations) reads as a dashed outline; confirmed fields solid.
    private func strokeStyle(for field: FieldModel) -> StrokeStyle {
        field.observationCount < 3
            ? StrokeStyle(lineWidth: 2, dash: [6, 4])
            : StrokeStyle(lineWidth: 2)
    }

    // MARK: - Trailing control column

    private var controlColumn: some View {
        VStack(spacing: 12) {
            mapControlButton("location.fill", label: "Center on my location") {
                Task { await locate() }
            }
            mapControlButton("plus", label: "Zoom in") { zoom(by: 0.5) }
            mapControlButton("minus", label: "Zoom out") { zoom(by: 2) }
            mapControlButton(useHybridStyle ? "map.fill" : "globe.americas.fill",
                             label: useHybridStyle ? "Switch to standard map" : "Switch to satellite map") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { useHybridStyle.toggle() }
                Haptics.selection()
            }
        }
        .padding(.trailing, 14)
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

    // MARK: - Bottom-leading list pill

    private var listPill: some View {
        Button {
            Haptics.selection()
            showingList = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "map.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.turf)
                // Separate literals so each is a LocalizedStringKey and the inflection markup is
                // parsed (a String-typed ternary would render `^[…]` verbatim).
                if fields.fields.isEmpty {
                    Text("No fields")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                } else {
                    Text("^[\(fields.fields.count) field](inflect: true)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .modifier(MapCapsuleGlass())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .padding(.bottom, FieldsChrome.bottomClearance)
        .accessibilityLabel(fields.fields.isEmpty ? "No fields. Open list."
                            : "\(fields.fields.count) fields. Open list.")
    }

    // MARK: - Bottom-trailing action stack

    private var actionStack: some View {
        VStack(alignment: .trailing, spacing: 10) {
            scanCapsule
            Button {
                Haptics.selection()
                showingAddField = true
            } label: {
                Label("Add Field", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 11)
                    .padding(.horizontal, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.turf)
            .clipShape(Capsule())
        }
        .padding(.trailing, 14)
        .padding(.bottom, FieldsChrome.bottomClearance)
    }

    private var scanCapsule: some View {
        Button {
            Task { await scan() }
        } label: {
            HStack(spacing: 7) {
                if isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FieldSource.satellite.color)
                }
                Text(isScanning ? "Scanning…" : "Scan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .modifier(MapCapsuleGlass())
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
        .accessibilityLabel(isScanning ? "Scanning this area" : "Scan this area for fields")
    }

    // MARK: - Empty-state hint

    private var emptyHint: some View {
        Group {
            if showEmptyHint {
                EmptyFieldsHint {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        emptyHintDismissed = true
                    }
                }
                .padding(.horizontal, 24)
                // Float above the action buttons (two stacked capsules) and the tab bar.
                .padding(.bottom, FieldsChrome.bottomClearance + 108)
            }
        }
    }

    private var showEmptyHint: Bool {
        fields.fields.isEmpty && proposals.isEmpty && !isScanning && !emptyHintDismissed
    }

    // MARK: - Scan result banner

    private var bannerOverlay: some View {
        Group {
            if let banner = scanBanner {
                ScanResultBanner(banner: banner) {
                    if banner.isSuccess { showingList = true }
                    dismissBanner()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Camera

    private func zoom(by factor: Double) {
        let region = visibleRegion ?? regionFallback()
        // Effectively uncapped zoom-in (~4 m of latitude) — MapKit clamps to the imagery's own
        // limit. Field UIs need corner-flag-level closeness.
        let minSpan = 0.00004
        let maxSpan = 1.2
        let latitudeDelta = min(max(region.span.latitudeDelta * factor, minSpan), maxSpan)
        let longitudeDelta = min(max(region.span.longitudeDelta * factor, minSpan), maxSpan)
        let zoomed = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            cameraPosition = .region(zoomed)
        }
        visibleRegion = zoomed
    }

    private func focus(on field: FieldModel) {
        let region = field.rectangle.mapRegion
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            cameraPosition = .region(region)
        }
        visibleRegion = region
        selectedFieldID = field.id
    }

    /// Recenter the camera on the user, requesting when-in-use access if it hasn't been decided yet.
    private func locate() async {
        guard let coordinate = await locationProvider.requestCurrentLocation() else { return }
        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        let region = MKCoordinateRegion(center: coordinate, span: span)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            cameraPosition = .region(region)
        }
        visibleRegion = region
    }

    private func regionFallback() -> MKCoordinateRegion {
        if let first = fields.fields.first { return first.rectangle.mapRegion }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                  span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    }

    // MARK: - Actions

    /// Scan the visible region for pitches. Always ends with visible feedback (a success or failure
    /// banner). When community sharing is on and location is available, fold in a nearby seed pass
    /// around the user so scanning doubles as the "find fields near me" affordance.
    private func scan() async {
        guard let region = visibleRegion else {
            showBanner(.failure)
            return
        }
        isScanning = true
        let detected = await SatelliteFieldDetector().detectFields(in: region)
        scanProposals = Array(detected.prefix(4))
        isScanning = false

        if scanProposals.isEmpty {
            MatchLog.info("scan: nothing shown to user (no proposals)", category: "scan")
            showBanner(.failure)
        } else {
            MatchLog.info("scan: showing \(scanProposals.count) proposal(s) to user", category: "scan")
            showBanner(.success(scanProposals.count))
        }

        // Seeding is folded into scan: no separate "Seed Nearby Fields" button. A nearby pass runs
        // only when the user has opted into community sharing and location is already granted.
        if settings.contributeDetectedFields, seeder.isLocationAuthorized, !seeder.isScanning {
            Task { await seeder.seedAroundCurrentLocation() }
        }
    }

    private func showBanner(_ banner: ScanBanner) {
        let token = UUID()
        bannerToken = token
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) {
            scanBanner = banner
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if bannerToken == token { dismissBanner() }
        }
    }

    private func dismissBanner() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) {
            scanBanner = nil
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
