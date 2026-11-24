// MatchReminders.swift
// MatchTracker

import MatchTrackerKit
import UserNotifications

/// Asks how a match went once it has reached the phone: to confirm what was logged on the pitch, or
/// to fill in what wasn't.
@MainActor
final class MatchReminders: NSObject {
    static let shared = MatchReminders()

    /// Long enough to answer on the wrist instead.
    private static let delay: TimeInterval = 3 * 60
    private static let promptedKey = "reviewPromptedMatches"
    private let center = UNUserNotificationCenter.current()

    /// Call before launch finishes, so a tapped reminder finds someone listening.
    func start() {
        center.delegate = self
    }

    /// The record has arrived, or arrived again with the score given on the watch.
    func matchArrived(_ record: MatchRecord) {
        let identifier = Self.identifier(for: record.startDate)
        guard SettingsStore.shared.asksAfterMatches, let question = Question(record),
              let end = record.endDate, end > Date().addingTimeInterval(-6 * 3600) else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = question.title
        content.body = question.body
        content.sound = .default
        content.userInfo = ["link": MatchTrackerLink.review(startingAt: record.startDate).url.absoluteString]
        let request = UNNotificationRequest(
            identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.delay, repeats: false))
        Task {
            // Quiet until the player asks for more: nobody has been asked anything yet.
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
            try? await center.add(request)
        }
    }

    /// It has been said, so there's nothing left to ask.
    func reviewed(_ startDate: Date) {
        let identifier = Self.identifier(for: startDate)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Whether reminders would arrive without being asked for out loud.
    func remindsQuietly() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .provisional || status == .notDetermined
    }

    /// - Returns: Whether they said yes.
    func askToRemind() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Opening the app is also a moment to ask, once for each match.
    func shouldAsk(about match: UUID) -> Bool {
        guard SettingsStore.shared.asksAfterMatches else { return false }
        var asked = AppGroup.defaults.stringArray(forKey: Self.promptedKey) ?? []
        guard !asked.contains(match.uuidString) else { return false }
        asked.append(match.uuidString)
        AppGroup.defaults.set(Array(asked.suffix(50)), forKey: Self.promptedKey)
        return true
    }

    private static func identifier(for startDate: Date) -> String { "review-\(Int(startDate.timeIntervalSince1970))" }

    /// What's worth asking about a match, or nil when it's all been said.
    private struct Question {
        let title: String
        let body: String

        init?(_ record: MatchRecord) {
            guard record.reviewedAt == nil, let end = record.endDate, end.timeIntervalSince(record.startDate) >= 600 else { return nil }
            let marked = record.events.filter { $0.kind == .flag }.count
            if record.finalScore == nil, let logged = record.loggedScore {
                let title = MatchResultText.title(goalsUs: logged.us, goalsThem: logged.them) ?? ""
                self.init(title: "\(title)?", body: marked > 0 ? "Check the goals you logged and say what you marked."
                                                              : "Check the goals you logged.")
            } else if record.finalScore == nil {
                self.init(title: "How did it end?", body: marked > 0 ? "Add the score, and say what you marked."
                                                                    : "Add the score while it’s fresh.")
            } else if marked > 0 {
                self.init(title: marked == 1 ? "You marked a moment" : "You marked \(marked) moments", body: "Say what happened while it’s fresh.")
            } else {
                return nil
            }
        }

        private init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }
}

extension MatchReminders: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let link = (response.notification.request.content.userInfo["link"] as? String).flatMap(URL.init(string:))
            .flatMap(MatchTrackerLink.init)
        await MainActor.run { LinkRouter.shared.pending = link }
    }

    /// With the app open, the app asks.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}
