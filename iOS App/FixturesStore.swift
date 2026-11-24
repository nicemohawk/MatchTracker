// FixturesStore.swift
// MatchTracker

import EventKit
import Foundation
import Observation
import MatchTrackerKit

/// Upcoming and recent matches read from calendars the player picked. Read-only, on this device,
/// and asleep until the player turns it on.
@Observable
@MainActor
final class FixtureStore {
    static let shared = FixtureStore()

    enum Access { case notAsked, denied, granted }

    private(set) var access: Access = .notAsked
    private(set) var calendarIDs: Set<String>
    /// Soonest first, from a week ago to two months ahead.
    private(set) var fixtures: [Fixture] = []
    private(set) var hasLoaded = false
    var isInvitationDismissed: Bool {
        didSet { AppGroup.defaults.set(isInvitationDismissed, forKey: Key.invitationDismissed) }
    }

    @ObservationIgnored let eventStore = EKEventStore()
    @ObservationIgnored private var changes: Task<Void, Never>?

    private enum Key {
        static let calendars = "fixtureCalendarIDs"
        static let invitationDismissed = "fixtureInvitationDismissed"
    }

    private init() {
        calendarIDs = Set(AppGroup.defaults.stringArray(forKey: Key.calendars) ?? [])
        isInvitationDismissed = AppGroup.defaults.bool(forKey: Key.invitationDismissed)
        readAccess()
        if isConnected { Task { await refresh() } }
        changes = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                await self?.refresh()
            }
        }
    }

    /// Whether the player has picked a calendar we can still read.
    var isConnected: Bool { access == .granted && !calendarIDs.isEmpty }

    /// The next match that hasn't finished.
    var next: Fixture? { fixtures.first { $0.end > Date() } }

    var upcoming: [Fixture] { fixtures.filter { $0.end > Date() } }

    /// The fixture a finished recording belongs to. Its `opponent` is a suggestion: let the player confirm it.
    func suggestion(forMatchFrom start: Date, to end: Date, at coordinate: Coordinate2D? = nil) -> Fixture? {
        FixtureMatcher.fixture(forMatchFrom: start, to: end, at: coordinate, among: fixtures)
    }

    // MARK: Connecting

    /// Asks for calendar access. Call only from a tap.
    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        readAccess()
    }

    func choose(_ calendars: Set<EKCalendar>) async {
        calendarIDs = Set(calendars.map(\.calendarIdentifier))
        AppGroup.defaults.set(Array(calendarIDs), forKey: Key.calendars)
        await refresh()
    }

    var chosenCalendars: Set<EKCalendar> {
        Set(calendarIDs.compactMap(eventStore.calendar(withIdentifier:)))
    }

    private func readAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notAsked
        // Write-only can't see events either.
        default: access = .denied
        }
    }

    // MARK: Reading

    func refresh() async {
        readAccess()
        let calendars = access == .granted ? Array(chosenCalendars) : []
        guard !calendars.isEmpty else {
            fixtures = []
            return
        }
        let now = Date()
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-7 * 86_400),
                                                      end: now.addingTimeInterval(60 * 86_400), calendars: calendars)
        let store = eventStore
        let events = await Task.detached(priority: .userInitiated) {
            store.events(matching: predicate).map(CalendarEvent.init)
        }.value
        fixtures = FixtureParser.fixtures(in: events, teamNames: SettingsStore.shared.teamMemberships.compactMap(\.name))
        hasLoaded = true
    }
}

private extension CalendarEvent {
    init(_ event: EKEvent) {
        let place = event.structuredLocation?.geoLocation?.coordinate
        self.init(
            // Repeats share an identifier; the start tells them apart.
            id: "\(event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "",
            location: event.structuredLocation?.title ?? event.location,
            coordinate: place.map { Coordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
            start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, isCanceled: event.status == .canceled)
    }
}
