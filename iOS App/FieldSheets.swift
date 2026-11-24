// FieldSheets.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

/// One field: its name and size, and what you can do with it. The map it opens over is its picture.
struct FieldDetailView: View {
    let fieldID: UUID
    var onDeleted: () -> Void = {}

    @EnvironmentObject private var fields: FieldsModel
    @EnvironmentObject private var matches: MatchStore
    @State private var name = ""
    @FocusState private var isNaming: Bool
    @State private var isAdjusting = false
    @State private var confirmingDelete = false

    var body: some View {
        if let field = fields.field(id: fieldID) {
            form(for: field)
        } else {
            ContentUnavailableView("Field Deleted", systemImage: "sportscourt")
        }
    }

    private func form(for field: FieldModel) -> some View {
        Form {
            Section {
                TextField("Field name", text: $name, axis: .vertical)
                    .font(.title2.bold())
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isNaming)
                    // A field that wraps takes Return as a new line; here it means done.
                    .onChange(of: name) { _, typed in
                        guard typed.contains(where: \.isNewline) else { return }
                        name = typed.filter { !$0.isNewline }
                        isNaming = false
                    }
                    .onChange(of: isNaming) { _, naming in
                        if !naming { rename(field) }
                    }
                    .accessibilityHint("Edits the field’s name")
                LabeledContent("Size", value: MatchFormat.fieldSize(field.rectangle))
                    .accessibilityValue(MatchFormat.spokenFieldSize(field.rectangle))
                let matchCount = matches.matchCount(at: field)
                if matchCount > 0 {
                    LabeledContent("Matches played", value: matchCount.formatted())
                }
            }
            if field.needsOutlineCheck {
                Section {
                    Button("Check Outline") { isAdjusting = true }
                } footer: {
                    Text(reasonToCheck(field))
                }
            }
            Section {
                if !field.needsOutlineCheck {
                    Button("Adjust Outline", systemImage: "skew") { isAdjusting = true }
                }
                Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") { openDirections(to: field) }
            }
            Section {
                Button("Delete Field", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("Delete \(field.name)?", isPresented: $confirmingDelete,
                                        titleVisibility: .visible) {
                        Button("Delete Field", role: .destructive) {
                            fields.delete(id: field.id)
                            onDeleted()
                        }
                    } message: {
                        Text("It’s removed from this iPhone and your watch. Matches you played here are kept.")
                    }
            }
        }
        .navigationTitle("Field")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.top, 8, for: .scrollContent)
        // Follows the automatic name when it arrives, unless the player has typed their own.
        .onChange(of: field.name, initial: true) { _, newName in name = newName }
        .onDisappear { rename(field) }
        .fullScreenCover(isPresented: $isAdjusting) {
            CornerEditorView(field: field, onSaved: {})
        }
    }

    private func reasonToCheck(_ field: FieldModel) -> String {
        let origin: String
        switch field.source {
        case .inferred: origin = "MatchTracker worked this outline out from where you ran."
        case .satellite: origin = "MatchTracker found this outline in satellite imagery."
        case .community: origin = "This outline came from other players."
        case .trained: origin = ""
        }
        return "\(origin) Line it up with the field so your heat map is right."
    }

    private func rename(_ field: FieldModel) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read the stored field again: it may have been deleted or adjusted since this one was drawn.
        guard var current = fields.field(id: field.id), !trimmed.isEmpty, trimmed != current.name else { return }
        current.name = trimmed
        fields.save(current)
    }

    private func openDirections(to field: FieldModel) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: field.rectangle.center.clCoordinate))
        item.name = field.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

/// Review a field found in satellite imagery before adding it.
struct DetectedFieldView: View {
    let candidate: DetectedField
    let onAdded: (FieldModel) -> Void
    let onDismissed: () -> Void

    @EnvironmentObject private var fields: FieldsModel
    @State private var name = ""
    @State private var isAdjusting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Field name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                }
                LabeledContent("Size", value: MatchFormat.fieldSize(candidate.rectangle))
                    .accessibilityValue(MatchFormat.spokenFieldSize(candidate.rectangle))
            } footer: {
                Text("Leave the name empty to use the name of the place.")
            }
            Section {
                Button("Adjust Outline", systemImage: "skew") { isAdjusting = true }
                Button("Not a Field", role: .destructive, action: onDismissed)
            }
        }
        .navigationTitle("Is This a Field?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: add)
            }
        }
        .fullScreenCover(isPresented: $isAdjusting) {
            AddFieldView(detected: candidate.rectangle, onAdded: onAdded)
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let field = FieldModel(id: UUID(), name: trimmed.isEmpty ? "New Field" : trimmed, createdAt: Date(),
                               outline: [], rectangle: candidate.rectangle, source: .satellite, observationCount: 0)
        fields.save(field)
        onAdded(field)
    }
}
