import SwiftUI

struct TeamView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Team",
                systemImage: "person.3",
                description: Text("Enter a team code in Settings to see roster stats.")
            )
            .navigationTitle("Team")
        }
    }
}

#Preview {
    TeamView()
}
