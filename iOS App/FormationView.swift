//
//  FormationView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Backend-computed team formation over recent matches, rendered on the app's canonical pitch
/// (`SoccerPitch`). A team-features screen: callers gate entry behind the entitlement.
struct FormationView: View {
    let teamCode: String
    @EnvironmentObject private var uploads: UploadService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                FormationSkeleton()
            case .loaded(let formation):
                formationContent(formation)
            case .insufficientData:
                ContentUnavailableView {
                    Label("Formation Unavailable Yet", systemImage: "square.grid.3x3.middle.filled")
                } description: {
                    Text("Team formation is computed from uploaded matches. Once at least 5 teammates have uploaded recent matches, their average shape appears here.")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Formation", systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Formation")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.background.ignoresSafeArea())
        .task { await load() }
        .refreshable { await load() }
    }

    private func formationContent(_ formation: TeamFormation) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formation.name)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.turf)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Confidence").captionLabel()
                        Text("\(Int(formation.confidence * 100))%")
                            .font(.system(.title3, design: .rounded).bold())
                            .monospacedDigit()
                            .foregroundStyle(formation.confidence > 0.6 ? Theme.turf : Theme.bench)
                    }
                }

                FormationPitch(formation: formation, reduceMotion: reduceMotion)
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                    )

                legend

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(formation.slots, id: \.playerName) { slot in
                        HStack(spacing: 10) {
                            Circle().fill(RosterAvatar.tint(for: slot.playerName))
                                .frame(width: 8, height: 8)
                            Text(slot.playerName)
                            Spacer()
                            Text(slot.role.capitalized)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .themedCard(cornerRadius: 16)
            }
            .padding()
        }
    }

    /// A quiet legend explaining how to read the markers.
    private var legend: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Each marker is a player's average position over recent matches. Ring strength reflects confidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func load() async {
        state = .loading
        do {
            let formation = try await uploads.fetchFormation(code: teamCode)
            state = .loaded(formation)
        } catch let error as APIError {
            // The backend answers 404 insufficient_data when < 5 players qualify (or the endpoint
            // doesn't exist yet on older backends).
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

// MARK: - Formation pitch

/// The canonical pitch surface with player markers overlaid as SwiftUI views (so each can play a
/// staggered pop-in entrance). Marker positions are derived from the same `SoccerPitch.fittedRect`
/// the canvas uses, keeping dots exactly on the drawn turf.
private struct FormationPitch: View {
    let formation: TeamFormation
    let reduceMotion: Bool
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let rect = SoccerPitch.fittedRect(in: geometry.size, padding: 6)
            ZStack {
                Canvas { context, size in
                    let rect = SoccerPitch.fittedRect(in: size, padding: 6)
                    SoccerPitch.fillTurf(&context, rect: rect)
                    var markings = context
                    SoccerPitch.draw(in: &markings, rect: rect)
                }

                ForEach(Array(formation.slots.enumerated()), id: \.element.playerName) { index, slot in
                    FormationMarker(name: slot.playerName, confidence: formation.confidence)
                        .position(
                            x: rect.minX + CGFloat(slot.x) * rect.width,
                            y: rect.minY + CGFloat(slot.y) * rect.height
                        )
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.2)
                        .opacity(appeared || reduceMotion ? 1 : 0)
                        .animation(
                            reduceMotion
                                ? nil
                                : .spring(response: 0.45, dampingFraction: 0.7)
                                    .delay(Double(index) * 0.05),
                            value: appeared
                        )
                }
            }
        }
        .onAppear { appeared = true }
    }
}

/// A single player's mean-position marker: initials in an accent-tinted disc with a confidence
/// ring. Tint is the deterministic `RosterAvatar` hash, matching avatars everywhere else.
private struct FormationMarker: View {
    let name: String
    let confidence: Double

    var body: some View {
        let tint = RosterAvatar.tint(for: name)
        Text(RosterAvatar.initials(from: name))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 32, height: 32)
            .background(Circle().fill(tint))
            .overlay(
                Circle().strokeBorder(.white.opacity(0.25 + 0.6 * confidence), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Skeleton

/// Pitch-shaped placeholder shown while the formation loads: the real turf with a few shimmering
/// marker discs, so the wait reads as "computing your shape" rather than a bare spinner.
private struct FormationSkeleton: View {
    // A rough, symmetric scatter that hints at a formation without implying real positions.
    private let sample: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.5),
        CGPoint(x: 0.28, y: 0.22), CGPoint(x: 0.28, y: 0.5), CGPoint(x: 0.28, y: 0.78),
        CGPoint(x: 0.52, y: 0.3), CGPoint(x: 0.52, y: 0.7),
        CGPoint(x: 0.74, y: 0.35), CGPoint(x: 0.74, y: 0.65)
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceElevated)
                    .frame(width: 120, height: 44)
                Spacer()
                RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceElevated)
                    .frame(width: 60, height: 30)
            }

            GeometryReader { geometry in
                let rect = SoccerPitch.fittedRect(in: geometry.size, padding: 6)
                ZStack {
                    Canvas { context, size in
                        let rect = SoccerPitch.fittedRect(in: size, padding: 6)
                        SoccerPitch.fillTurf(&context, rect: rect)
                        var markings = context
                        SoccerPitch.draw(in: &markings, rect: rect)
                    }
                    ForEach(Array(sample.enumerated()), id: \.offset) { _, point in
                        Circle().fill(Color.white.opacity(0.18))
                            .frame(width: 30, height: 30)
                            .position(x: rect.minX + point.x * rect.width,
                                      y: rect.minY + point.y * rect.height)
                    }
                }
            }
            .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
            .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding()
        .redacted(reason: .placeholder)
        .formationShimmer()
    }
}

// MARK: - Shimmer

private struct FormationShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 1.5)
                    .offset(x: phase * geometry.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func formationShimmer() -> some View { modifier(FormationShimmer()) }
}
