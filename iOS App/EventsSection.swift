// EventsSection.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct EventsSection: View {
    @ObservedObject var detail: MatchDetailModel
    @EnvironmentObject private var store: MatchStore

    @State private var events: [MatchEvent] = []
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            scoreRecap

            HStack {
                Text("Timeline").font(.headline)
                Spacer()
                Menu {
                    ForEach(MatchEventKind.allCases, id: \.self) { kind in
                        Button {
                            addEvent(kind: kind)
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
            }

            if events.isEmpty {
                Text("No events recorded.").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(events.sorted { $0.date < $1.date }) { event in
                        EventRow(
                            event: event,
                            minute: minuteOfMatch(event.date),
                            note: bindingForNote(event),
                            onDelete: { deleteEvent(event) }
                        )
                        Divider()
                    }
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            events = detail.events
            didLoad = true
        }
        .onChange(of: detail.events) { _, _ in
            events = detail.events
        }
    }

    private var scoreRecap: some View {
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        return HStack {
            Spacer()
            VStack {
                Text("\(us) – \(them)").font(.largeTitle.bold().monospacedDigit())
                Text("Us vs Them").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Mutations

    private func minuteOfMatch(_ date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(detail.matchStart) / 60))
    }

    private func bindingForNote(_ event: MatchEvent) -> Binding<String> {
        Binding(
            get: { events.first(where: { $0.id == event.id })?.note ?? "" },
            set: { newValue in
                guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
                events[index].note = newValue.isEmpty ? nil : newValue
                persist()
            }
        )
    }

    private func addEvent(kind: MatchEventKind) {
        events.append(MatchEvent(kind: kind, date: Date().clamped(to: detail.matchStart...detail.matchEnd)))
        persist()
    }

    private func deleteEvent(_ event: MatchEvent) {
        events.removeAll { $0.id == event.id }
        persist()
    }

    private func persist() {
        let base = detail.record ?? MatchRecord(
            id: detail.matchIdentifier,
            startDate: detail.matchStart,
            endDate: detail.matchEnd,
            fieldID: nil,
            events: [],
            teamCode: nil
        )
        var updated = base
        updated.events = events
        store.save(record: updated)
    }
}

struct EventRow: View {
    let event: MatchEvent
    let minute: Int
    @Binding var note: String
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.kind.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(minute)'").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(event.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
                TextField("Add note", text: $note, axis: .vertical)
                    .font(.caption)
                    .textFieldStyle(.plain)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
