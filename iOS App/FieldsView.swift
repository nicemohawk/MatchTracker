// FieldsView.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

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

    /// Auto seed passes are throttled to avoid re-tiling on every tab switch (the scanned-region
    /// log already skips tiles scanned within 30 days).
    @AppStorage("lastNearbySeedAt") private var lastAutoSeed: Double = 0
    private let autoSeedInterval: TimeInterval = 30 * 60

    /// Scan proposals and seeder proposals are offered together.
    private var proposals: [OrientedRectangle] { scanProposals + seeder.proposals }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                controls
            }
            .navigationTitle("Fields")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: selectedFieldBinding) { field in
                FieldDetailSheet(field: field)
            }
            .sheet(item: $pendingProposal) { proposal in
                AcceptProposalSheet(rectangle: proposal.rectangle)
            }
            .fullScreenCover(isPresented: $showingAddField) {
                AddFieldView()
            }
            .onAppear {
                frameFields()
                autoSeedIfNeeded()
            }
        }
    }

    private var map: some View {
        Map(position: $cameraPosition, selection: $selectedFieldID) {
            ForEach(fields.fields) { field in
                MapPolygon(coordinates: field.rectangle.coordinateRing)
                    .foregroundStyle(field.source.color.opacity(0.25))
                    .stroke(field.source.color, lineWidth: 2)
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
        .mapStyle(.hybrid(elevation: .flat))
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if !proposals.isEmpty {
                proposalBanner
            }
            HStack {
                Button {
                    showingAddField = true
                } label: {
                    Label("Add Field", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await scan() }
                } label: {
                    Label(isScanning ? "Scanning…" : "Scan for Fields",
                          systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
            }
            .padding(.horizontal)

            Button {
                Task { await seeder.seedAroundCurrentLocation() }
            } label: {
                HStack(spacing: 6) {
                    if seeder.isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Seeding nearby… \(seeder.scannedTiles)/\(seeder.totalTiles)")
                    } else {
                        Label("Seed Nearby Fields", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(seeder.isScanning)
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    private var proposalBanner: some View {
        VStack(spacing: 6) {
            Text("\(proposals.count) possible field\(proposals.count == 1 ? "" : "s") detected")
                .font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                        Button {
                            pendingProposal = IdentifiedRectangle(rectangle: proposal)
                        } label: {
                            Text("Accept \(Int(proposal.lengthMeters))×\(Int(proposal.widthMeters)) m")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Dismiss") { scanProposals = [] }
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func scan() async {
        guard let region = visibleRegion else { return }
        isScanning = true
        defer { isScanning = false }
        let detected = await SatelliteFieldDetector().detectFields(in: region)
        scanProposals = detected.prefix(4).map { $0 }
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

    private var selectedFieldBinding: Binding<FieldModel?> {
        Binding(
            get: { selectedFieldID.flatMap { id in fields.fields.first(where: { $0.id == id }) } },
            set: { newValue in selectedFieldID = newValue?.id }
        )
    }
}

/// Identifiable wrapper so detected rectangles can drive `ForEach` / `sheet(item:)`.
struct IdentifiedRectangle: Identifiable {
    let id = UUID()
    let rectangle: OrientedRectangle
}
