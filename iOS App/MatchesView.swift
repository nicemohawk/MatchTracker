import SwiftUI

struct MatchesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Matches Yet",
                systemImage: "figure.soccer",
                description: Text("Recorded matches from your Apple Watch will appear here.")
            )
            .navigationTitle("Matches")
        }
    }
}

#Preview {
    MatchesView()
}
