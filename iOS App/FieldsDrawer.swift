// FieldsDrawer.swift
// MatchTracker

import SwiftUI
import CoreLocation
import MatchTrackerKit

/// The persistent bottom drawer for the Fields tab. Always presented as a sheet with a snapping
/// peek/medium detent, it holds every action and all content: a summary + nearest-field hint at
/// the peek, an actions row (Scan This Area / Add Field / Seed Nearby), a highlighted "Detected"
/// group for live proposals, and the field list sorted by distance from the map center. The
/// detail, accept-proposal, and add-field flows are presented from here so they nest cleanly
/// above the always-on drawer.
struct FieldsDrawer: View {
    let fields: [FieldModel]
    let proposals: [OrientedRectangle]
    let isScanning: Bool
    let mapCenter: CLLocationCoordinate2D?

    @Binding var selectedFieldID: UUID?
    @Binding var pendingProposal: IdentifiedRectangle?
    @Binding var showingAddField: Bool

    let onScan: () -> Void
    let onSeed: () -> Void
    let onSelectField: (FieldModel) -> Void
    let onDismissProposals: () -> Void

    @EnvironmentObject private var fieldsModel: FieldsModel
    @Environment(NearbyFieldSeeder.self) private var seeder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                actions
                if !proposals.isEmpty { detectedSection }
                fieldList
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 44)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .sheet(item: selectedFieldBinding) { field in
            FieldDetailSheet(field: field)
        }
        .sheet(item: $pendingProposal) { proposal in
            AcceptProposalSheet(rectangle: proposal.rectangle)
        }
        .fullScreenCover(isPresented: $showingAddField) {
            AddFieldView()
        }
    }

    // MARK: - Peek summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("^[\(fields.count) field](inflect: true)")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hint: String {
        guard let nearest = sortedFields.first else {
            return "Scan or seed the map to discover pitches nearby."
        }
        if let center = mapCenter {
            let meters = distance(nearest, from: center)
            return "Nearest: \(nearest.name) · \(MatchFormat.distance(meters))"
        }
        return "Nearest: \(nearest.name)"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onScan) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                        }
                        Text(isScanning ? "Scanning…" : "Scan This Area")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Theme.signal)
                .disabled(isScanning)
                .accessibilityLabel("Scan this area for fields")

                Button { showingAddField = true } label: {
                    Label("Add Field", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.turf)
            }
            seedButton
        }
    }

    private var seedButton: some View {
        Button(action: onSeed) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text(seeder.isScanning
                         ? "Seeding nearby… \(seeder.scannedTiles)/\(seeder.totalTiles)"
                         : "Seed Nearby Fields")
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                if seeder.isScanning {
                    ProgressView(value: Double(seeder.scannedTiles),
                                 total: Double(max(seeder.totalTiles, 1)))
                        .tint(Theme.turf)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(Theme.pace)
        .disabled(seeder.isScanning)
        .accessibilityLabel("Seed nearby fields from satellite imagery")
    }

    // MARK: - Detected proposals

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeaderBar(title: "Detected", tint: FieldSource.satellite.color)
                Spacer()
                Button("Dismiss", action: onDismissProposals)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                proposalRow(proposal)
            }
        }
        .padding(14)
        .background(Theme.tintWash(FieldSource.satellite.color, dark: 0.14, light: 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.chipStroke(FieldSource.satellite.color), lineWidth: 1)
        )
    }

    private func proposalRow(_ proposal: OrientedRectangle) -> some View {
        HStack(spacing: 12) {
            sourceDot(FieldSource.satellite.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Possible pitch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(Int(proposal.lengthMeters)) × \(Int(proposal.widthMeters)) m · Satellite")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Accept") {
                pendingProposal = IdentifiedRectangle(rectangle: proposal)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(FieldSource.satellite.color)
        }
    }

    // MARK: - Field list

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderBar(title: "Fields", tint: Theme.turf)
            if fields.isEmpty {
                Text("No fields yet. Add one, or scan the map to detect pitches from satellite imagery.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ForEach(sortedFields) { field in
                    Button { onSelectField(field) } label: {
                        fieldRow(field)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func fieldRow(_ field: FieldModel) -> some View {
        HStack(spacing: 12) {
            sourceDot(field.source.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(field.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(metadata(for: field))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let distanceText = distanceText(for: field) {
                Text(distanceText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func metadata(for field: FieldModel) -> String {
        var parts = [field.source.label,
                     "\(Int(field.rectangle.lengthMeters)) × \(Int(field.rectangle.widthMeters)) m"]
        if field.observationCount > 0 {
            parts.append("\(field.observationCount) obs")
        }
        return parts.joined(separator: " · ")
    }

    private func sourceDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Distance sorting

    private var sortedFields: [FieldModel] {
        guard let center = mapCenter else { return fields }
        return fields.sorted { distance($0, from: center) < distance($1, from: center) }
    }

    private func distance(_ field: FieldModel, from center: CLLocationCoordinate2D) -> CLLocationDistance {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let point = CLLocation(latitude: field.rectangle.center.latitude,
                               longitude: field.rectangle.center.longitude)
        return point.distance(from: origin)
    }

    private func distanceText(for field: FieldModel) -> String? {
        guard let center = mapCenter else { return nil }
        return MatchFormat.distance(distance(field, from: center))
    }

    private var selectedFieldBinding: Binding<FieldModel?> {
        Binding(
            get: { selectedFieldID.flatMap { fieldsModel.field(id: $0) } },
            set: { selectedFieldID = $0?.id }
        )
    }
}
