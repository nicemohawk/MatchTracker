//
//  FormationView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Backend-computed team formation over recent matches, rendered on a pitch. A team-features
/// screen: callers gate entry behind the entitlement.
struct FormationView: View {
    let teamCode: String
    @EnvironmentObject private var uploads: UploadService

    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case loaded(TeamFormation)
        case insufficientData
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            case .loaded(let formation):
                formationContent(formation)
            case .insufficientData:
                ContentUnavailableView(
                    "Not Enough Data",
                    systemImage: "square.grid.3x3.middle.filled",
                    description: Text("Formation detection needs recent matches from at least 5 teammates. Keep uploading!")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't Load Formation",
                    systemImage: "wifi.slash",
                    description: Text(message)
                )
            }
        }
        .navigationTitle("Formation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func formationContent(_ formation: TeamFormation) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text(formation.name)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Confidence")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(formation.confidence * 100))%")
                            .font(.title3.bold())
                            .foregroundStyle(formation.confidence > 0.6 ? .green : .orange)
                    }
                }

                formationPitch(formation)
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .background(Color.green.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(formation.slots, id: \.playerName) { slot in
                        HStack {
                            Text(slot.playerName)
                            Spacer()
                            Text(slot.role.capitalized)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }

    private func formationPitch(_ formation: TeamFormation) -> some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 6)
            context.fill(Path(rect), with: .color(Color(red: 0.20, green: 0.55, blue: 0.25)))
            var markings = context
            SoccerPitch.draw(in: &markings, rect: rect, lineColor: .white.opacity(0.9))

            for slot in formation.slots {
                let point = CGPoint(x: rect.minX + CGFloat(slot.x) * rect.width,
                                    y: rect.minY + CGFloat(slot.y) * rect.height)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                             with: .color(.blue))
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                               with: .color(.white), lineWidth: 1.5)
                let label = Text(initials(slot.playerName)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                context.draw(context.resolve(label), at: point)
            }
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    private func load() async {
        do {
            let formation = try await uploads.fetchFormation(code: teamCode)
            state = .loaded(formation)
        } catch let error as APIError {
            // The backend answers 404 insufficient_data when < 5 players qualify.
            if case .httpStatus(let status) = error, status == 404 {
                state = .insufficientData
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
