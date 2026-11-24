// FieldsListSheet.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Your fields, most played first, with anything just detected above them.
struct FieldsList: View {
    @Bindable var model: FieldsMapModel
    let detected: [DetectedField]
    let onSelect: (FieldModel) -> Void
    let onReview: (DetectedField) -> Void
    let onDetect: () -> Void

    @EnvironmentObject private var fields: FieldsModel
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List {
            if !detected.isEmpty {
                Section("Found in this view") {
                    ForEach(detected) { candidate in
                        Button { onReview(candidate) } label: {
                            FieldRow(title: "Possible field", rectangle: candidate.rectangle, isGuess: true)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Dismiss", role: .destructive) { model.dismissed.insert(candidate.id) }
                        }
                    }
                }
            }
            if !fields.fields.isEmpty {
                Section {
                    ForEach(sortedFields, id: \.field.id) { entry in
                        Button { onSelect(entry.field) } label: {
                            FieldRow(title: entry.field.name.isEmpty ? "Unnamed field" : entry.field.name,
                                     rectangle: entry.field.rectangle,
                                     matchCount: entry.matchCount,
                                     isGuess: entry.field.needsOutlineCheck,
                                     needsCheck: entry.field.needsOutlineCheck)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .overlay {
            if fields.fields.isEmpty, detected.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Fields Yet", systemImage: "sportscourt")
        } description: {
            Text("Play a match with GPS and its field appears here. You can also add one now.")
        } actions: {
            Button("Draw Corners") { model.isDrawing = true }
                .buttonStyle(.bordered)
            Button("Detect in This View", action: onDetect)
                .buttonStyle(.bordered)
                .disabled(model.isDetecting)
        }
    }

    private var sortedFields: [(field: FieldModel, matchCount: Int)] {
        fields.fields
            .map { ($0, matches.matchCount(at: $0)) }
            .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
    }
}

/// One field: what it looks like, its name, how big it is and how often you've played there.
private struct FieldRow: View {
    let title: String
    let rectangle: OrientedRectangle
    var matchCount = 0
    var isGuess = false
    var needsCheck = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            FieldSatelliteImage(rectangle: rectangle, isGuess: isGuess)
                .frame(width: 84, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                if needsCheck {
                    Label("Check outline", systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                        .labelStyle(.titleAndIcon)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var detail: String {
        let size = MatchFormat.fieldSize(rectangle)
        guard matchCount > 0 else { return size }
        return "\(size) · \(Self.matches(matchCount))"
    }

    private var spoken: String {
        [title, MatchFormat.spokenFieldSize(rectangle),
         matchCount > 0 ? Self.matches(matchCount) : nil,
         needsCheck ? "Check outline" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func matches(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count) matches"
    }
}

extension MatchStore {
    /// How many recorded matches were played on a field: the ones that say so, plus the ones whose
    /// analysis placed them there.
    func matchCount(at field: FieldModel) -> Int {
        matches.filter { match in
            if let fieldID = match.record?.fieldID { return fieldID == field.id }
            guard let badge = cachedBadge(for: match.id), badge.stale != true else { return false }
            return badge.fieldName == field.name
        }.count
    }
}
