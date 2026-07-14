//
//  CoachDashboardView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Sideline coach view: every rostered player's live position and vitals, polled from the team
/// live endpoint, plus this device's own stream. A segmented "Timeline" pane coalesces every
/// teammate's tagged events into one unified, labelable feed. Optimized for iPad width via a
/// split view; still usable stacked on iPhone. Entitlement-gated by callers.
struct CoachDashboardView: View {
    let teamCode: String
    @EnvironmentObject private var uploads: UploadService
    @Environment(LiveMatchStore.self) private var liveMatches

    @State private var players: [LivePlayerStatus] = []
    @State private var selectedPlayerName: String?
    @State private var errorMessage: String?

    /// Which detail pane the coach is viewing. Pitch is the default.
    @State private var pane: DetailPane = .pitch

    // Timeline state
    @State private var teamEvents: [TeamEvent] = []
    @State private var filterPlayer: String?
    @State private var filterGroup: EventKindGroup?
    @State private var editingEventID: UUID?
    @State private var labelDraft: String = ""
    @State private var toast: String?

    private enum DetailPane: String, CaseIterable, Identifiable {
        case pitch = "Pitch"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            rosterList
                .navigationTitle("Live Team")
        } detail: {
            detailColumn
        }
        .task { await pollLoop() }
        .task { await eventPollLoop() }
    }

    // MARK: Roster

    private var rosterList: some View {
        List(selection: $selectedPlayerName) {
            if players.isEmpty {
                ContentUnavailableView(
                    "Waiting for Players",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(errorMessage ?? "Live positions appear when teammates start a match.")
                )
            }
            ForEach(players, id: \.playerName) { player in
                HStack {
                    Circle()
                        .fill(player.stale ? Color.gray : (player.onPitch ? Theme.turf : Theme.bench))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(player.playerName).font(.body)
                        HStack(spacing: 10) {
                            if let heartRate = player.heartRate {
                                Label("\(Int(heartRate))", systemImage: "heart.fill")
                            }
                            Label(String(format: "%.1f km", player.distanceMeters / 1000),
                                  systemImage: "figure.run")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .opacity(player.stale ? 0.45 : 1)
                .tag(player.playerName)
            }
        }
    }

    // MARK: Detail column (segmented)

    private var detailColumn: some View {
        VStack(spacing: 12) {
            Picker("View", selection: $pane) {
                ForEach(DetailPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            switch pane {
            case .pitch: pitchDetail
            case .timeline: timelineDetail
            }
        }
        .navigationTitle(teamCode)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { toastBanner }
    }

    // MARK: Pitch

    private var pitchDetail: some View {
        VStack(spacing: 16) {
            Canvas { context, size in
                let rect = SoccerPitch.fittedRect(in: size, padding: 10)
                SoccerPitch.fillTurf(&context, rect: rect)
                var markings = context
                SoccerPitch.draw(in: &markings, rect: rect)

                for player in players {
                    guard let x = player.x, let y = player.y else { continue }
                    let point = CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                                        y: rect.minY + CGFloat(y) * rect.height)
                    let isSelected = player.playerName == selectedPlayerName
                    let radius: CGFloat = isSelected ? 11 : 8
                    let dotRect = CGRect(x: point.x - radius, y: point.y - radius,
                                         width: radius * 2, height: radius * 2)
                    let tint = player.stale ? Color.gray : (player.onPitch ? Theme.signal : Theme.bench)
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: tint.opacity(0.6), radius: 5))
                        layer.fill(Path(ellipseIn: dotRect), with: .color(tint))
                    }
                    if isSelected {
                        context.stroke(Path(ellipseIn: dotRect), with: .color(Theme.goal), lineWidth: 2.5)
                    }
                    let label = Text(initials(player.playerName))
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                    context.draw(context.resolve(label), at: point)
                }
            }
            .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
            .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            selectedTiles

            Spacer()
        }
        .padding(.vertical)
    }

    @ViewBuilder
    private var selectedTiles: some View {
        if let player = players.first(where: { $0.playerName == selectedPlayerName }) {
            HStack {
                StatTile(title: "HR", value: player.heartRate.map { "\(Int($0))" } ?? "—", systemImage: "heart.fill")
                StatTile(title: "Distance", value: String(format: "%.2f km", player.distanceMeters / 1000), systemImage: "figure.run")
                StatTile(title: "Status", value: player.onPitch ? "On pitch" : "Bench", systemImage: "sportscourt")
            }
            .padding(.horizontal)
        }
    }

    // MARK: Timeline

    private var timelineDetail: some View {
        VStack(spacing: 0) {
            timelineHeader

            let rows = timelineRows
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Events from your team's matches appear here live.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                TeamEventRow(
                                    row: row,
                                    isEditing: editingEventID == row.id,
                                    labelDraft: $labelDraft,
                                    onBeginLabel: { beginLabeling(row) },
                                    onSubmitLabel: { Task { await submitLabel(for: row) } }
                                )
                                .id(row.id)
                                Divider().overlay(Theme.surfaceStroke)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: rows.count) { _, _ in
                        guard let last = rows.last else { return }
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        guard let last = rows.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var timelineHeader: some View {
        HStack {
            SectionHeaderBar(title: "Team Timeline", tint: Theme.goal,
                             subtitle: filterSubtitle)
            Spacer()
            Menu {
                Picker("Player", selection: $filterPlayer) {
                    Text("All players").tag(String?.none)
                    ForEach(rosterNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Picker("Kind", selection: $filterGroup) {
                    Text("All events").tag(EventKindGroup?.none)
                    ForEach(EventKindGroup.allCases) { group in
                        Text(group.title).tag(EventKindGroup?.some(group))
                    }
                }
            } label: {
                Label("Filter", systemImage: filterActive ? "line.3.horizontal.decrease.circle.fill"
                                                           : "line.3.horizontal.decrease.circle")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var filterActive: Bool { filterPlayer != nil || filterGroup != nil }

    private var filterSubtitle: String? {
        var parts: [String] = []
        if let filterPlayer { parts.append(filterPlayer) }
        if let filterGroup { parts.append(filterGroup.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Roster names offered in the filter menu: the live roster, unioned with any players who only
    /// appear in the event feed (so their events stay filterable even when they're off the live map).
    private var rosterNames: [String] {
        var names = Set(players.map(\.playerName))
        names.formUnion(teamEvents.map(\.playerName))
        return names.sorted()
    }

    @ViewBuilder
    private var toastBanner: some View {
        if let toast {
            Text(toast)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.chipFill(Theme.loss), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.chipStroke(Theme.loss), lineWidth: 1))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Merged rows

    /// Coalesced, filtered, chronological (oldest-first) timeline: every `TeamEvent` from the
    /// backend plus the local wearer's live events (deduped by event id — the server copy wins).
    private var timelineRows: [TimelineRow] {
        var rows = teamEvents.map(TimelineRow.init(teamEvent:))

        let known = Set(teamEvents.map(\.id))
        if liveMatches.isLive {
            let localName = SettingsStore.shared.playerName.isEmpty ? "Me" : SettingsStore.shared.playerName
            for event in liveMatches.events where !known.contains(event.id) {
                rows.append(TimelineRow(localEvent: event, playerName: localName))
            }
        }

        rows = rows.filter { row in
            if let filterPlayer, row.playerName != filterPlayer { return false }
            if let filterGroup, !filterGroup.contains(row.kind) { return false }
            return true
        }
        return rows.sorted { $0.date < $1.date }
    }

    // MARK: Labeling

    private func beginLabeling(_ row: TimelineRow) {
        labelDraft = ""
        editingEventID = row.id
        Haptics.selection()
    }

    private func submitLabel(for row: TimelineRow) async {
        let text = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingEventID = nil
        guard !text.isEmpty, let matchUUID = row.matchUUID else { return }

        // Optimistic: show the label immediately, roll back if the write fails.
        applyCoachLabel(text, toEventID: row.id)
        do {
            try await uploads.annotateTeamEvent(id: row.id, matchUUID: matchUUID, label: text)
            MatchLog.info("Labeled event \(row.id) for \(row.playerName)", category: "coach")
        } catch {
            applyCoachLabel(nil, toEventID: row.id)
            showToast("Couldn't save label")
            MatchLog.error("Annotate failed: \(error.localizedDescription)", category: "coach")
        }
    }

    private func applyCoachLabel(_ label: String?, toEventID id: UUID) {
        guard let index = teamEvents.firstIndex(where: { $0.id == id }) else { return }
        teamEvents[index].coachLabel = label
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { toast = nil }
        }
    }

    // MARK: Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func eventPollLoop() async {
        while !Task.isCancelled {
            await refreshEvents()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func refresh() async {
        do {
            var fetched = try await uploads.fetchLiveTeam(code: teamCode)
            // Merge the local wearer's own live stream (fresher than the server round-trip).
            if liveMatches.isLive, let update = liveMatches.latest {
                let localName = SettingsStore.shared.playerName.isEmpty ? "Me" : SettingsStore.shared.playerName
                fetched.removeAll { $0.playerName == localName }
                fetched.append(LivePlayerStatus(
                    playerName: localName, updatedAt: update.timestamp,
                    x: nil, y: nil,
                    heartRate: update.heartRate, distanceMeters: update.distanceMeters,
                    onPitch: update.onPitch, stale: false
                ))
            }
            players = fetched.sorted { $0.playerName < $1.playerName }
            errorMessage = nil
        } catch {
            errorMessage = "Live feed unavailable: \(error.localizedDescription)"
        }
    }

    private func refreshEvents() async {
        do {
            teamEvents = try await uploads.fetchTeamEvents(code: teamCode)
        } catch {
            // Non-fatal: the live pitch still works; keep the last-known events on screen.
            MatchLog.error("Team events unavailable: \(error.localizedDescription)", category: "coach")
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}

// MARK: - Timeline row model

/// One display row in the merged coach timeline, sourced either from a backend `TeamEvent` or the
/// local wearer's live `MatchEvent`. Local events carry no `matchUUID` (their match hasn't been
/// uploaded yet), so they can't be coach-labeled until they land server-side.
private struct TimelineRow: Identifiable {
    let id: UUID
    let date: Date
    let playerName: String
    let kind: MatchEventKind?
    let kindRaw: String
    let note: String?
    let coachLabel: String?
    /// nil for local live events (no server match to annotate against yet).
    let matchUUID: UUID?

    init(teamEvent event: TeamEvent) {
        id = event.id
        date = event.date
        playerName = event.playerName
        kind = event.kind
        kindRaw = event.kindRawValue
        note = event.note
        coachLabel = event.coachLabel
        matchUUID = event.matchUUID
    }

    init(localEvent event: MatchEvent, playerName: String) {
        id = event.id
        date = event.date
        self.playerName = playerName
        kind = event.kind
        kindRaw = event.kind.rawValue
        note = event.note
        coachLabel = nil
        matchUUID = nil
    }

    var title: String { kind?.title ?? kindRaw.capitalized }
    var systemImage: String { kind?.systemImage ?? "circle" }
    var tint: Color { kind.map(\.tint) ?? Color.secondary }
    /// A quiet "Add label" affordance shows only when the coach can actually annotate: the event
    /// has neither a player note nor a coach label, and it lives server-side (has a matchUUID).
    var canLabel: Bool {
        (note?.isEmpty ?? true) && (coachLabel?.isEmpty ?? true) && matchUUID != nil
    }
}

/// Kind buckets offered in the timeline filter menu.
private enum EventKindGroup: String, CaseIterable, Identifiable {
    case goals, cardsAndFouls, flags, subs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .goals: return "Goals"
        case .cardsAndFouls: return "Cards & Fouls"
        case .flags: return "Flags"
        case .subs: return "Subs"
        }
    }

    func contains(_ kind: MatchEventKind?) -> Bool {
        guard let kind else { return false }
        switch self {
        case .goals: return [.goalForUs, .goalAgainstUs, .goalMine, .assist].contains(kind)
        case .cardsAndFouls: return [.yellowCard, .redCard, .foul].contains(kind)
        case .flags: return [.flag, .turnover, .timeout].contains(kind)
        case .subs: return [.subIn, .subOut].contains(kind)
        }
    }
}

// MARK: - Timeline row view

private struct TeamEventRow: View {
    let row: TimelineRow
    let isEditing: Bool
    @Binding var labelDraft: String
    let onBeginLabel: () -> Void
    let onSubmitLabel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.date, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Image(systemName: row.systemImage)
                .font(.body)
                .foregroundStyle(row.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.playerName).font(.caption.weight(.bold)).foregroundStyle(.primary)
                    Text(row.title).font(.subheadline)
                }

                if let note = row.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }

                if let coachLabel = row.coachLabel, !coachLabel.isEmpty {
                    Label(coachLabel, systemImage: "tag.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.signal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.chipFill(Theme.signal), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.chipStroke(Theme.signal), lineWidth: 1))
                }

                if isEditing {
                    TextField("Add label", text: $labelDraft)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .submitLabel(.done)
                        .onSubmit(onSubmitLabel)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surfaceElevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 1))
                } else if row.canLabel {
                    Button(action: onBeginLabel) {
                        Label("Add label", systemImage: "plus.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
