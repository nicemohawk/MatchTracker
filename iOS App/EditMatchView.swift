// EditMatchView.swift
// MatchTracker

import MatchTrackerKit
import SwiftUI

/// Put right whatever the watch got wrong — or never knew.
struct EditMatchView: View {
    @ObservedObject var detail: MatchDetailModel
    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State private var opponent = ""
    @State private var notes = ""
    /// What the fields started as. Only what was changed is saved: a record that loads late must
    /// not be overwritten with the blanks shown before it did.
    @State private var loaded: (opponent: String, notes: String)?
    @State private var editing: MatchEvent?
    @State private var addingEvent = false
    @State private var adjusting: MatchDetailModel.AdjustableField?

    private var id: UUID { detail.matchIdentifier }

    private var moments: [MatchEvent] {
        detail.events.filter { MomentsChapter.isMoment($0.kind) || $0.source == .manual && [.subIn, .subOut].contains($0.kind) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Opponent", text: $opponent)
                        .onSubmit(commit)
                }
                Section("Moments") {
                    ForEach(moments) { event in
                        Button { editing = event } label: {
                            LabeledContent {
                                Text(detail.minutes.text(for: event.date)).monospacedDigit()
                            } label: {
                                Label(event.kind.momentTitle, systemImage: event.kind.momentSymbol)
                            }
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(event) }
                        }
                    }
                    Button("Add Moment", systemImage: "plus") { addingEvent = true }
                }
                Section {
                    DatePicker("Kickoff", selection: kickoff, in: detail.recordedInterval.start...detail.matchEnd,
                               displayedComponents: .hourAndMinute)
                    DatePicker("Full time", selection: fullTime, in: detail.matchStart...detail.recordedInterval.end,
                               displayedComponents: .hourAndMinute)
                    if detail.record?.trimmedStart != nil || detail.record?.trimmedEnd != nil {
                        Button("Use the Whole Recording") { store.trim(id, start: nil, end: nil) }
                    }
                } header: {
                    Text("When it was played")
                } footer: {
                    Text("Nothing is deleted. Warm-ups, drives home and forgotten stops are just left out.")
                }
                if let analytics = detail.analytics, analytics.hasRoute {
                    Section("Pitch") {
                        Button("We Attacked the Other Way", systemImage: "arrow.up.arrow.down") {
                            store.setFlipsAttack(!analytics.attackDirection.flipsAttack, for: id)
                        }
                        if detail.canAdjustField {
                            Button("Adjust the Outline", systemImage: "skew") { adjusting = detail.adjustableField() }
                        }
                    }
                }
                Section("Notes") {
                    TextField("How did it go?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Edit Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commit()
                        dismiss()
                    }
                }
            }
            .sheet(item: $editing) { MomentEditor(detail: detail, event: $0) }
            .sheet(isPresented: $addingEvent) { MomentEditor(detail: detail, event: nil) }
            .sheet(item: $adjusting) { adjustable in
                CornerEditorView(field: adjustable.field) {
                    if adjustable.isDraft { detail.bindField(id: adjustable.field.id) }
                    adjusting = nil
                }
            }
        }
        .onAppear {
            guard loaded == nil else { return }
            opponent = detail.record?.opponent ?? ""
            notes = detail.record?.notes ?? ""
            loaded = (opponent, notes)
        }
        .onChange(of: detail.record == nil) { _, isMissing in
            guard !isMissing, let record = detail.record else { return }
            if opponent.isEmpty { opponent = record.opponent ?? "" }
            if notes.isEmpty { notes = record.notes ?? "" }
            loaded = (record.opponent ?? "", record.notes ?? "")
        }
        // A swipe down keeps what was typed, like every other Apple form that saves as you go.
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let loaded else { return }
        if opponent != loaded.opponent { store.setOpponent(opponent, for: id) }
        if notes != loaded.notes { store.setNotes(notes, for: id) }
        self.loaded = (opponent, notes)
    }

    private func delete(_ event: MatchEvent) {
        guard let removed = store.deleteEvent(event.id, from: id) else { return }
        undoManager?.registerUndo(withTarget: store) { store in
            Task { @MainActor in store.restoreEvent(removed, to: id) }
        }
        undoManager?.setActionName("Delete Moment")
    }

    private var kickoff: Binding<Date> {
        Binding(get: { detail.matchStart }, set: { store.trim(id, start: $0, end: detail.record?.trimmedEnd) })
    }

    private var fullTime: Binding<Date> {
        Binding(get: { detail.matchEnd }, set: { store.trim(id, start: detail.record?.trimmedStart, end: $0) })
    }
}

/// One moment: what, when, and anything worth remembering about it.
private struct MomentEditor: View {
    @ObservedObject var detail: MatchDetailModel
    let event: MatchEvent?

    @EnvironmentObject private var store: MatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MatchEventKind = .goalForUs
    @State private var minute = 1
    @State private var loadedMinute = 1
    @State private var note = ""

    private let kinds: [MatchEventKind] = [.goalForUs, .goalMine, .assist, .goalAgainstUs, .subOut, .subIn,
                                           .flag, .yellowCard, .redCard, .foul]

    private var lastMinute: Int { detail.minutes.minute(of: detail.matchEnd) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("What happened", selection: $kind) {
                    ForEach(kinds, id: \.self) { Label($0.momentTitle, systemImage: $0.momentSymbol).tag($0) }
                }
                Picker("Minute", selection: $minute) {
                    ForEach(1...lastMinute, id: \.self) { Text("\($0)′").tag($0) }
                }
                .pickerStyle(.wheel)
                TextField("Note", text: $note, axis: .vertical)
            }
            .navigationTitle(event == nil ? "Add Moment" : "Edit Moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(event == nil ? "Add" : "Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            kind = event?.kind ?? .goalForUs
            minute = event.map(detail.minute) ?? max(1, lastMinute / 2)
            loadedMinute = minute
            note = event?.note ?? ""
        }
    }

    private func save() {
        let date = detail.minutes.date(ofMinute: minute)
        if let event {
            store.setEvent(event.id, in: detail.matchIdentifier, kind: kind,
                           date: minute == loadedMinute ? nil : date, note: note)
        } else {
            _ = store.addEvent(kind, at: date, note: note.isEmpty ? nil : note, to: detail.matchIdentifier)
        }
    }
}
