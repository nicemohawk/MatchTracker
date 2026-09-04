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
    @State private var hasLoadedTeam = false

    /// Which detail pane the coach is viewing. Pitch is the default.
    @State private var pane: DetailPane = .pitch

    // Timeline state
    @State private var teamEvents: [TeamEvent] = []
    @State private var filterPlayer: String?
    @State private var filterGroup: EventKindGroup?
    @State private var editingEventID: UUID?
    @State private var labelDraft: String = ""
    @State private var toast: String?
    @State private var hasLoadedEvents = false
    @State private var eventErrorMessage: String?

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
                if !hasLoadedTeam {
                    ForEach(0..<4, id: \.self) { index in
                        RosterSkeletonRow(width: 150 - CGFloat(index * 18))
                            .listRowSeparator(.hidden)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Waiting for Players", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(errorMessage ?? "Live positions appear when teammates start a match.")
                    } actions: {
                        if errorMessage != nil {
                            Button("Retry") { Task { await refresh() } }
                                .buttonStyle(.bordered)
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            ForEach(players, id: \.playerName) { player in
                rosterRow(player)
                    .tag(player.playerName)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: players.map(\.playerName))
    }

    private func rosterRow(_ player: LivePlayerStatus) -> some View {
        HStack(spacing: 12) {
            PlayerAvatar(name: player.playerName, size: 38)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusTint(player))
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.playerName)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                HStack(spacing: 12) {
                    if let heartRate = player.heartRate {
                        Label("\(Int(heartRate))", systemImage: "heart.fill")
                            .foregroundStyle(Theme.heart)
                    }
                    Label(String(format: "%.1f km", player.distanceMeters / 1000),
                          systemImage: "figure.run")
                        .foregroundStyle(Theme.pace)
                }
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .labelStyle(.titleAndIcon)
            }
        }
        .opacity(player.stale ? 0.5 : 1)
    }

    private func statusTint(_ player: LivePlayerStatus) -> Color {
        player.stale ? Theme.bench : (player.onPitch ? Theme.turf : Theme.bench)
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

            Group {
                switch pane {
                case .pitch: pitchDetail
                case .timeline: timelineDetail
                }
            }
            .id(pane)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .animation(.easeInOut(duration: 0.28), value: pane)
        .onChange(of: pane) { Haptics.selection() }
        .navigationTitle(teamCode)
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .bottom) { toastBanner }
    }

    // MARK: Pitch

    private var pitchDetail: some View {
        VStack(spacing: 16) {
            // Center the empty board vertically so an offline/waiting coach sees a composed screen,
            // not a pitch pinned to the top over a void.
            if players.isEmpty { Spacer(minLength: 0) }

            pitchCanvas
                .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                )
                // In the two-column split the roster's own empty state is hidden behind the sidebar
                // toggle (iPad portrait), so the pitch must explain itself when there's no one on it.
                .overlay { if players.isEmpty { pitchEmptyOverlay } }
                .padding(.horizontal)

            benchStrip

            selectedTiles

            Spacer(minLength: 0)
        }
        .padding(.vertical)
        // Keep the pitch + tiles a sensible measure in a wide split detail column, not stretched.
        .readableWidth()
    }

    /// Waiting / offline messaging drawn directly on the empty turf. White-on-turf reads cleanly in
    /// both app color schemes (the pitch fill is always dark), and mirrors the timeline's error line.
    @ViewBuilder
    private var pitchEmptyOverlay: some View {
        if !hasLoadedTeam {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        } else {
            VStack(spacing: 10) {
                Image(systemName: errorMessage != nil ? "wifi.slash" : "dot.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                Text(errorMessage != nil ? "Live feed unavailable" : "Waiting for players")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(errorMessage != nil
                     ? "Positions appear once the team feed reconnects."
                     : "Live positions appear when teammates start a match.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                if errorMessage != nil {
                    Button("Retry") { Task { await refresh() } }
                        .font(.callout.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.turf)
                        .padding(.top, 2)
                }
            }
            .padding(24)
            // A soft dark scrim so the white copy stays legible over the white pitch markings
            // (the center circle runs right behind the message at most sizes).
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.45))
            )
        }
    }

    /// The live pitch, driven by a `TimelineView(.animation)` so on-pitch players emit a soft,
    /// continuous pulse ring without per-view state.
    private var pitchCanvas: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let rect = SoccerPitch.fittedRect(in: size, padding: 10)
                SoccerPitch.fillTurf(&context, rect: rect)
                var markings = context
                SoccerPitch.draw(in: &markings, rect: rect)

                let phase = timeline.date.timeIntervalSinceReferenceDate
                let pulse = (sin(phase * 2.2) + 1) / 2   // 0…1

                for player in players {
                    guard let x = player.x, let y = player.y else { continue }
                    let point = CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                                        y: rect.minY + CGFloat(y) * rect.height)
                    let isSelected = player.playerName == selectedPlayerName
                    let tint = player.stale ? Color.gray : RosterAvatar.tint(for: player.playerName)

                    // Live pulse: an expanding, fading ring for players currently on the pitch.
                    if player.onPitch && !player.stale {
                        let ringRadius = 12 + CGFloat(pulse) * 10
                        let ringRect = CGRect(x: point.x - ringRadius, y: point.y - ringRadius,
                                              width: ringRadius * 2, height: ringRadius * 2)
                        context.stroke(Path(ellipseIn: ringRect),
                                       with: .color(tint.opacity((1 - pulse) * 0.55)),
                                       lineWidth: 2)
                    }

                    let radius: CGFloat = isSelected ? 12 : 9
                    let dotRect = CGRect(x: point.x - radius, y: point.y - radius,
                                         width: radius * 2, height: radius * 2)
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 3, y: 1))
                        layer.fill(Path(ellipseIn: dotRect), with: .color(tint))
                    }
                    context.stroke(Path(ellipseIn: dotRect),
                                   with: .color(isSelected ? Theme.goal : .white.opacity(0.85)),
                                   lineWidth: isSelected ? 2.5 : 1.25)

                    let label = Text(RosterAvatar.initials(from: player.playerName))
                        .font(.system(size: isSelected ? 10 : 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                    context.draw(context.resolve(label), at: point)
                }
            }
        }
    }

    /// Players not currently on the pitch, as a horizontal strip of tappable avatars beneath it.
    @ViewBuilder
    private var benchStrip: some View {
        let bench = players.filter { !$0.onPitch }
        if !bench.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bench").captionLabel().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(bench, id: \.playerName) { player in
                            Button {
                                selectedPlayerName = player.playerName
                                Haptics.selection()
                            } label: {
                                VStack(spacing: 4) {
                                    PlayerAvatar(name: player.playerName, size: 40)
                                        .overlay(
                                            Circle().strokeBorder(
                                                player.playerName == selectedPlayerName ? Theme.goal : .clear,
                                                lineWidth: 2)
                                        )
                                    Text(RosterAvatar.initials(from: player.playerName))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .opacity(player.stale ? 0.5 : 1)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedTiles: some View {
        if let player = players.first(where: { $0.playerName == selectedPlayerName }) {
            HStack(spacing: 12) {
                StatTile(title: "HR", value: player.heartRate.map { "\(Int($0))" } ?? "—",
                         systemImage: "heart.fill", tint: Theme.heart)
                StatTile(title: "Distance", value: String(format: "%.2f km", player.distanceMeters / 1000),
                         systemImage: "figure.run", tint: Theme.pace)
                StatTile(title: "Status", value: player.onPitch ? "On pitch" : "Bench",
                         systemImage: "sportscourt", tint: player.onPitch ? Theme.turf : Theme.bench)
            }
            .padding(.horizontal)
        }
    }

    // MARK: Timeline

    private var timelineDetail: some View {
        VStack(spacing: 0) {
            timelineHeader

            let rows = timelineRows
            if rows.isEmpty && !hasLoadedEvents {
                if let eventErrorMessage {
                    errorLine(eventErrorMessage) { Task { await refreshEvents() } }
                } else {
                    TimelineSkeleton()
                }
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Events from your team's matches appear here live.")
                )
                .frame(maxHeight: .infinity)
            } else {
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
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                            Divider().overlay(Theme.surfaceStroke)
                        }
                    }
                    .padding(.horizontal)
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: rows.first?.id)
                }
            }
        }
        // Keep the header + ticker a readable centered column in a wide split detail pane.
        .readableWidth()
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

    /// A quiet, retryable failure line — used where a bare error would be too loud.
    private func errorLine(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.title3).foregroundStyle(.secondary)
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Coalesced, filtered, newest-first timeline: every `TeamEvent` from the backend plus the
    /// local wearer's live events (deduped by event id — the server copy wins). Newest-first so
    /// fresh events tick in at the top like a broadcast ticker.
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
        return rows.sorted { $0.date > $1.date }
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
        hasLoadedTeam = true
    }

    private func refreshEvents() async {
        do {
            teamEvents = try await uploads.fetchTeamEvents(code: teamCode)
            eventErrorMessage = nil
            hasLoadedEvents = true
        } catch {
            // Non-fatal: the live pitch still works; keep the last-known events on screen.
            if !hasLoadedEvents {
                eventErrorMessage = "Team timeline unavailable right now."
            }
            MatchLog.error("Team events unavailable: \(error.localizedDescription)", category: "coach")
        }
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

    /// The glyph's semantic color. Subs read neutral bench (per the coach palette); every other
    /// kind uses the app-wide `MatchEventKind.tint` (goals turf, cards yellow, etc.).
    var glyphTint: Color {
        switch kind {
        case .subIn, .subOut: return Theme.bench
        default: return kind.map(\.tint) ?? Color.secondary
        }
    }

    /// A quiet "Label" affordance shows only when the coach can actually annotate: the event
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
            // Relative time chip — monospaced, ticks like a broadcast clock.
            Text(row.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)

            PlayerAvatar(name: row.playerName, size: 30)

            // Event glyph in its semantic color, on a matching tint chip.
            Image(systemName: row.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.glyphTint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.chipFill(row.glyphTint)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.playerName).font(.caption.weight(.bold)).foregroundStyle(.primary)
                    Text(row.title).font(.subheadline)
                }

                if let note = row.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    PulsingLabelChip(action: onBeginLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

/// The quiet "Label" affordance for unlabeled events: a tinted chip with a gentle breathing
/// pulse to draw the eye without shouting. Tapping opens the inline label field.
private struct PulsingLabelChip: View {
    let action: () -> Void
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label("Label", systemImage: "tag")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.signal)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Theme.chipFill(Theme.signal), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.chipStroke(Theme.signal), lineWidth: 1))
                .opacity(pulsing ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Skeletons

/// A leaderboard-shaped shimmer row for the loading roster sidebar.
private struct RosterSkeletonRow: View {
    var width: CGFloat = 140

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.surfaceElevated).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                    .frame(width: width, height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                    .frame(width: 90, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .coachShimmer()
    }
}

/// Ticker-shaped shimmer rows shown while the timeline first loads.
private struct TimelineSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                        .frame(width: 44, height: 12)
                    Circle().fill(Theme.surfaceElevated).frame(width: 30, height: 30)
                    Circle().fill(Theme.surfaceElevated).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                            .frame(width: 160 - CGFloat(index * 14), height: 13)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
                            .frame(width: 100, height: 10)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                Divider().overlay(Theme.surfaceStroke)
            }
        }
        .padding(.horizontal)
        .redacted(reason: .placeholder)
        .coachShimmer()
    }
}

// MARK: - Shimmer

/// A lightweight left-to-right sheen for redacted placeholders (local to the coach surface so it
/// stays self-contained; mirrors the roster leaderboard's shimmer).
private struct CoachShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5)
                    .offset(x: phase * geometry.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func coachShimmer() -> some View { modifier(CoachShimmer()) }
}
