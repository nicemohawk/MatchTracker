// FieldBoundsEditor.swift
// MatchTracker
//
// The single field-boundary editor, unifying what were two implementations. Its draggable-handle
// approach is lifted from Add Field's adjust phase (the good one): a live satellite Map with the
// four corners as a SIBLING handle overlay (positions from `proxy.convert`, re-derived each camera
// frame), so a handle's drag never fights the map's pan. Dragging updates local @State ONLY; the
// oriented rectangle is refit — and, for a saved field, persisted — on drag END / Save, never per
// frame. Replaces `CornerEditorView` (now a thin wrapper) everywhere it was used.
//
// White-screen fix: the old corner editor mounted a Metal-backed imagery Map inside a
// fullScreenCover before layout gave it a size ("CAMetalLayer ignoring invalid setDrawableSize
// 0x0"), so it rendered blank until an app-switch. Here the Map is created only AFTER a first
// non-zero geometry (see `MapMountGate`), and callers present it as a large sheet, so it renders
// on first present.

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// Adjust a saved field's four corners on satellite imagery and persist the correction as a
/// high-weight trained observation. Reusable: `CornerEditorView` wraps this, and the match screen
/// presents it directly as a sheet.
struct FieldBoundsEditor: View {
    let field: FieldModel
    /// The match's raw GPS route, when the editor is opened from a match's analysis — drawn under
    /// the correction so corners can be aligned against where play actually happened. Empty when
    /// editing from the Fields tab (no match context).
    var route: [CLLocationCoordinate2D] = []
    /// Called after a successful save (the caller dismisses / reprojects).
    var onSaved: () -> Void

    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    @State private var corners: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition
    /// Bumped continuously while the camera moves so the handle overlay (positions from
    /// `proxy.convert`) re-renders in lockstep with the map. A reference held in plain `@State`
    /// (NOT `@StateObject`) on purpose: only `CameraTrackedHandles` observes it, so the per-frame
    /// bumps re-render just the handle overlay — never this body, whose Map content and
    /// `fittedRectangle` refit depend only on `corners`.
    @State private var cameraTicker = CameraTicker()
    @State private var grabbedCorner: Int?

    private final class CameraTicker: ObservableObject {
        @Published var tick = 0
        /// Latest visible region, tracked for the zoom buttons. Deliberately NOT @Published —
        /// it updates every camera frame and must not invalidate anything.
        var region: MKCoordinateRegion?
    }

    /// Hosts the corner handles behind the ticker so continuous pan/zoom invalidates only this
    /// subtree, keeping the editor body untouched during camera moves.
    private struct CameraTrackedHandles: View {
        @ObservedObject var ticker: CameraTicker
        @Binding var corners: [CLLocationCoordinate2D]
        @Binding var grabbedCorner: Int?
        let proxy: MapProxy
        let coordinateSpaceName: String

        var body: some View {
            FieldCornerHandles(corners: $corners, grabbedCorner: $grabbedCorner,
                               proxy: proxy, coordinateSpaceName: coordinateSpaceName,
                               cameraTick: ticker.tick)
        }
    }

    init(field: FieldModel, route: [CLLocationCoordinate2D] = [], onSaved: @escaping () -> Void) {
        self.field = field
        self.route = route
        self.onSaved = onSaved
        _cameraPosition = State(initialValue: .region(field.rectangle.mapRegion))
    }

    private static let mapSpace = "fieldBoundsMap"

    /// Live oriented rectangle refit from the current corners — the dashed correction preview. This
    /// is the SAME fit Add Field applies (`FieldGeometry.fitOrientedRectangle`), so a nudge here and
    /// a placement there converge on identical geometry.
    private var fittedRectangle: OrientedRectangle? {
        guard corners.count == 4 else { return nil }
        return FieldGeometry.fitOrientedRectangle(to: corners.map(Coordinate2D.init))
    }

