//
//  CoachDashboardView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Sideline coach view: every rostered player's live position and vitals, polled from the team
/// live endpoint, plus this device's own stream. Optimized for iPad width via a split view;
/// still usable stacked on iPhone. Entitlement-gated by callers.
struct CoachDashboardView: View {
    let teamCode: String
    @EnvironmentObject private var uploads: UploadService
    @Environment(LiveMatchStore.self) private var liveMatches

    @State private var players: [LivePlayerStatus] = []
    @State private var selectedPlayerName: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            rosterList
                .navigationTitle("Live Team")
        } detail: {
            pitchDetail
        }
        .task { await pollLoop() }
    }

    // MARK: Roster

    private var rosterList: some View {
        List(selection: $selectedPlayerName) {
            if players.isEmpty {
                ContentUnavailableView(
                    "Waiting for Players",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(errorMessage ?? "Live positions appear when teammates start a match.")
                )
            }
            ForEach(players, id: \.playerName) { player in
                HStack {
                    Circle()
                        .fill(player.stale ? Color.gray : (player.onPitch ? Theme.turf : Theme.bench))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(player.playerName).font(.body)
                        HStack(spacing: 10) {
                            if let heartRate = player.heartRate {
                                Label("\(Int(heartRate))", systemImage: "heart.fill")
                            }
                            Label(String(format: "%.1f km", player.distanceMeters / 1000),
                                  systemImage: "figure.run")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .opacity(player.stale ? 0.45 : 1)
                .tag(player.playerName)
            }
        }
    }

    // MARK: Pitch

    private var pitchDetail: some View {
        VStack(spacing: 16) {
            Canvas { context, size in
                let rect = SoccerPitch.fittedRect(in: size, padding: 10)
                SoccerPitch.fillTurf(&context, rect: rect)
                var markings = context
                SoccerPitch.draw(in: &markings, rect: rect)

                for player in players {
                    guard let x = player.x, let y = player.y else { continue }
                    let point = CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                                        y: rect.minY + CGFloat(y) * rect.height)
                    let isSelected = player.playerName == selectedPlayerName
                    let radius: CGFloat = isSelected ? 11 : 8
                    let dotRect = CGRect(x: point.x - radius, y: point.y - radius,
                                         width: radius * 2, height: radius * 2)
                    let tint = player.stale ? Color.gray : (player.onPitch ? Theme.signal : Theme.bench)
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: tint.opacity(0.6), radius: 5))
                        layer.fill(Path(ellipseIn: dotRect), with: .color(tint))
                    }
                    if isSelected {
                        context.stroke(Path(ellipseIn: dotRect), with: .color(Theme.goal), lineWidth: 2.5)
                    }
                    let label = Text(initials(player.playerName))
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                    context.draw(context.resolve(label), at: point)
                }
            }
            .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
            .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            selectedTiles

            Spacer()
        }
        .padding(.vertical)
        .navigationTitle(teamCode)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var selectedTiles: some View {
        if let player = players.first(where: { $0.playerName == selectedPlayerName }) {
            HStack {
                StatTile(title: "HR", value: player.heartRate.map { "\(Int($0))" } ?? "—", systemImage: "heart.fill")
                StatTile(title: "Distance", value: String(format: "%.2f km", player.distanceMeters / 1000), systemImage: "figure.run")
                StatTile(title: "Status", value: player.onPitch ? "On pitch" : "Bench", systemImage: "sportscourt")
            }
            .padding(.horizontal)
        }
    }

    // MARK: Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func refresh() async {
        do {
            var fetched = try await uploads.fetchLiveTeam(code: teamCode)
            // Merge the local wearer's own live stream (fresher than the server round-trip).
            if liveMatches.isLive, let update = liveMatches.latest {
                let localName = SettingsStore.shared.playerName.isEmpty ? "Me" : SettingsStore.shared.playerName
                fetched.removeAll { $0.playerName == localName }
                fetched.append(LivePlayerStatus(
                    playerName: localName, updatedAt: update.timestamp,
                    x: nil, y: nil,
                    heartRate: update.heartRate, distanceMeters: update.distanceMeters,
                    onPitch: update.onPitch, stale: false
                ))
            }
            players = fetched.sorted { $0.playerName < $1.playerName }
            errorMessage = nil
        } catch {
            errorMessage = "Live feed unavailable: \(error.localizedDescription)"
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}
