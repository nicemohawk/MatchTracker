// FieldSheets.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

/// Detail sheet for a saved field: rename, inspect source/dimensions, delete. Reskinned to the
/// app's dark design language — a source-tinted hero echoing the drawer's place card (glyph tile,
/// Walked/GPS/Satellite/Community badge, dashed-vs-solid confidence motif), labeled mini-stats, a
/// themed rename field, and action rows with a `Theme.loss` delete guarded by a confirmationDialog.
struct FieldDetailSheet: View {
    let field: FieldModel
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var showingDeleteConfirmation = false

    /// Matches the drawer's threshold: fewer confirming observations reads as "unconfirmed".
    private let confirmedThreshold = 3

    private var tint: Color { field.source.color }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    statsRow
                    nameCard
                    actionsCard
                    observationHint
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Haptics.selection()
                        var updated = field
                        updated.name = name
                        fields.save(updated)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Delete \(field.name)?",
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete Field", role: .destructive) {
                    Haptics.impact(.medium)
                    fields.delete(id: field.id)
                    dismiss()
                }
            } message: {
                Text("Removes this field from this device and your Apple Watch. Matches already recorded here stay intact.")
            }
            .onAppear { name = field.name }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            FieldSourceTile(source: field.source, size: 60, glyphSize: 25, cornerRadius: 16)
            VStack(spacing: 10) {
                Text(field.name.isEmpty ? "Field" : field.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    FieldSourceBadge(source: field.source)
                    FieldConfidenceBadge(observationCount: field.observationCount,
                                         confirmedThreshold: confirmedThreshold)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Theme.heroWash, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            FieldStatTile(label: "Dimensions",
                          value: "\(Int(field.rectangle.lengthMeters)) × \(Int(field.rectangle.widthMeters)) m",
                          tint: tint)
            FieldStatTile(label: "Observations",
                          value: "\(field.observationCount)",
                          tint: tint)
        }
    }

    // MARK: - Rename

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Field Name").captionLabel().foregroundStyle(tint)
            ThemedFieldTextField(placeholder: "Field name", text: $name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themedCard()
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                CornerEditorView(field: field) { dismiss() }
            } label: {
                FieldActionRow(icon: "arrow.up.and.down.and.arrow.left.and.right",
                               title: "Adjust Corners",
                               subtitle: "Nudge the geometry on satellite imagery",
                               tint: Theme.signal,
                               showsChevron: true)
            }
            .buttonStyle(.plain)

            Divider()
                .overlay(Theme.surfaceStroke)
                .padding(.leading, 62)

            Button(role: .destructive) {
                Haptics.selection()
                showingDeleteConfirmation = true
            } label: {
                FieldActionRow(icon: "trash",
                               title: "Delete Field",
                               subtitle: nil,
                               tint: Theme.loss,
                               showsChevron: false,
                               titleColor: Theme.loss)
            }
            .buttonStyle(.plain)
        }
        .themedCard()
    }

    private var observationHint: some View {
        Text(field.observationCount < confirmedThreshold
             ? "Low-confidence geometry (\(field.observationCount) observation\(field.observationCount == 1 ? "" : "s")) — nudging corners locks it in as trained."
             : "Manual corrections count as high-weight trained observations.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Confirm and name a satellite-detected field proposal before saving. Reskinned to match the
/// drawer's "Detected" language: a satellite-tinted, dashed preview motif (echoing the map's dashed
/// proposal polygons), truthful "what happens" copy, a themed name field, and a turf Accept capsule.
struct AcceptProposalSheet: View {
    let rectangle: OrientedRectangle
    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Detected Field"

    private var satellite: Color { FieldSource.satellite.color }
    /// Whether on-device detections are contributed to the community field database (Settings).
    private var contributesToCommunity: Bool { SettingsStore.shared.contributeDetectedFields }
    private var isNameEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    statsRow
                    nameCard
                    whatHappensCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { acceptBar }
            .navigationTitle("New Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 12) {
            MapPreview(rectangle: rectangle, color: satellite)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.chipStroke(satellite),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(satellite)
                Text("Detected in satellite imagery")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Theme.tintWash(satellite, dark: 0.14, light: 0.10),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.chipStroke(satellite),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            FieldStatTile(label: "Dimensions",
                          value: "\(Int(rectangle.lengthMeters)) × \(Int(rectangle.widthMeters)) m",
                          tint: satellite)
            VStack(alignment: .leading, spacing: 8) {
                FieldSourceBadge(source: .satellite)
                Text("Source").captionLabel()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .metricTile(tint: satellite)
        }
    }

    // MARK: - Name

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Field Name").captionLabel().foregroundStyle(satellite)
            ThemedFieldTextField(placeholder: "Field name", text: $name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themedCard()
    }

    // MARK: - What happens

    private var whatHappensCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What happens").captionLabel().foregroundStyle(Theme.turf)
            whatHappensRow(icon: "checkmark.circle.fill", tint: Theme.turf,
                           text: "Adds this pitch to your saved fields and syncs it to your Apple Watch.")
            whatHappensRow(icon: "hand.draw.fill", tint: satellite,
                           text: "Fitted from imagery — adjust the corners any time to lock it in as trained.")
            whatHappensRow(icon: contributesToCommunity ? "person.2.fill" : "lock.fill",
                           tint: contributesToCommunity ? Theme.signal : Theme.bench,
                           text: contributesToCommunity
                                ? "Community sharing is on: on-device detections help map fields for nearby players. Manage it in Settings."
                                : "Community sharing is off — your fields stay on your devices only.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themedCard()
    }

    private func whatHappensRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Accept

    private var acceptBar: some View {
        Button {
            Haptics.impact(.medium)
            let field = FieldModel(
                id: UUID(), name: name, createdAt: Date(), outline: [],
                rectangle: rectangle, source: .satellite, observationCount: 0
            )
            fields.save(field)
            dismiss()
        } label: {
            Text("Accept Field")
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.turf)
        .clipShape(Capsule())
        .disabled(isNameEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

/// Thin compatibility wrapper over the unified `FieldBoundsEditor` (the good draggable-handle
/// editor lifted from Add Field's adjust phase). Kept so existing call sites — the field detail
/// sheet's "Adjust Corners" push — don't need to change; all behavior lives in `FieldBoundsEditor`.
struct CornerEditorView: View {
    let field: FieldModel
    var onSaved: () -> Void

    var body: some View {
        FieldBoundsEditor(field: field, onSaved: onSaved)
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
        // Metal-backed: never let layout resolve this to zero height mid-transition
        // ("CAMetalLayer ignoring invalid setDrawableSize 0x0" in device logs).
        .frame(minHeight: 120)
    }
}

// MARK: - Shared sheet components

/// Source presentation shared by the field sheets — the same AllTrails-style badge language the
/// drawer uses (`FieldsDrawer.swift`), duplicated file-privately here so the two sheets read
/// identically without exposing the drawer's private helpers.
private extension FieldSource {
    var badgeName: String {
        switch self {
        case .trained: return "Walked"
        case .inferred: return "GPS"
        case .satellite: return "Satellite"
        case .community: return "Community"
        }
    }

    var glyph: String {
        switch self {
        case .trained: return "figure.walk"
        case .inferred: return "location.fill"
        case .satellite: return "globe.americas.fill"
        case .community: return "person.2.fill"
        }
    }
}

/// A source-tinted rounded-square glyph tile — the leading mark from the drawer's place card,
/// scalable so it can headline a sheet hero.
struct FieldSourceTile: View {
    let source: FieldSource
    var size: CGFloat = 38
    var glyphSize: CGFloat = 16
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.chipFill(source.color))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: source.glyph)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(source.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.chipStroke(source.color), lineWidth: 1)
            )
    }
}

/// A tinted capsule naming a field's source (Walked / GPS / Satellite / Community).
struct FieldSourceBadge: View {
    let source: FieldSource

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(source.color)
                .frame(width: 6, height: 6)
            Text(source.badgeName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(source.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.chipFill(source.color), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.chipStroke(source.color), lineWidth: 1))
    }
}

