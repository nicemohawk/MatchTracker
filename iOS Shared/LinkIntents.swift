import AppIntents
import Observation
import MatchTrackerKit

/// Where the app has been asked to go, by a link, a control, a shortcut or Spotlight. The app
/// consumes it once it has a window to show it in, which may be after the request on a cold launch.
@MainActor
@Observable
final class LinkRouter {
    static let shared = LinkRouter()
    var pending: MatchTrackerLink?
}

/// These open the app, so they run in the app's process; the extension compiles them to build
/// controls from.
struct OpenLiveMatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Live Match"
    static var description = IntentDescription("Opens the match being recorded on your Apple Watch.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LinkRouter.shared.pending = .live
        return .result()
    }
}

struct OpenSeasonIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Season"
    static var description = IntentDescription("Opens your season.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LinkRouter.shared.pending = .season
        return .result()
    }
}

struct StartOnWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Match on Apple Watch"
    static var description = IntentDescription("Opens MatchTracker on your Apple Watch and starts recording.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LinkRouter.shared.pending = .start
        return .result()
    }
}
