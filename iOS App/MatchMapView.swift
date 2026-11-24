// MatchMapView.swift
// MatchTracker

import MapKit
import MatchTrackerKit
import SwiftUI

/// The route where it really happened.
struct MatchMapView: View {
    @ObservedObject var detail: MatchDetailModel
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if let rectangle = detail.analytics?.rectangle, rectangle.corners.count == 4 {
                    MapPolygon(coordinates: rectangle.corners.map(\.clCoordinate))
                        .foregroundStyle(.clear)
                        .stroke(.white.opacity(0.8), lineWidth: 2)
                }
                MapPolyline(coordinates: route)
                    .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .mapStyle(.imagery)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .navigationTitle(detail.analytics?.fieldName ?? "Map")
            .navigationBarTitleDisplayMode(.inline)
            .closeToolbar()
        }
    }

    /// A couple of thousand points draw smoothly; a whole match is six.
    private var route: [CLLocationCoordinate2D] {
        let step = max(1, detail.track.count / 2000)
        return stride(from: 0, to: detail.track.count, by: step).map { detail.track[$0].coordinate.clCoordinate }
    }
}