/// A confidence hint mirroring the map and drawer: unconfirmed geometry gets a dashed capsule,
/// confirmed geometry a solid one.
struct FieldConfidenceBadge: View {
    let observationCount: Int
    let confirmedThreshold: Int

    private var isConfirmed: Bool { observationCount >= confirmedThreshold }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isConfirmed ? "checkmark.seal.fill" : "circle.dashed")
                .font(.system(size: 9, weight: .semibold))
            Text(isConfirmed ? "Confirmed" : "Unconfirmed")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(
            Capsule().strokeBorder(
                Color.secondary.opacity(0.4),
                style: isConfirmed
                    ? StrokeStyle(lineWidth: 1)
                    : StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        )
    }
}

/// A labeled mini-stat: a rounded numeral over an uppercase caption on a source-tinted metric tile.
struct FieldStatTile: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).captionLabel()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .metricTile(tint: tint)
    }
}

/// The house rename/name input: an elevated rounded field with a hairline stroke.
struct ThemedFieldTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .textInputAutocapitalization(.words)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
    }
}

/// A tappable themed row: tinted glyph tile, title (+ optional subtitle), optional chevron.
struct FieldActionRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    let tint: Color
    var showsChevron: Bool = false
    var titleColor: Color?

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.chipFill(tint))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.chipStroke(tint), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor ?? .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
