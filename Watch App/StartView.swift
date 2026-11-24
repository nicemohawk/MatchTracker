//
//  StartView.swift
//  MatchTracker
//

import SwiftUI
import CoreLocation
import MatchTrackerKit

/// The start screen. One tap starts the match: each format is its own button, the one usually
/// played on this weekday first and largest.
struct StartView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(ConnectivityManager.self) private var connectivity
    @State private var fieldDetector = StartFieldDetector()

    private var likelyFormat: MatchFormat { WatchSettings.predictedFormat }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if let failure = workoutManager.startFailure {
                        startFailureCard(failure)
                    }
                    startButton(likelyFormat, prominent: true)
                    ForEach(MatchFormat.allCases.filter { $0 != likelyFormat }, id: \.self) { format in
                        startButton(format, prominent: false)
                    }

                    NavigationLink {
                        FieldTrainingView()
                    } label: {
                        Label("Train Field", systemImage: "map").font(.headline)
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.pace, minHeight: 52))
                    .padding(.top, 12)

                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape").font(.headline)
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 52))

                    // Build stamp: the one-glance answer to "is the new build actually on the
                    // watch?" — the phone→watch install hop fails silently often enough that
                    // this has to be visible on-device.
                    Text("v\(AppVersion.current)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .scenePadding(.horizontal)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(WatchSettings.refereeMode ? "Referee mode" : "MatchTracker")
        }
        .onAppear { workoutManager.routeRecorder.warmUp() }
        .task(id: connectivity.fieldsRevision) {
            fieldDetector.detect()
        }
    }

    private func startButton(_ format: MatchFormat, prominent: Bool) -> some View {
        Button {
            WatchHaptics.click()
            workoutManager.beginCountdown(field: fieldDetector.matchedField, format: format)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: format.symbolName)
                    .font(prominent ? .title : .title3)
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.startTitle)
                        .font(prominent ? .title3.weight(.bold) : .headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if prominent, let detail = readiness(for: format) {
                        Text(detail)
                            .font(.footnote.weight(.medium))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(WatchTileButtonStyle(tint: prominent ? WatchTheme.turf : WatchTheme.bench,
                                          minHeight: prominent ? 88 : 52, prominent: prominent))
        .accessibilityLabel("Start \(format.startTitle)")
        .accessibilityValue(prominent ? readiness(for: format) ?? "" : "")
    }

    /// Where, and whether GPS is ready — what's worth knowing before tapping.
    private func readiness(for format: MatchFormat) -> String? {
        guard format != .indoor else { return nil }
        let gps: String?
        switch workoutManager.routeRecorder.signal {
        case .good: gps = "GPS ready"
        case .acquiring, .lost: gps = "Finding GPS…"
        case .denied: gps = "Location is off"
        case .imprecise: gps = "Precise Location is off"
        case .off: gps = nil
        }
        return [fieldDetector.matchedField?.name, gps].compactMap { $0 }.joined(separator: " · ")
    }

    /// A failed start bounces back here — without a reason it reads as "the countdown just never
    /// switched". A card, not a wall of red text shoving the Start button off screen: what went
    /// wrong in the player's terms, HealthKit's own wording kept underneath for the log, and a
    /// dismiss so the screen returns to normal.
    private func startFailureCard(_ failure: WorkoutManager.StartFailure) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Couldn't start")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    WatchHaptics.click()
                    workoutManager.startFailure = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(WatchTheme.cardYellow)

            Text(failure.message)
                .font(.caption2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = failure.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape.fill(WatchTheme.chipFill(WatchTheme.cardYellow))
            shape.strokeBorder(WatchTheme.chipStroke(WatchTheme.cardYellow), lineWidth: 1)
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

/// One-shot location lookup that names the best-matching known field for the start screen.
@Observable
final class StartFieldDetector: NSObject, CLLocationManagerDelegate {
    var matchedField: FieldModel?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
    }

    func detect() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        default:
            locationManager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let samples = [Coordinate2D(latitude: location.coordinate.latitude,
                                    longitude: location.coordinate.longitude)]
        matchedField = AppGroupStorage.fieldStore.bestMatch(for: samples)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

/// Start-screen presentation for the match-format quick pick.
private extension MatchFormat {
    var startTitle: String {
        switch self {
        case .match: return "Match"
        case .smallSided: return "Pickup"
        case .indoor: return "Indoor"
        }
    }

    var symbolName: String {
        switch self {
        case .match: return "sportscourt"
        case .smallSided: return "figure.cooldown"
        case .indoor: return "house"
        }
    }
}
