// FieldsListSheet.swift
// MatchTracker

import SwiftUI
import CoreLocation
import MatchTrackerKit

/// Identifiable wrapper so a detected rectangle can drive `sheet(item:)`.
struct IdentifiedRectangle: Identifiable {
    let id = UUID()
    let rectangle: OrientedRectangle
}

/// The Fields list, presented as a standard dismissible `.sheet` (detents `[.medium, .large]`) from
/// the map's bottom-leading pill — replacing the old custom drawer. It lists saved fields as
/// AllTrails-style place cards (source badge, confidence, distance from the map center) and, when a
/// scan has surfaced candidates, a "Detected" section to accept or dismiss them. Tapping a row
/// focuses the map and dismisses; the row's detail button opens `FieldDetailSheet`; accepting a
/// proposal opens `AcceptProposalSheet`. Both are presented as nested sheets so the flow is
/// self-contained.
struct FieldsListSheet: View {
    let fields: [FieldModel]
    let proposals: [OrientedRectangle]
    let mapCenter: CLLocationCoordinate2D?
    let onSelectField: (FieldModel) -> Void
    let onDismissProposals: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Re-injected into the nested detail / accept sheets so they always have the model, regardless
    /// of how SwiftUI propagates environment objects across sheet boundaries.
    @EnvironmentObject private var fieldsModel: FieldsModel

    /// Fields with fewer than this many confirming observations render as "unconfirmed" — the dashed
    /// motif shared with the map polygons and the detail sheet.
    private let confirmedThreshold = 3
    /// Below this distance from the map center a field reads as "here" rather than "0 m".
    private let hereThresholdMeters: CLLocationDistance = 30

    @State private var detailField: FieldModel?
    @State private var pendingProposal: IdentifiedRectangle?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !proposals.isEmpty { detectedSection }
                    if fields.isEmpty && proposals.isEmpty {
                        emptyState
                    } else if !fields.isEmpty {
                        fieldSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .readableWidth()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .sheet(item: $detailField) { field in
            FieldDetailSheet(field: field)
                .environmentObject(fieldsModel)
        }
        .sheet(item: $pendingProposal) { proposal in
            AcceptProposalSheet(rectangle: proposal.rectangle)
                .environmentObject(fieldsModel)
        }
    }

    // MARK: - Detected proposals

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeaderBar(title: "Detected", tint: FieldSource.satellite.color)
                Spacer()
                Button {
                    Haptics.selection()
                    onDismissProposals()
                } label: {
                    Text("Dismiss")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss all detected proposals")
            }
            ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                proposalCard(proposal)
            }
        }
    }

    private func proposalCard(_ proposal: OrientedRectangle) -> some View {
        let satellite = FieldSource.satellite.color
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FieldSourceTile(source: .satellite)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Possible pitch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        FieldSourceBadge(source: .satellite)
                        Text("\(Int(proposal.lengthMeters)) × \(Int(proposal.widthMeters)) m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            Button {
                Haptics.selection()
                pendingProposal = IdentifiedRectangle(rectangle: proposal)
            } label: {
                Text("Review & Accept")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.turf)
            .clipShape(Capsule())
        }
        .padding(14)
        .background(Theme.tintWash(satellite, dark: 0.14, light: 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.chipStroke(satellite),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    // MARK: - Fields

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderBar(title: "Fields", tint: Theme.turf)
            ForEach(sortedFields) { field in
                fieldRow(field)
            }
        }
    }

    private func fieldRow(_ field: FieldModel) -> some View {
        let tint = field.source.color
        return HStack(spacing: 12) {
            // Tapping the body focuses the map and dismisses.
            Button {
                Haptics.selection()
                onSelectField(field)
            } label: {
                HStack(spacing: 12) {
                    FieldSourceTile(source: field.source)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(field.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            FieldSourceBadge(source: field.source)
                            FieldConfidenceBadge(observationCount: field.observationCount,
                                                 confirmedThreshold: confirmedThreshold)
                        }
                        Text("\(Int(field.rectangle.lengthMeters)) × \(Int(field.rectangle.widthMeters)) m")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if let distanceText = distanceText(for: field) {
                        Text(distanceText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // A clear, separate detail affordance opens the field's detail sheet.
            Button {
                Haptics.selection()
                detailField = field
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(field.name) details")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
    }

    // MARK: - Empty state (proposals + fields both empty)

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "map")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.turf)
            Text("No fields yet")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Close this and walk a touchline or scan the map to add your first pitch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
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
        let meters = distance(field, from: center)
        if meters < hereThresholdMeters { return "here" }
        return MatchFormat.distance(meters)
    }
}
