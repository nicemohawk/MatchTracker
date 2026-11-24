//
//  MatchIntents.swift
//  MatchTracker
//

import AppIntents
import MatchTrackerKit

/// The match format as Siri, Shortcuts and the Action button see it.
enum MatchFormatOption: String, AppEnum {
    case match, smallSided, indoor

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Match Type"
    static var caseDisplayRepresentations: [MatchFormatOption: DisplayRepresentation] = [
        .match: DisplayRepresentation(title: "Match", image: .init(systemName: "sportscourt")),
        .smallSided: DisplayRepresentation(title: "Pickup", image: .init(systemName: "figure.soccer")),
        .indoor: DisplayRepresentation(title: "Indoor", image: .init(systemName: "house"))
    ]

    var format: MatchFormat { MatchFormat(rawValue: rawValue) ?? .match }
}

/// "Hey Siri, start a match" — and the Action button on Apple Watch Ultra, where this is the
/// fastest possible start.
struct StartMatchIntent: StartWorkoutIntent {
    static var title: LocalizedStringResource = "Start Match"
    static var description = IntentDescription("Starts recording a match.")
    static var openAppWhenRun = true

    @Parameter(title: "Match Type")
    var workoutStyle: MatchFormatOption

    init() {}

    init(style: MatchFormatOption) {
        workoutStyle = style
    }

    static var suggestedWorkouts: [StartMatchIntent] {
        [.init(style: .match), .init(style: .smallSided), .init(style: .indoor)]
    }

    var displayRepresentation: DisplayRepresentation {
        MatchFormatOption.caseDisplayRepresentations[workoutStyle] ?? DisplayRepresentation(title: "Match")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutManager.shared.beginCountdown(field: WorkoutManager.shared.detectedField,
                                             format: workoutStyle.format)
        return .result()
    }
}

struct PauseMatchIntent: PauseWorkoutIntent {
    static var title: LocalizedStringResource = "Pause Match"

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutManager.shared.pause()
        return .result()
    }
}

struct ResumeMatchIntent: ResumeWorkoutIntent {
    static var title: LocalizedStringResource = "Resume Match"

    @MainActor
    func perform() async throws -> some IntentResult {
        WorkoutManager.shared.resume()
        return .result()
    }
}

/// The question a player actually asks on the touchline.
struct ToggleSubIntent: AppIntent {
    static var title: LocalizedStringResource = "Sub On or Off"
    static var description = IntentDescription("Records that you came off, or back on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard WorkoutManager.shared.phase == .active else { return .result() }
        WorkoutManager.shared.toggleSub()
        return .result()
    }
}

struct MatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMatchIntent(style: .match),
                    phrases: ["Start a match in \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Start Match", systemImageName: "soccerball")
        AppShortcut(intent: ToggleSubIntent(),
                    phrases: ["Sub me in \(.applicationName)"],
                    shortTitle: "Sub On or Off", systemImageName: "arrow.left.arrow.right")
    }
}
