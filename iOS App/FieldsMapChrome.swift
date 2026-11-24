// FieldsMapChrome.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

// MARK: - One-shot location

/// Finds the player once, when they ask, requesting when-in-use access the first time.
@MainActor
@Observable
final class MapLocationProvider: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    @ObservationIgnored private var wantsLocation = false

    private(set) var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Nil if access is denied or no fix arrives.
    func requestCurrentLocation() async -> CLLocationCoordinate2D? {
        resume(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .notDetermined:
                wantsLocation = true
                manager.requestWhenInUseAuthorization()
            default:
                resume(nil)
            }
        }
    }

    private func resume(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = self.manager.authorizationStatus
            guard wantsLocation else { return }
            switch authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                wantsLocation = false
                self.manager.requestLocation()
            case .notDetermined:
                break
            default:
                wantsLocation = false
                resume(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in resume(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in resume(nil) }
    }
}

// MARK: - Satellite picture of a field

/// A still satellite picture of a field, turned so its long side runs left to right, with the
/// outline drawn on. A snapshot rather than a live map: lists can hold dozens.
struct FieldSatelliteImage: View {
    let rectangle: OrientedRectangle
    /// Dash the outline when it's a guess.
    var isGuess = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.pitchGradient
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: request(for: geometry.size)) {
                let request = request(for: geometry.size)
                guard request.size.width > 1, request.size.height > 1 else { return }
                if let rendered = await FieldSnapshotter.image(for: request) { image = rendered }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Satellite picture of the field")
    }

    private func request(for size: CGSize) -> FieldSnapshotter.Request {
        FieldSnapshotter.Request(rectangle: rectangle, size: size, scale: displayScale, isDashed: isGuess)
    }
}

@MainActor
enum FieldSnapshotter {
    struct Request: Equatable {
        let rectangle: OrientedRectangle
        let size: CGSize
        let scale: CGFloat
        let isDashed: Bool

        var cacheKey: NSString {
            let corners = rectangle.corners.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
            return "\(corners)|\(Int(size.width))x\(Int(size.height))@\(scale)|\(isDashed)" as NSString
        }
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(for request: Request) async -> UIImage? {
        if let cached = cache.object(forKey: request.cacheKey) { return cached }

        let options = MKMapSnapshotter.Options()
        options.size = request.size
        options.traitCollection = UITraitCollection(displayScale: request.scale)
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        options.camera = camera(for: request)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let outline = UIBezierPath()
        for (index, corner) in request.rectangle.coordinateRing.enumerated() {
            let point = snapshot.point(for: corner)
            if index == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
        }
        outline.close()
        outline.lineWidth = request.size.width > 120 ? 3 : 2
        outline.lineJoinStyle = .round
        if request.isDashed { outline.setLineDash([6, 4], count: 2, phase: 0) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = request.scale
        let rendered = UIGraphicsImageRenderer(size: request.size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1).setStroke()
            outline.stroke()
        }
        cache.setObject(rendered, forKey: request.cacheKey)
        return rendered
    }

    /// Straight down, long side across, with a margin around the field.
    private static func camera(for request: Request) -> MKMapCamera {
        let rectangle = request.rectangle
        let margin = 1.35
        let aspect = Double(request.size.width / max(request.size.height, 1))
        let visibleHeight = max(rectangle.lengthMeters * margin / aspect, rectangle.widthMeters * margin)
        // Of the two ways to lay the field flat, the one closer to north-up.
        let heading = rectangle.headingDegrees - 90
        // MapKit's camera sees 30° top to bottom.
        let distance = visibleHeight / 2 / tan(15 * Double.pi / 180)
        return MKMapCamera(lookingAtCenter: rectangle.center.clCoordinate, fromDistance: distance,
                           pitch: 0, heading: heading < 0 ? heading + 360 : heading)
    }
}
