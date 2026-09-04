// FieldsMapChrome.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// Shared layout constants and floating chrome for the Fields map (`FieldsView`). Every floating
/// element is a standard control on glass — no custom drawer — so the map stays the hero and the
/// tab bar below stays visible and tappable.
enum FieldsChrome {
    /// On iOS 26 the floating Liquid Glass tab bar does NOT contribute a bottom safe-area inset
    /// (content flows beneath it), so bottom-anchored chrome lifts itself clear of the pills
    /// explicitly. Pre-26 the tab bar insets normally and the safe area already covers it.
    static var tabBarAllowance: CGFloat {
        if #available(iOS 26.0, *) { return 70 } else { return 0 }
    }

    /// What a bottom-anchored floating control pads to clear the tab bar plus a small breathing gap.
    static var bottomClearance: CGFloat { tabBarAllowance + 14 }
}

// MARK: - Glass surfaces

/// Liquid Glass circle on iOS 26; `.ultraThinMaterial` fallback earlier. Used by the trailing map
/// control column so each button matches the app's glass language.
struct MapControlGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.surfaceStroke, lineWidth: 1))
        }
    }
}

/// Liquid Glass capsule on iOS 26; material fallback earlier. Used by the floating list pill and the
/// secondary Scan action so they read clearly in both light and dark over satellite imagery.
struct MapCapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 1))
        }
    }
}

// MARK: - One-shot location

/// A tiny one-shot location provider so the trailing "locate" control can recenter the camera on the
/// user, requesting when-in-use access the first time if needed. Mirrors `NearbyFieldSeeder`'s
/// delegate pattern without reaching into it, so the two never fight over a single manager.
@MainActor
@Observable
final class MapLocationProvider: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    @ObservationIgnored private var wantsLocation = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Request when-in-use access if it hasn't been decided yet (so the map's user-location dot and
    /// the locate control have something to work with).
    func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Resolve the current coordinate once, requesting authorization first if undecided. Returns nil
    /// if access is denied or the fix fails.
    func requestCurrentLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
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
            guard wantsLocation else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                wantsLocation = false
                manager.requestLocation()
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

// MARK: - Scan result banner

/// The outcome of a satellite scan, surfaced as a top banner so a scan is never silent.
enum ScanBanner: Equatable {
    case success(Int)
    case failure

    var isSuccess: Bool { if case .success = self { return true }; return false }
}

/// A glass banner that slides down from the top after a scan. Success invites a review tap; failure
/// explains the fix. Auto-dismissed by the caller (~4s); the whole banner is tappable on success.
struct ScanResultBanner: View {
    let banner: ScanBanner
    let onTap: () -> Void

    private var tint: Color {
        banner.isSuccess ? FieldSource.satellite.color : Theme.bench
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: banner.isSuccess ? "sparkle.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    // A LocalizedStringKey (not a String) so the `^[…](inflect:)` grammar agreement
                    // is parsed — passing a String would render the markup verbatim.
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if banner.isSuccess {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MapCapsuleGlass())
        }
        .buttonStyle(.plain)
        .disabled(!banner.isSuccess)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var title: LocalizedStringKey {
        switch banner {
        case .success(let count):
            return "^[\(count) possible pitch](inflect: true) found"
        case .failure:
            return "No pitches found in this view"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch banner {
        case .success:
            return "Tap to review and add them."
        case .failure:
            return "Zoom so one field fills the screen, or add it manually."
        }
    }

    private var accessibilityText: String {
        switch banner {
        case .success(let count):
            let noun = count == 1 ? "pitch" : "pitches"
            return "\(count) possible \(noun) found. Tap to review and add them."
        case .failure:
            return "No pitches found in this view. Zoom so one field fills the screen, or add it manually."
        }
    }
}

// MARK: - Empty state hint

/// A single compact invite floating above the action buttons when there are no fields yet. One card,
/// no nesting, dismissible — the caller remembers the dismissal via `@AppStorage`.
struct EmptyFieldsHint: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.turf)
                .frame(width: 26)
            Text("Walk a touchline or scan this view to add your first pitch.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss hint")
        }
        .padding(.vertical, 12)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .modifier(MapCapsuleGlass())
    }
}
