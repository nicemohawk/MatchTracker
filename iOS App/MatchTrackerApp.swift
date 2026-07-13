import SwiftUI

@main
struct MatchTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            MatchesView()
                .tabItem {
                    Label("Matches", systemImage: "figure.soccer")
                }
            FieldsView()
                .tabItem {
                    Label("Fields", systemImage: "map")
                }
            TeamView()
                .tabItem {
                    Label("Team", systemImage: "person.3")
                }
        }
    }
}

#Preview {
    RootTabView()
}
