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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Button {
                        workoutManager.detectedField = fieldDetector.matchedField
                        workoutManager.phase = .countdown
                    } label: {
                        Label("Start Match", systemImage: "figure.soccer")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .tint(.green)

                    fieldStatusLine

                    NavigationLink {
                        FieldTrainingView()
                    } label: {
                        Label("Train Field", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.blue)

                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }

                    if WatchSettings.refereeMode {
                        Label("Referee mode", systemImage: "rectangle.portrait.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }

                    if let teamCode = connectivity.teamCode, !teamCode.isEmpty {
                        Label(teamCode, systemImage: "person.3")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("MatchTracker")
        }
        .task(id: connectivity.fieldsRevision) {
            fieldDetector.detect()
        }
    }

    private var fieldStatusLine: some View {
        HStack(spacing: 4) {
            Image(systemName: fieldDetector.matchedField == nil ? "location.slash" : "mappin.and.ellipse")
            Text(fieldDetector.statusText)
        }
        .font(.footnote)
        .foregroundStyle(fieldDetector.matchedField == nil ? Color.secondary : Color.green)
        .frame(maxWidth: .infinity, alignment: .leading)
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
