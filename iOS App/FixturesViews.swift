// FixturesViews.swift
// MatchTracker

import EventKitUI
import MapKit
import SwiftUI
import MatchTrackerKit

// MARK: - Next match

/// The next match, for the Summary screen. Draws its content only; put it in whatever group the
/// screen uses. Before a calendar is chosen it's a quiet offer that can be turned down for good.
struct NextMatchCard: View {
    var store: FixtureStore = .shared

    @EnvironmentObject private var fields: FieldsModel

    /// Lets the host leave the whole group out when there's nothing to say.
    @MainActor static var hasContent: Bool {
        let store = FixtureStore.shared
        return store.isConnected ? store.next != nil : !store.isInvitationDismissed
    }

    var body: some View {
        Group {
            if store.isConnected {
                if let fixture = store.next {
                    next(fixture)
                }
            } else if !store.isInvitationDismissed {
                invitation
            }
        }
    }

    private func next(_ fixture: Fixture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Next match, \(fixture.relativeDay)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(fixture.displayTitle)
                .font(.title2.bold())
            Text(fixture.start, format: .dateTime.weekday(.wide).month().day().hour().minute())
                .font(.body)
            FixturePlace(fixture: fixture, field: fixture.field(among: fields.fields))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("See your next match here")
                .font(.headline)
            Text("Choose the calendar your fixtures are in. Teams on TeamSnap or Spond can add theirs to Calendar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { invitationButtons }
                VStack(alignment: .leading, spacing: 8) { invitationButtons }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var invitationButtons: some View {
        ChooseCalendarButton(store: store)
            .buttonStyle(.bordered)
        Button("Not Now") { withAnimation { store.isInvitationDismissed = true } }
            .buttonStyle(.borderless)
            .tint(.secondary)
    }
}

/// Where it is, opening Maps: the name of a field we know, else the calendar's own words.
private struct FixturePlace: View {
    let fixture: Fixture
    let field: FieldModel?

    private var coordinate: Coordinate2D? { field?.rectangle.center ?? fixture.coordinate }

    var body: some View {
        if let name = field?.name ?? fixture.location {
            if let coordinate {
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude)))
                    item.name = name
                    item.openInMaps()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin")
                        Text(name).multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens in Maps")
            } else {
                Text(name)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Fixture {
    /// "Rovers FC, away", or the calendar's own title when we can't read an opponent out of it.
    var displayTitle: String {
        guard let opponent else { return title }
        switch venue {
        case .away: return "\(opponent), away"
        case .home: return "\(opponent), home"
        case nil: return "vs \(opponent)"
        }
    }

    var relativeDay: String {
        if start <= Date() { return "now" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: start)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}

// MARK: - Opponent suggestion

/// "Rovers FC? From your calendar." One tap fills the opponent of a match just played.
struct OpponentSuggestionButton: View {
    let start: Date
    let end: Date
    var coordinate: Coordinate2D?
    var store: FixtureStore = .shared
    let onAccept: (String) -> Void

    var body: some View {
        if let opponent = store.suggestion(forMatchFrom: start, to: end, at: coordinate)?.opponent {
            Button { onAccept(opponent) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Was it \(opponent)?")
                    Text("From your calendar").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
        }
    }
}

// MARK: - Fixtures page

struct FixturesListView: View {
    var store: FixtureStore = .shared

    @EnvironmentObject private var fields: FieldsModel

    var body: some View {
        Group {
            if !store.isConnected {
                ContentUnavailableView {
                    Label("Your fixtures, from Calendar", systemImage: "calendar")
                } description: {
                    if store.access == .denied {
                        Text("Calendar access is off for MatchTracker. Turn on full access in Settings to see your fixtures.")
                    } else {
                        Text("Choose the calendar your matches are in. Teams on TeamSnap or Spond can add theirs to Calendar. MatchTracker only reads it, and nothing leaves this device.")
                    }
                } actions: {
                    ChooseCalendarButton(store: store)
                        .buttonStyle(.prominentAction)
                }
            } else if store.upcoming.isEmpty && store.hasLoaded {
                ContentUnavailableView {
                    Label("No matches coming up", systemImage: "calendar")
                } description: {
                    Text("Nothing in the next two months of \(calendarNames) looks like a match.")
                } actions: {
                    ChooseCalendarButton(store: store, title: "Choose Another Calendar")
                        .buttonStyle(.bordered)
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fixtures")
        .task { await store.refresh() }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.upcoming) { fixture in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fixture.displayTitle).font(.headline)
                        Text(fixture.start, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                        FixturePlace(fixture: fixture, field: fixture.field(among: fields.fields))
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("From \(calendarNames).")
            }
            Section {
                ChooseCalendarButton(store: store, title: "Change Calendars")
                Button("Stop Using Calendar") { Task { await store.choose([]) } }
            } footer: {
                Text("Nothing is deleted from your calendar.")
            }
        }
        .readableFormWidth()
        .refreshable { await store.refresh() }
    }

    private var calendarNames: String {
        store.chosenCalendars.map(\.title).sorted().formatted()
    }
}

// MARK: - Choosing a calendar

/// Asks for access if needed, then shows the system's calendar chooser.
struct ChooseCalendarButton: View {
    var store: FixtureStore = .shared
    var title = "Choose a Calendar"

    @Environment(\.openURL) private var openURL
    @State private var isChoosing = false

    var body: some View {
        if store.access == .denied {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } else {
            Button(title) {
                Task {
                    if store.access == .notAsked { await store.requestAccess() }
                    isChoosing = store.access == .granted
                }
            }
            .sheet(isPresented: $isChoosing) {
                CalendarChooser(store: store).ignoresSafeArea()
            }
        }
    }
}

private struct CalendarChooser: UIViewControllerRepresentable {
    let store: FixtureStore

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let chooser = EKCalendarChooser(selectionStyle: .multiple, displayStyle: .allCalendars, entityType: .event,
                                        eventStore: store.eventStore)
        chooser.title = "Calendars with Your Matches"
        chooser.showsDoneButton = true
        chooser.showsCancelButton = true
        chooser.selectedCalendars = store.chosenCalendars
        chooser.delegate = context.coordinator
        return UINavigationController(rootViewController: chooser)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.dismiss = dismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store, dismiss: dismiss) }

    final class Coordinator: NSObject, EKCalendarChooserDelegate {
        let store: FixtureStore
        var dismiss: DismissAction

        init(store: FixtureStore, dismiss: DismissAction) {
            self.store = store
            self.dismiss = dismiss
        }

        func calendarChooserDidFinish(_ chooser: EKCalendarChooser) {
            let calendars = chooser.selectedCalendars
            Task { @MainActor in
                await store.choose(calendars)
                dismiss()
            }
        }

        func calendarChooserDidCancel(_ chooser: EKCalendarChooser) {
            dismiss()
        }
    }
}
