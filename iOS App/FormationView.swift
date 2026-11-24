// FormationView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

/// Where everyone plays: a portrait pitch, attacking up, that a coach can rearrange by dragging.
struct FormationView: View {
    let teamCode: String

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var board: FormationBoard
    @State private var selected: String?
    @State private var chosenStyle: Style?

    private enum Style: String, CaseIterable { case pitch = "Pitch", list = "List" }

    init(teamCode: String) {
        self.teamCode = teamCode
        _board = State(initialValue: FormationBoard(teamCode: teamCode))
    }

    /// Dragging needs sight and space; the list has everything either way.
    private var style: Style {
        chosenStyle ?? (isVoiceOverOn || dynamicTypeSize.isAccessibilitySize ? .list : .pitch)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Formation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await board.load() }
            .sensoryFeedback(.impact(weight: .light), trigger: board.changeCount)
    }

    @ViewBuilder private var content: some View {
        if !board.spots.isEmpty {
            VStack(spacing: 12) {
                header
                switch style {
                case .pitch:
                    pitch
                    selectionBar
                case .list:
                    list
                }
            }
        } else {
            switch board.phase {
            case .loading:
                ProgressView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load the formation", systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await board.load() } }
                        .buttonStyle(.prominentAction)
                }
            case .loaded where board.squad.isEmpty:
                ContentUnavailableView("No squad yet", systemImage: "sportscourt",
                                       description: Text("Once teammates share a match, you can set them up here."))
            case .loaded:
                ContentUnavailableView {
                    Label("No formation yet", systemImage: "sportscourt")
                } description: {
                    Text("One appears after five teammates have shared matches. You can also set one up yourself.")
                } actions: {
                    Button("Set Up by Hand") { board.setUpByHand() }
                        .buttonStyle(.prominentAction)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                shapeName
                Spacer()
                stylePicker.frame(width: 160)
            }
            VStack(alignment: .leading) {
                shapeName
                stylePicker
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var shapeName: some View {
        Text(board.shapeName ?? "Your lineup")
            .font(.system(.largeTitle, design: .rounded).bold())
            .monospacedDigit()
            .contentTransition(.numericText())
            .fixedSize()
    }

    private var stylePicker: some View {
        Picker("Show as", selection: Binding(get: { style }, set: { chosenStyle = $0 })) {
            ForEach(Style.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !board.spots.isEmpty || board.canUndo {
                Button("Undo", systemImage: "arrow.uturn.backward") { withAnimation(.snappy) { board.undo() } }
                    .disabled(!board.canUndo)
            }
            if board.hasSuggestion {
                Menu("More", systemImage: "ellipsis") {
                    Button("Use Positions from Matches", systemImage: "figure.run") {
                        withAnimation(.snappy) { board.useSuggestion() }
                    }
                    .disabled(!board.isEdited)
                }
            }
        }
    }

    // MARK: Pitch

    private var pitch: some View {
        GeometryReader { geometry in
            let rect = PortraitPitch.fittedRect(in: geometry.size)
            ZStack {
                PortraitPitch()
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                ForEach(board.spots) { spot in
                    FormationMarker(spot: spot, isMe: settings.isMe(spot.name), isSelected: selected == spot.name,
                                    diameter: min(52, rect.width * 0.125), rect: rect, board: board) {
                        selected = selected == spot.name ? nil : spot.name
                    }
                }
            }
            .coordinateSpace(.named(FormationMarker.space))
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formation. \(board.spoken)")
    }

    private var selectionBar: some View {
        Group {
            if let spot = board.spots.first(where: { $0.name == selected }) {
                HStack {
                    VStack(alignment: .leading) {
                        TeamPlayerName(name: spot.name).font(.headline)
                        Text(spot.role).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    swapMenu(spot.name)
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Drag a player to move them. Drop one on another to swap.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func swapMenu(_ name: String) -> some View {
        Menu("Swap") {
            if !board.bench.isEmpty {
                Section("Bring on") {
                    ForEach(board.bench, id: \.self) { other in
                        Button(other) { swap(name, other) }
                    }
                }
            }
            Section("Swap places with") {
                ForEach(board.spots.map(\.name).filter { $0 != name }, id: \.self) { other in
                    Button(other) { swap(name, other) }
                }
            }
        }
        .accessibilityLabel("Swap \(name)")
    }

    private func swap(_ name: String, _ other: String) {
        withAnimation(.snappy) { board.swap(name, with: other) }
        if selected == name && !board.spots.contains(where: { $0.name == name }) { selected = other }
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(board.lines, id: \.title) { line in
                Section(line.title) {
                    ForEach(line.spots) { spot in
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                row(spot)
                                Spacer()
                                swapMenu(spot.name)
                            }
                            VStack(alignment: .leading) {
                                row(spot)
                                swapMenu(spot.name)
                            }
                        }
                    }
                }
            }
            if !board.bench.isEmpty {
                Section("Bench") {
                    ForEach(board.bench, id: \.self) { TeamPlayerName(name: $0) }
                }
            }
        }
        .readableFormWidth()
    }

    private func row(_ spot: FormationBoard.Spot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TeamPlayerName(name: spot.name)
            Text(spot.role).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Marker

/// One player on the pitch: drag to move, tap to select, VoiceOver actions to nudge.
private struct FormationMarker: View {
    static let space = "formation"

    let spot: FormationBoard.Spot
    let isMe: Bool
    let isSelected: Bool
    let diameter: CGFloat
    let rect: CGRect
    let board: FormationBoard
    let onTap: () -> Void

    @GestureState private var translation: CGSize = .zero

    var body: some View {
        let isDragging = translation != .zero
        VStack(spacing: 3) {
            Text(RosterAvatar.initials(from: spot.name))
                .font(.system(size: diameter * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: diameter, height: diameter)
                .background(isMe ? Theme.turf : .white, in: Circle())
                .overlay { Circle().strokeBorder(.white, lineWidth: isSelected || isDragging ? 4 : 0).padding(-6) }
            Text(isMe ? "You" : RosterAvatar.shortName(spot.name))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .contentShape(Rectangle())
        .scaleEffect(isDragging ? 1.12 : 1)
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .updating($translation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let start = PortraitPitch.point(x: spot.x, y: spot.y, in: rect)
                    let end = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                    drop(at: end)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMe ? "\(spot.name), you" : spot.name)
        .accessibilityValue(spot.role)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Move forward") { board.move(spot.name, toX: spot.x + 0.08, y: spot.y) }
        .accessibilityAction(named: "Move back") { board.move(spot.name, toX: spot.x - 0.08, y: spot.y) }
        .accessibilityAction(named: "Move left") { board.move(spot.name, toX: spot.x, y: spot.y - 0.12) }
        .accessibilityAction(named: "Move right") { board.move(spot.name, toX: spot.x, y: spot.y + 0.12) }
        .position(PortraitPitch.point(x: spot.x, y: spot.y, in: rect))
        .offset(translation)
        .zIndex(isDragging ? 1 : 0)
    }

    private func drop(at point: CGPoint) {
        let other = board.spots.first { candidate in
            guard candidate.name != spot.name else { return false }
            let center = PortraitPitch.point(x: candidate.x, y: candidate.y, in: rect)
            return hypot(center.x - point.x, center.y - point.y) < diameter * 0.6
        }
        withAnimation(.snappy) {
            if let other {
                board.swap(spot.name, with: other.name)
            } else {
                let place = PortraitPitch.place(point, in: rect)
                board.move(spot.name, toX: place.x, y: place.y)
            }
        }
    }
}

// MARK: - Pitch drawing

/// A full pitch standing up, our goal at the bottom.
struct PortraitPitch: View {
    static let aspect = SoccerPitch.widthMeters / SoccerPitch.lengthMeters

    var body: some View {
        Canvas { context, size in
            let rect = Self.fittedRect(in: size)
            SoccerPitch.fillTurf(&context, rect: rect)
            // The shared markings lie on their side; stand them up.
            let lying = CGRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width)
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: .degrees(-90))
            SoccerPitch.draw(in: &context, rect: lying, lineColor: .white.opacity(0.35))
        }
        .accessibilityHidden(true)
    }

    static func fittedRect(in size: CGSize) -> CGRect {
        let height = min(size.height, size.width / aspect)
        let width = height * aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// `x` runs up the pitch from our goal, `y` from the left touchline to the right.
    static func point(x: Double, y: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + y * rect.width, y: rect.maxY - x * rect.height)
    }

    static func place(_ point: CGPoint, in rect: CGRect) -> (x: Double, y: Double) {
        ((rect.maxY - point.y) / rect.height, (point.x - rect.minX) / rect.width)
    }
}

// MARK: - Board

/// The formation on screen: suggested from matches until someone moves a player, then theirs.
/// Kept on this device; the server has nowhere to put it.
@Observable
@MainActor
final class FormationBoard {
    struct Spot: Codable, Equatable, Identifiable {
        var name: String
        var x: Double
        var y: Double
        var id: String { name }
        var role: String { FormationShape.role(x: x, y: y) }
    }

    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var spots: [Spot] = []
    private(set) var squad: [String] = []
    private(set) var changeCount = 0
    private(set) var isEdited = false
    private var suggestion: [Spot] = []
    private var suggestedName: String?
    private var history: [[Spot]] = []
    private let teamCode: String

    init(teamCode: String) {
        self.teamCode = teamCode
        if let data = AppGroup.defaults.data(forKey: storageKey), let saved = try? JSONDecoder().decode([Spot].self, from: data) {
            spots = saved
            isEdited = true
        }
    }

    private var storageKey: String { "formation.\(teamCode)" }

    var canUndo: Bool { !history.isEmpty }
    var hasSuggestion: Bool { !suggestion.isEmpty }
    var bench: [String] { squad.filter { name in !spots.contains { $0.name == name } } }

    var shapeName: String? { isEdited ? FormationShape.name(depths: spots.map(\.x)) : suggestedName }

    var lines: [(title: String, spots: [Spot])] {
        let sorted = spots.sorted { $0.y < $1.y }
        let keeper = sorted.filter { $0.role == "Goalkeeper" }
        let outfield = sorted.filter { $0.role != "Goalkeeper" }
        return [
            ("Forwards", outfield.filter { $0.x >= 0.64 }),
            ("Midfielders", outfield.filter { $0.x >= 0.36 && $0.x < 0.64 }),
            ("Defenders", outfield.filter { $0.x < 0.36 }),
            ("Goalkeeper", keeper)
        ].filter { !$0.1.isEmpty }
    }

    var spoken: String {
        lines.reversed().map { "\($0.title): \($0.spots.map(\.name).formatted())" }.joined(separator: ". ")
    }

    func load() async {
        if spots.isEmpty { phase = .loading }
        do {
            async let formation = TeamService.formation(code: teamCode)
            async let stats = TeamService.stats(code: teamCode, since: TeamModel.seasonStart)
            let (newFormation, newStats) = try await (formation, stats)
            squad = newStats.players.map(\.name).sorted()
            suggestion = newFormation?.slots.map { Spot(name: $0.playerName, x: $0.x, y: $0.y) } ?? []
            suggestedName = newFormation?.name
            if !isEdited { spots = suggestion }
            phase = .loaded
        } catch {
            phase = .failed(TeamService.explain(error))
        }
    }

    // MARK: Changes

    func move(_ name: String, toX x: Double, y: Double) {
        guard let index = spots.firstIndex(where: { $0.name == name }) else { return }
        change {
            spots[index].x = min(0.96, max(0.06, x))
            spots[index].y = min(0.92, max(0.08, y))
        }
    }

    /// Swaps two players' places, or brings `other` on for `name` from the bench.
    func swap(_ name: String, with other: String) {
        guard let index = spots.firstIndex(where: { $0.name == name }) else { return }
        change {
            if let otherIndex = spots.firstIndex(where: { $0.name == other }) {
                spots[otherIndex].name = name
            }
            spots[index].name = other
        }
    }

    func setUpByHand() {
        change {
            spots = zip(squad, FormationShape.startingPoints).map { Spot(name: $0, x: $1.x, y: $1.y) }
        }
    }

    func useSuggestion() {
        change { spots = suggestion }
        isEdited = false
        save()
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        spots = previous
        isEdited = spots != suggestion && !spots.isEmpty
        changeCount += 1
        save()
    }

    private func change(_ edit: () -> Void) {
        history.append(spots)
        edit()
        isEdited = true
        changeCount += 1
        save()
    }

    private func save() {
        AppGroup.defaults.set(isEdited ? try? JSONEncoder().encode(spots) : nil, forKey: storageKey)
    }
}
