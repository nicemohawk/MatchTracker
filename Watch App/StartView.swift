import SwiftUI

struct StartView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Button {
                    // STUB: start a match workout session.
                } label: {
                    Label("Start Match", systemImage: "figure.soccer")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)

                Text("Field auto-detect: none")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("MatchTracker")
        }
    }
}

#Preview {
    StartView()
}
