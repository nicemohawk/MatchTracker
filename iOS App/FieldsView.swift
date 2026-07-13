// FieldsView.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

struct FieldsView: View {
    @EnvironmentObject private var fields: FieldsModel

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedFieldID: UUID?
    @State private var proposals: [IdentifiedRectangle] = []
    @State private var pendingProposal: IdentifiedRectangle?
    @State private var showingAddField = false
    @State private var isScanning = false

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
            .onAppear { frameFields() }
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
            ForEach(proposals) { proposal in
                MapPolygon(coordinates: proposal.rectangle.coordinateRing)
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
        }
        .padding(.bottom, 8)
    }

    private var proposalBanner: some View {
        VStack(spacing: 6) {
            Text("\(proposals.count) possible field\(proposals.count == 1 ? "" : "s") detected")
                .font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(proposals) { proposal in
                        Button {
                            pendingProposal = proposal
                        } label: {
                            Text("Accept \(Int(proposal.rectangle.lengthMeters))×\(Int(proposal.rectangle.widthMeters)) m")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Dismiss") { proposals = [] }
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
        proposals = detected.prefix(4).map { IdentifiedRectangle(rectangle: $0) }
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