    var body: some View {
        MapMountGate {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    // Match route under everything: the evidence to align the corners against.
                    if route.count > 1 {
                        MapPolyline(coordinates: route)
                            .stroke(Theme.signal.opacity(0.65),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                    if corners.count >= 3 {
                        MapPolygon(coordinates: corners)
                            .foregroundStyle(Theme.turf.opacity(0.15))
                            .stroke(Theme.turf, lineWidth: 2)
                    }
                    if let fittedRectangle {
                        MapPolygon(coordinates: fittedRectangle.coordinateRing)
                            .foregroundStyle(Theme.turf.opacity(0.12))
                            .stroke(Theme.turf, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .mapStyle(.imagery)
                .mapControls { }
                .onMapCameraChange(frequency: .continuous) { context in
                    cameraTicker.region = context.region
                    cameraTicker.tick &+= 1
                }
                // Sibling overlay (not annotations) so a handle drag never fights the map pan.
                .overlay {
                    CameraTrackedHandles(ticker: cameraTicker, corners: $corners,
                                         grabbedCorner: $grabbedCorner, proxy: proxy,
                                         coordinateSpaceName: Self.mapSpace)
                }
                .coordinateSpace(name: Self.mapSpace)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) { guidanceBar }
        // Zoom + frame controls, matching the Fields/Add Field control-column idiom. Corner
        // placement is fine motor work — pinch alone (fighting the handle grab targets) isn't
        // enough to get the imagery close.
        .overlay(alignment: .topTrailing) { controlColumn }
        .navigationTitle("Adjust Field")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { if corners.isEmpty { corners = field.rectangle.corners.map(\.clCoordinate) } }
    }

    private var controlColumn: some View {
        VStack(spacing: 12) {
            mapControlButton("square.dashed", label: "Frame the field") {
                withAnimation(.easeInOut(duration: 0.35)) {
                    cameraPosition = .region(field.rectangle.mapRegion)
                }
                Haptics.selection()
            }
            mapControlButton("plus.magnifyingglass", label: "Zoom in") { zoom(by: 0.5) }
            mapControlButton("minus.magnifyingglass", label: "Zoom out") { zoom(by: 2) }
        }
        .padding(.trailing, 14)
        .padding(.top, 12)
    }

    private func mapControlButton(_ systemImage: String,
                                  label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .modifier(AddFieldControlGlass())
        .accessibilityLabel(label)
    }

    private func zoom(by factor: Double) {
        let region = cameraTicker.region ?? field.rectangle.mapRegion
        // Effectively uncapped zoom-in (~4 m of latitude) — MapKit clamps to the imagery's own
        // limit. Placing a corner on the flag needs all the closeness the tiles can give.
        let minSpan = 0.00004
        let maxSpan = 0.05
        let zoomed = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: min(max(region.span.latitudeDelta * factor, minSpan), maxSpan),
                longitudeDelta: min(max(region.span.longitudeDelta * factor, minSpan), maxSpan)
            )
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(zoomed)
        }
        cameraTicker.region = zoomed
        Haptics.selection()
    }

    /// A dark guidance bar over the imagery: what to do, plus a turf Save capsule.
    private var guidanceBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.turf)
                Text(grabbedCorner == nil
                     ? "Drag any of the four corners to match the pitch."
                     : "Corner \((grabbedCorner ?? 0) + 1) of 4")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            Button { save() } label: {
                Text("Save Corrections")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.turf)
            .clipShape(Capsule())
            .disabled(fittedRectangle == nil)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// Refit the rectangle from the corrected corners and persist. Saving records a high-weight
    /// trained observation (the correction), matching Add Field and the old corner editor.
    private func save() {
        guard let rectangle = fittedRectangle else { return }
        var updated = field
        updated.rectangle = rectangle
        updated.outline = corners.map(Coordinate2D.init)
        updated.source = .trained
        updated.observationCount += 1
        fields.save(updated)
        Haptics.impact(.medium)
        dismiss()
        onSaved()
    }
}

/// The shared draggable-corner overlay used by BOTH this editor and Add Field's adjust phase. Each
/// corner is positioned from `proxy.convert` every camera frame (`cameraTick` forces the refresh)
/// and carries a drag gesture in the map's named coordinate space, so touches on a handle stop at
/// the handle and everywhere else falls through to the map. Dragging writes ONLY to the local
/// `corners` binding — no camera move, no store write — which is what keeps it smooth.
struct FieldCornerHandles: View {
    @Binding var corners: [CLLocationCoordinate2D]
    @Binding var grabbedCorner: Int?
    let proxy: MapProxy
    let coordinateSpaceName: String
    /// Read (below) purely to re-evaluate this overlay while the camera moves.
    let cameraTick: Int

    var body: some View {
        if corners.count == 4 {
            ZStack {
                let _ = cameraTick
                ForEach(Array(corners.enumerated()), id: \.offset) { index, coordinate in
                    if let point = proxy.convert(coordinate, to: .local) {
                        handle(index: index)
                            .position(point)
                            .gesture(
                                DragGesture(minimumDistance: 0,
                                            coordinateSpace: .named(coordinateSpaceName))
                                    .onChanged { value in
                                        if grabbedCorner != index {
                                            grabbedCorner = index
                                            Haptics.selection()
                                        }
                                        if let moved = proxy.convert(value.location, from: .local) {
                                            corners[index] = moved
                                        }
                                    }
                                    .onEnded { _ in grabbedCorner = nil }
                            )
                    }
                }
            }
            .allowsHitTesting(true)
        }
    }

    private func handle(index: Int) -> some View {
        ZStack {
            Circle().fill(Theme.turf.opacity(grabbedCorner == index ? 0.45 : 0.28))
            Circle().strokeBorder(Theme.turf, lineWidth: 2)
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 1)
        }
        .frame(width: 34, height: 34)
        .scaleEffect(grabbedCorner == index ? 1.25 : 1)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        // A generous grab target beyond the visible circle — corners are fine-motor targets.
        .contentShape(Circle().inset(by: -12))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: grabbedCorner)
        .accessibilityLabel("Corner \(index + 1) — drag to adjust")
    }
}

/// Defers building a Metal-backed Map until layout has handed down a first non-zero size, so the
/// map never initializes against a 0×0 drawable (the blank-until-app-switch bug when presented in
/// a cover). `GeometryReader` reports the real size on the first layout pass, so the gated content
/// mounts on first present with a valid surface.
struct MapMountGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > 1, geometry.size.height > 1 {
                content()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Theme.background
            }
        }
    }
}
