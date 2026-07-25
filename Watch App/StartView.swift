//
//  StartView.swift
//  MatchTracker
//

import SwiftUI
import CoreLocation
import MatchTrackerKit

/// The workout start screen: a big green Start Match button, live field auto-detect status,
/// a Train Field entry point and the team code mirrored from the phone.
struct StartView: View {
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(ConnectivityManager.self) private var connectivity
    @State private var fieldDetector = StartFieldDetector()

    /// The quick-pick match format. Seeded from the last-used choice and auto-suggested to
    /// Pickup on small fields, but an explicit tap always wins and persists.
    @State private var selectedFormat = WatchSettings.matchFormat
    @State private var userDidChooseFormat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // A failed start bounces back here — without a reason it reads as "the
                    // countdown just never switched".
                    if let failure = workoutManager.startFailureMessage {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.heart)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        WatchHaptics.click()
                        workoutManager.matchFormat = selectedFormat
                        workoutManager.detectedField = fieldDetector.matchedField
                        workoutManager.phase = .countdown
                    } label: {
                        Label("Start Match", systemImage: "figure.soccer")
                            .font(.headline)
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 52, prominent: true))

                    formatPicker

                    fieldStatusLine

                    NavigationLink {
                        FieldTrainingView()
                    } label: {
                        Label("Train Field", systemImage: "map")
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.pace, minHeight: 44))

                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 44))

                    if WatchSettings.refereeMode {
                        Label("Referee mode", systemImage: "rectangle.portrait.fill")
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.cardYellow)
                    }

                    if let teamCode = connectivity.teamCode, !teamCode.isEmpty {
                        Label(teamCode, systemImage: "person.3")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Build stamp: the one-glance answer to "is the new build actually on the
                    // watch?" — the phone→watch install hop fails silently often enough that
                    // this has to be visible on-device.
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("MatchTracker")
        }
        .task(id: connectivity.fieldsRevision) {
            fieldDetector.detect()
        }
        .onChange(of: fieldDetector.matchedField) { _, field in
            // Auto-suggest Pickup for small fields, once per detection — unless the user has
            // already made an explicit choice, which always wins.
            guard !userDidChooseFormat, let field else { return }
            if field.rectangle.lengthMeters < 75 {
                selectedFormat = .smallSided
            }
        }
    }

    /// Compact Match / Pickup / Indoor selector under the Start button.
    private var formatPicker: some View {
        HStack(spacing: 4) {
            ForEach(MatchFormat.allCases, id: \.self) { format in
                formatChip(format)
            }
        }
    }

    private func formatChip(_ format: MatchFormat) -> some View {
        let isSelected = selectedFormat == format
        let tint = isSelected ? WatchTheme.turf : WatchTheme.bench
        return Button {
            WatchHaptics.click()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedFormat = format
            }
            userDidChooseFormat = true
            WatchSettings.matchFormat = format
        } label: {
            VStack(spacing: 3) {
                Image(systemName: format.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                Text(format.shortTitle)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isSelected ? WatchTheme.turf : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                if isSelected {
                    shape.fill(WatchTheme.chipFill(tint))
                    shape.strokeBorder(WatchTheme.chipStroke(tint), lineWidth: 1)
                } else {
                    shape.fill(WatchTheme.surface)
                    shape.strokeBorder(WatchTheme.surfaceStroke, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var fieldStatusLine: some View {
        let matched = fieldDetector.matchedField != nil
        return HStack(spacing: 5) {
            Image(systemName: matched ? "mappin.and.ellipse" : "location.slash")
            Text(fieldDetector.statusText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(matched ? WatchTheme.turf : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// One-shot location lookup that names the best-matching known field for the start screen.
@Observable
final class StartFieldDetector: NSObject, CLLocationManagerDelegate {
    var matchedField: FieldModel?
    var statusText = "Locating field…"

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
            statusText = "Location off"
        default:
            locationManager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let samples = [Coordinate2D(latitude: location.coordinate.latitude,
                                    longitude: location.coordinate.longitude)]
        if let field = AppGroupStorage.fieldStore.bestMatch(for: samples) {
            matchedField = field
            statusText = "Playing at: \(field.name)"
        } else {
            matchedField = nil
            statusText = "No field matched"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "No field matched"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

/// Start-screen presentation for the match-format quick pick.
private extension MatchFormat {
    var shortTitle: String {
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
