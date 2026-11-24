// LiveActivityDebugGallery.swift
// MatchTracker
//
// DEBUG-only. Draws the widgets and Live Activity inside the app, where they can be photographed in
// every appearance and text size, and plays a match into the live pipeline:
//   -SurfaceGallery widgets | season | accessories | live | button
//   -DemoLiveMatch YES      (-DemoLiveMatchEnds YES to blow the whistle after 25 s)
//   -OpenLink matchtracker://live

#if DEBUG
import SwiftUI
import WidgetKit
import MatchTrackerKit

struct SurfaceGallery: View {
    static var page: String? { UserDefaults.standard.string(forKey: "SurfaceGallery") }

    private let snapshot = WidgetSnapshot.sample

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                switch Self.page {
                case "season":
                    card(158, 158) { SeasonWidgetView(snapshot: snapshot, family: .systemSmall) }
                    card(338, 158) { SeasonWidgetView(snapshot: snapshot, family: .systemMedium) }
                    card(338, 158) { SeasonWidgetView(snapshot: unscored, family: .systemMedium) }
                    card(158, 158) { SeasonWidgetView(snapshot: nil, family: .systemSmall) }
                case "accessories": accessories
                case "live": liveActivities
                case "button":
                    StartOnWatchButton()
                    Button {} label: { Label("Start on Apple Watch", systemImage: "applewatch") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                default:
                    HStack(spacing: 22) {
                        card(158, 158) { LastMatchWidgetView(snapshot: snapshot, family: .systemSmall) }
                        card(158, 158) { LastMatchWidgetView(snapshot: unscored, family: .systemSmall) }
                    }
                    card(338, 158) { LastMatchWidgetView(snapshot: snapshot, family: .systemMedium) }
                    card(338, 354) { LastMatchWidgetView(snapshot: snapshot, family: .systemLarge) }
                    card(158, 158, background: .indigo) {
                        LastMatchWidgetView(snapshot: snapshot, family: .systemSmall, monochrome: true)
                            .environment(\.colorScheme, .dark)
                    }
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGray4))
    }

    private var unscored: WidgetSnapshot {
        var match = MatchDigest(id: UUID(), startDate: Date().addingTimeInterval(-90_000),
                                endDate: Date().addingTimeInterval(-86_000), format: .smallSided)
        match.distanceMeters = 5200
        match.fieldName = "Riverside Park North"
        return WidgetSnapshot.make(from: [match])
    }

    private func card<Content: View>(_ width: CGFloat, _ height: CGFloat,
                                     background: Color? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: height)
            .foregroundStyle(SurfacePalette.ivory)
            .environment(\.colorScheme, .dark)
            .background { if let background { background } else { WidgetCloth() } }
            .clipShape(.rect(cornerRadius: 22))
    }

    private var accessories: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([snapshot, unscored].indices, id: \.self) { index in
                let shown = [snapshot, unscored][index]
                LastMatchWidgetView(snapshot: shown, family: .accessoryInline)
                HStack(spacing: 14) {
                    LastMatchWidgetView(snapshot: shown, family: .accessoryCircular).frame(width: 72, height: 72)
                    LastMatchWidgetView(snapshot: shown, family: .accessoryRectangular).frame(width: 160, height: 72)
                }
                SeasonWidgetView(snapshot: shown, family: .accessoryInline)
                HStack(spacing: 14) {
                    SeasonWidgetView(snapshot: shown, family: .accessoryCircular).frame(width: 72, height: 72)
                    SeasonWidgetView(snapshot: shown, family: .accessoryRectangular).frame(width: 160, height: 72)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private var liveActivities: some View {
        VStack(spacing: 14) {
            ForEach(Self.states.indices, id: \.self) { index in
                let (state, isStale) = Self.states[index]
                LiveActivityLockScreenView(state: state, units: .current, isStale: isStale)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            HStack(spacing: 14) {
                ForEach([0, 4], id: \.self) { index in
                    LiveActivitySmallView(state: Self.states[index].0, units: .current)
                        .frame(width: 165, height: 70)
                        .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .environment(\.colorScheme, .dark)
                }
            }
        }
    }

    private static var states: [(LiveMatchState, Bool)] {
        func make(_ change: (inout LiveMatchState) -> Void) -> LiveMatchState {
            var state = LiveMatchState(startDate: Date().addingTimeInterval(-2531))
            state.onPitch = true
            state.goalsUs = 2
            state.goalsThem = 1
            state.heartRate = 164
            state.distanceMeters = 5230
            change(&state)
            return state
        }
        return [(make { _ in }, false),
                (make { $0.goalsUs = nil; $0.goalsThem = nil; $0.onPitch = false }, false),
                (make { $0.isAtBreak = true; $0.elapsed += 2000 }, false),
                (make { _ in }, true),
                (make { $0.goalsUs = 3; $0.hasEnded = true; $0.elapsed = 4320; $0.distanceMeters = 7403 }, false)]
    }
}

/// Plays a match at the pace of the real stream, through the same door.
@MainActor
enum DemoLiveMatch {
    private static var task: Task<Void, Never>?

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "DemoLiveMatch"), task == nil else { return }
        // It "kicked off" before the last demo ended, which would otherwise rule out a second activity.
        AppGroup.defaults.removeObject(forKey: "liveActivitySuppressedUntil")
        let ends = UserDefaults.standard.bool(forKey: "DemoLiveMatchEnds")
        // Kicked off 62 minutes ago, on whatever field is known first.
        let start = Date().addingTimeInterval(-62 * 60)
        let field = AppEnvironment.current?.fields.fields.first
        task = Task {
            for step in 1...600 {
                let angle = Double(step) / 9
                let points: [TrackPoint] = field.map { field in
                    let center = field.rectangle.center
                    return (0..<5).map { index in
                        let turn = angle + Double(index) / 45
                        return TrackPoint(
                            coordinate: Coordinate2D(latitude: center.latitude + 0.00018 * sin(turn * 1.7),
                                                     longitude: center.longitude + 0.00038 * cos(turn)),
                            timestamp: Date(), speedMetersPerSecond: 4, courseDegrees: 0, horizontalAccuracy: 4)
                    }
                } ?? []
                var events: [MatchEvent] = []
                if step == 1 {
                    let minutes: [(MatchEventKind, Double)] = [(.matchStart, 0), (.goalForUs, 12), (.goalAgainstUs, 31),
                                                               (.periodEnd, 45), (.periodStart, 55), (.goalMine, 58)]
                    events = minutes.map { MatchEvent(kind: $0.0, date: start.addingTimeInterval($0.1 * 60)) }
                }
                let isLast = ends && step == 12
                if isLast { events.append(MatchEvent(kind: .matchEnd, date: Date())) }
                AppEnvironment.current?.connectivity.onLiveUpdate?(LiveMatchUpdate(
                    sequence: step, timestamp: Date(), elapsed: Date().timeIntervalSince(start),
                    heartRate: 150 + 12 * sin(angle), distanceMeters: 7100 + Double(step) * 9,
                    currentSpeed: 3.4 + sin(angle), onPitch: step % 40 < 30,
                    latestPoints: points, newEvents: events,
                    usGoals: step > 10 ? 3 : 2, themGoals: 1))
                if isLast { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
#endif
