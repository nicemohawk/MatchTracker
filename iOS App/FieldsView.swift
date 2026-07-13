import SwiftUI

struct FieldsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Fields Yet",
                systemImage: "map",
                description: Text("Trained fields will appear here on a map.")
            )
            .navigationTitle("Fields")
        }
    }
}

#Preview {
    FieldsView()
}
