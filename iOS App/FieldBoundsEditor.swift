// FieldBoundsEditor.swift
// MatchTracker
//
// The one outline editor, used to adjust a saved field, to draw a new one and to correct a detected
// one. Full-screen imagery with the four corners as a SIBLING handle overlay (positions from
// `proxy.convert`, re-derived each camera frame), so a handle's drag never fights the map's pan.
// Dragging writes local @State only; the rectangle is refit live for the readout and handed to the
// caller once, on Save.
//
// A Metal-backed imagery Map mounted before layout gives it a size renders blank until an app
// switch ("CAMetalLayer ignoring invalid setDrawableSize 0x0"), so the Map is created only after a
// first non-zero geometry (see `MapMountGate`).

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// Adjust a saved field's four corners and persist the correction. Present it on its own, full
/// screen or in a sheet; it brings its navigation bar with it.
struct CornerEditorView: View {
    let field: FieldModel
    /// The match's GPS route, when opened from a match: the evidence to line the corners up with.
    var route: [CLLocationCoordinate2D] = []
    /// Called after a successful save (the caller dismisses / reprojects).
    var onSaved: () -> Void

    @EnvironmentObject private var fields: FieldsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FieldOutlineEditor(title: "Adjust Outline",
                               initialCorners: field.rectangle.corners.map(\.clCoordinate),
                               initialRegion: field.rectangle.mapRegion,
                               route: route) { corners, rectangle in
                var updated = field
                updated.rectangle = rectangle
                updated.outline = corners.map(Coordinate2D.init)
                updated.source = .trained
                updated.observationCount += 1
                fields.save(updated)
                dismiss()
                onSaved()
            }
        }
    }
}

// MARK: - Plausible size

/// What a field can be. The upper bounds are soccer's; the lower ones allow small-sided and futsal,
/// which the sport profile's full-size range would reject.
enum FieldSizeCheck {
    static let lengthRange = 20.0...SportProfile.soccer.typicalLengthRange.upperBound
    static let widthRange = 12.0...SportProfile.soccer.typicalWidthRange.upperBound

    /// Why this outline can't be saved, in the player's words, or nil when it can.
    static func problem(with rectangle: OrientedRectangle, corners: [CLLocationCoordinate2D]) -> String? {
        let units = UnitSystem.current
        if rectangle.lengthMeters > lengthRange.upperBound {
            return "Too long for a field. The most is \(units.shortDistance(lengthRange.upperBound).text)."
        }
        if rectangle.widthMeters > widthRange.upperBound {
            return "Too wide for a field. The most is \(units.shortDistance(widthRange.upperBound).text)."
        }
        if rectangle.lengthMeters < lengthRange.lowerBound || rectangle.widthMeters < widthRange.lowerBound {
            let least = units.fieldSize(length: lengthRange.lowerBound, width: widthRange.lowerBound)
            return "Too small for a field. The least is \(least)."
        }
        if corners.count == 4, FieldRing.area(of: corners) < 0.8 * rectangle.lengthMeters * rectangle.widthMeters {
            return "Not square yet. Put each corner on a corner of the field."
        }
        return nil
    }

    static func isPlausible(_ rectangle: OrientedRectangle) -> Bool {
        problem(with: rectangle, corners: []) == nil
    }
}

/// Corner arithmetic in local meters.
enum FieldRing {
    static func center(of corners: [CLLocationCoordinate2D]) -> Coordinate2D {
        let count = Double(max(corners.count, 1))
        return Coordinate2D(latitude: corners.reduce(0) { $0 + $1.latitude } / count,
                            longitude: corners.reduce(0) { $0 + $1.longitude } / count)
    }

    /// Indices in the order that walks the outline without crossing itself, whatever order the
    /// corners were tapped in.
    static func order(of corners: [CLLocationCoordinate2D]) -> [Int] {
        let frame = ENUFrame(reference: center(of: corners))
        return corners.indices.sorted { first, second in
            let a = frame.project(Coordinate2D(corners[first]))
            let b = frame.project(Coordinate2D(corners[second]))
            return atan2(a.y, a.x) < atan2(b.y, b.x)
        }
    }

    static func area(of corners: [CLLocationCoordinate2D]) -> Double {
        let frame = ENUFrame(reference: center(of: corners))
        let points = order(of: corners).map { frame.project(Coordinate2D(corners[$0])) }
        var doubled = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            doubled += Double(points[index].x * next.y - next.x * points[index].y)
        }
        return abs(doubled) / 2
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let point = ENUFrame(reference: Coordinate2D(a)).project(Coordinate2D(b))
        return hypot(Double(point.x), Double(point.y))
    }

    static func moved(_ coordinate: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        ENUFrame(reference: Coordinate2D(coordinate)).unproject(CGPoint(x: east, y: north)).clCoordinate
    }
}

// MARK: - Editor

/// Four corners on satellite imagery. Starts with corners to drag, or with none and asks for taps.
struct FieldOutlineEditor: View {
    let title: String
    let initialCorners: [CLLocationCoordinate2D]
    var route: [CLLocationCoordinate2D] = []
    let onSave: ([CLLocationCoordinate2D], OrientedRectangle) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var corners: [CLLocationCoordinate2D]
    @State private var undoStack: [[CLLocationCoordinate2D]] = []
    @State private var cameraPosition: MapCameraPosition
    /// Bumped while the camera moves so the overlay re-renders in lockstep with the map. A plain
    /// `@State` reference on purpose: only `OutlineOverlay` observes it, so per-frame bumps never
    /// re-evaluate this body.
    @State private var camera = OutlineCamera()
    @State private var grabbed: OutlineHandle?
    @State private var needsToZoomIn = false
    @State private var confirmingDiscard = false
    @State private var saves = 0

    private static let mapSpace = "fieldOutlineMap"
    /// Wider than this and a tap can't land on a corner.
    private static let widestPlacingSpan = 1500.0

    init(title: String,
         initialCorners: [CLLocationCoordinate2D] = [],
         initialRegion: MKCoordinateRegion? = nil,
         route: [CLLocationCoordinate2D] = [],
         onSave: @escaping ([CLLocationCoordinate2D], OrientedRectangle) -> Void) {
        self.title = title
        self.initialCorners = initialCorners
        self.route = route
        self.onSave = onSave
        _corners = State(initialValue: initialCorners)
        _cameraPosition = State(initialValue: initialRegion.map { .region($0) } ?? .automatic)
    }

    private var isPlacing: Bool { corners.count < 4 }

    private var ring: [CLLocationCoordinate2D] { FieldRing.order(of: corners).map { corners[$0] } }

    /// The rectangle that will be saved.
    private var rectangle: OrientedRectangle? {
        isPlacing ? nil : FieldGeometry.fitOrientedRectangle(to: corners.map(Coordinate2D.init))
    }

    private var problem: String? {
        guard let rectangle else { return nil }
        return FieldSizeCheck.problem(with: rectangle, corners: corners)
    }

    /// What will be saved, or the corners as they are while that isn't possible.
    private var outline: [CLLocationCoordinate2D] {
        guard let rectangle, problem == nil else { return isPlacing ? corners : ring }
        return rectangle.coordinateRing
    }

    /// Fixed, not adaptive: imagery is the same in light and dark.
    private static let good = Color(red: 0.19, green: 0.82, blue: 0.35)
    private static let bad = Color(red: 1.0, green: 0.27, blue: 0.23)

    var body: some View {
        MapMountGate { map }
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) { statusPanel }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Chrome over imagery reads best dark, as in Camera and Markup.
            .preferredColorScheme(.dark)
            .toolbar { toolbar }
            .interactiveDismissDisabled()
            .sensoryFeedback(.selection, trigger: grabbed) { _, new in new != nil }
            .sensoryFeedback(.selection, trigger: corners.count)
            .sensoryFeedback(.success, trigger: saves)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if undoStack.isEmpty { dismiss() } else { confirmingDiscard = true }
            }
            .tint(.primary)
            .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard,
                                titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
                .fontWeight(.semibold)
                .disabled(rectangle == nil || problem != nil)
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if route.count > 1 {
                    MapPolyline(coordinates: route)
                        .stroke(.white.opacity(0.7),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.imagery)
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .continuous) { context in
                camera.region = context.region
                camera.heading = context.camera.heading
                camera.tick &+= 1
            }
            .onTapGesture { location in
                guard isPlacing, let coordinate = proxy.convert(location, from: .local) else { return }
                place(coordinate)
            }
            .accessibilityLabel("Satellite map")
            // A sibling overlay (not annotations), so a handle drag never fights the map's pan.
            .overlay {
                OutlineOverlay(camera: camera, corners: corners, outline: outline,
                               halfway: problem == nil ? rectangle.map(halfwayLine) ?? [] : [],
                               color: problem == nil ? Self.good : Self.bad,
                               grabbed: $grabbed,
                               proxy: proxy, space: Self.mapSpace,
                               spokenSize: rectangle.map(MatchFormat.spokenFieldSize) ?? "",
                               onDragBegan: pushUndo,
                               onMove: { corners[$0] = $1 },
                               onMoveAll: { corners = $0 })
            }
            .coordinateSpace(name: Self.mapSpace)
        }
    }

    private func halfwayLine(of rectangle: OrientedRectangle) -> [CLLocationCoordinate2D] {
        let ring = rectangle.coordinateRing
        guard ring.count == 4 else { return [] }
        // Halve the two long sides.
        let start = FieldRing.meters(ring[0], ring[1]) >= FieldRing.meters(ring[1], ring[2]) ? 0 : 1
        func middle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                                   longitude: (a.longitude + b.longitude) / 2)
        }
        return [middle(ring[start], ring[start + 1]), middle(ring[(start + 2) % 4], ring[(start + 3) % 4])]
    }

    // MARK: Status

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            statusText
                .frame(maxWidth: .infinity, alignment: .leading)
            if !undoStack.isEmpty {
                Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(.primary)
            }
        }
        .readableWidth()
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let rectangle {
                Text(MatchFormat.fieldSize(rectangle))
                    .font(.figure(.title2))
                    .monospacedDigit()
                    .accessibilityLabel(MatchFormat.spokenFieldSize(rectangle))
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.loss)
                } else {
                    Text("Drag a corner to fine-tune it, or the middle to move the whole field.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            } else {
                Text(needsToZoomIn ? "Zoom in closer" : "Tap corner \(corners.count + 1) of 4")
                    .font(.title3.weight(.semibold))
                Text("Zoom until the field fills the screen, then tap each of its corners.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
                if corners.isEmpty {
                    Button("Start from a Full-Size Field", action: placeRectangle)
                        .font(.body)
                        .frame(minHeight: 44)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func pushUndo() { undoStack.append(corners) }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        corners = previous
        grabbed = nil
    }

    private func place(_ coordinate: CLLocationCoordinate2D) {
        let span = (camera.region?.span.latitudeDelta ?? 180) * metersPerDegreeLatitude
        needsToZoomIn = span > Self.widestPlacingSpan
        guard !needsToZoomIn else { return }
        pushUndo()
        corners.append(coordinate)
    }

    /// Drops a regulation field in the middle of the view. Also the way in for VoiceOver, which
    /// can't tap a spot on a map.
    private func placeRectangle() {
        guard let region = camera.region else { return }
        pushUndo()
        needsToZoomIn = false
        let half = (length: 52.5, width: 34.0)
        // Long side along the taller side of the screen's view.
        let isTall = region.span.latitudeDelta * metersPerDegreeLatitude
            >= region.span.longitudeDelta * ENUFrame(reference: Coordinate2D(region.center)).metersPerDegreeLongitude
        let east = isTall ? half.width : half.length
        let north = isTall ? half.length : half.width
        corners = [(-east, north), (east, north), (east, -north), (-east, -north)].map {
            FieldRing.moved(region.center, east: $0.0, north: $0.1)
        }
        let framed = MKCoordinateRegion(center: region.center, latitudinalMeters: 190, longitudinalMeters: 190)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            cameraPosition = .region(framed)
        }
    }

    private func save() {
        guard let rectangle, problem == nil else { return }
        saves += 1
        onSave(ring, rectangle)
    }
}

/// The live camera, observed only by the handle overlay.
private final class OutlineCamera: ObservableObject {
    @Published var tick = 0
    var region: MKCoordinateRegion?
    var heading: CLLocationDirection = 0
}

private enum OutlineHandle: Hashable {
    case corner(Int)
    case middle
}

/// The outline, its handles, edge lengths and the loupe, positioned from the map camera every frame.
/// The outline is drawn here rather than as map content, which trails the finger during a drag.
private struct OutlineOverlay: View {
    @ObservedObject var camera: OutlineCamera
    let corners: [CLLocationCoordinate2D]
    let outline: [CLLocationCoordinate2D]
    let halfway: [CLLocationCoordinate2D]
    let color: Color
    @Binding var grabbed: OutlineHandle?
    let proxy: MapProxy
    let space: String
    let spokenSize: String
    let onDragBegan: () -> Void
    let onMove: (Int, CLLocationCoordinate2D) -> Void
    let onMoveAll: ([CLLocationCoordinate2D]) -> Void

    /// Screen positions when the drag began; moves are relative, so the corner stays under the
    /// loupe's crosshair instead of jumping to the fingertip.
    @State private var dragStart: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            let _ = camera.tick
            let points = corners.map { proxy.convert($0, to: .local) }
            ZStack {
                outlineShape
                if corners.count == 4 {
                    edgeLabels(points: points)
                    middleHandle(points: points)
                }
                ForEach(corners.indices, id: \.self) { index in
                    if let point = points[index] {
                        cornerHandle(index: index, at: point, points: points)
                    }
                }
                if corners.count == 4 {
                    loupe(points: points, in: geometry.size)
                }
            }
        }
    }

    // MARK: Outline

    private var outlineShape: some View {
        let line = path(through: outline, closed: corners.count == 4)
        return ZStack {
            if corners.count == 4 { line.fill(color.opacity(0.18)) }
            line.stroke(color, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            path(through: halfway, closed: false).stroke(color.opacity(0.7), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func path(through coordinates: [CLLocationCoordinate2D], closed: Bool) -> Path {
        Path { path in
            path.addLines(coordinates.compactMap { proxy.convert($0, to: .local) })
            if closed { path.closeSubpath() }
        }
    }

    // MARK: Handles

    private func cornerHandle(index: Int, at point: CGPoint, points: [CGPoint?]) -> some View {
        let isGrabbed = grabbed == .corner(index)
        return ring(diameter: isGrabbed ? 52 : 30)
            .frame(width: 60, height: 60)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        guard beginDrag(.corner(index), points: points) else { return }
                        let target = CGPoint(x: dragStart[index].x + value.translation.width,
                                             y: dragStart[index].y + value.translation.height)
                        if let coordinate = proxy.convert(target, from: .local) { onMove(index, coordinate) }
                    }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel(corners.count == 4 ? "\(direction(of: index)) corner" : "Corner \(index + 1)")
            .accessibilityValue(spokenSize)
            .accessibilityHint("Swipe up or down to move it outward or inward.")
            .accessibilityAdjustableAction { adjustment in
                nudgeOutward(index, meters: adjustment == .increment ? 1 : -1)
            }
            .accessibilityAction(named: "Move north") { nudge(index, east: 0, north: 1) }
            .accessibilityAction(named: "Move south") { nudge(index, east: 0, north: -1) }
            .accessibilityAction(named: "Move east") { nudge(index, east: 1, north: 0) }
            .accessibilityAction(named: "Move west") { nudge(index, east: -1, north: 0) }
    }

    /// A hollow ring, so the corner it marks stays visible.
    private func ring(diameter: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(.black.opacity(0.45), lineWidth: 7)
            Circle().strokeBorder(.white, lineWidth: 4).padding(1.5)
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func middleHandle(points: [CGPoint?]) -> some View {
        let visible = points.compactMap { $0 }
        if visible.count == 4 {
            let center = CGPoint(x: visible.map(\.x).reduce(0, +) / 4, y: visible.map(\.y).reduce(0, +) / 4)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
                .frame(width: 60, height: 60)
                .contentShape(Circle())
                .position(center)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                        .onChanged { value in
                            guard beginDrag(.middle, points: points) else { return }
                            let moved = dragStart.compactMap {
                                proxy.convert(CGPoint(x: $0.x + value.translation.width,
                                                      y: $0.y + value.translation.height), from: .local)
                            }
                            if moved.count == corners.count { onMoveAll(moved) }
                        }
                        .onEnded { _ in endDrag() }
                )
                .opacity(grabbed == nil || grabbed == .middle ? 1 : 0)
                .accessibilityElement()
                .accessibilityLabel("Whole field")
                .accessibilityAction(named: "Move north") { nudgeAll(east: 0, north: 1) }
                .accessibilityAction(named: "Move south") { nudgeAll(east: 0, north: -1) }
                .accessibilityAction(named: "Move east") { nudgeAll(east: 1, north: 0) }
                .accessibilityAction(named: "Move west") { nudgeAll(east: -1, north: 0) }
        }
    }

    private func beginDrag(_ handle: OutlineHandle, points: [CGPoint?]) -> Bool {
        if grabbed == nil {
            let visible = points.compactMap { $0 }
            guard visible.count == corners.count else { return false }
            dragStart = visible
            grabbed = handle
            onDragBegan()
        }
        return grabbed == handle
    }

    private func endDrag() {
        grabbed = nil
        dragStart = []
    }

    // MARK: VoiceOver nudges

    private func nudge(_ index: Int, east: Double, north: Double) {
        onDragBegan()
        onMove(index, FieldRing.moved(corners[index], east: east, north: north))
    }

    private func nudgeAll(east: Double, north: Double) {
        onDragBegan()
        onMoveAll(corners.map { FieldRing.moved($0, east: east, north: north) })
    }

    private func nudgeOutward(_ index: Int, meters: Double) {
        let offset = ENUFrame(reference: FieldRing.center(of: corners)).project(Coordinate2D(corners[index]))
        let length = max(hypot(Double(offset.x), Double(offset.y)), 0.001)
        nudge(index, east: Double(offset.x) / length * meters, north: Double(offset.y) / length * meters)
    }

    private func direction(of index: Int) -> String {
        let offset = ENUFrame(reference: FieldRing.center(of: corners)).project(Coordinate2D(corners[index]))
        let degrees = (atan2(Double(offset.x), Double(offset.y)) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
        let names = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
        return names[Int((degrees / 45).rounded()) % 8]
    }

    // MARK: Edge lengths

    private func edgeLabels(points: [CGPoint?]) -> some View {
        let order = FieldRing.order(of: corners)
        let visible = points.compactMap { $0 }
        let center = visible.isEmpty ? .zero
            : CGPoint(x: visible.map(\.x).reduce(0, +) / CGFloat(visible.count),
                      y: visible.map(\.y).reduce(0, +) / CGFloat(visible.count))
        return ForEach(0..<4, id: \.self) { side in
            let first = order[side], second = order[(side + 1) % 4]
            if let a = points[first], let b = points[second], hypot(a.x - b.x, a.y - b.y) > 120 {
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let away = CGPoint(x: middle.x - center.x, y: middle.y - center.y)
                let length = max(hypot(away.x, away.y), 1)
                EdgeLength(meters: FieldRing.meters(corners[first], corners[second]))
                    .position(x: middle.x + away.x / length * 24, y: middle.y + away.y / length * 18)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Loupe

    /// A closer look at the corner being dragged, held clear of the finger. Mounted throughout so
    /// its imagery is already loaded when a drag starts.
    private func loupe(points: [CGPoint?], in size: CGSize) -> some View {
        let index: Int? = { if case .corner(let index) = grabbed { return index } else { return nil } }()
        let diameter: CGFloat = 150
        let point = index.flatMap { points[$0] } ?? .zero
        let above = point.y - 125
        let y = above > diameter / 2 + 110 ? above : point.y + 125
        let x = min(max(point.x, diameter / 2 + 12), size.width - diameter / 2 - 12)
        let coordinate = corners[index ?? 0]
        return Map(position: .constant(.camera(MapCamera(centerCoordinate: coordinate, distance: 75,
                                                         heading: camera.heading))),
                   interactionModes: []) { }
        .mapStyle(.imagery)
        .mapControls { }
        // Oversized, so the map's own badge falls outside the circle. The full map shows it.
        .frame(width: diameter * 1.5, height: diameter * 1.5)
        .frame(width: diameter, height: diameter)
        .overlay { loupeEdges(index: index, points: points, radius: diameter / 2) }
        .overlay {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .thin))
                .foregroundStyle(.white)
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
        .position(x: index == nil ? size.width / 2 : x, y: index == nil ? size.height / 2 : y)
        .opacity(index == nil ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The two edges meeting at the grabbed corner, leaving the crosshair the way they leave the corner.
    private func loupeEdges(index: Int?, points: [CGPoint?], radius: CGFloat) -> some View {
        Path { path in
            let order = FieldRing.order(of: corners)
            guard let index, let corner = points[index], let place = order.firstIndex(of: index) else { return }
            for neighbor in [order[(place + 1) % 4], order[(place + 3) % 4]] {
                guard let other = points[neighbor] else { continue }
                let length = max(hypot(other.x - corner.x, other.y - corner.y), 1)
                path.move(to: CGPoint(x: radius, y: radius))
                path.addLine(to: CGPoint(x: radius + (other.x - corner.x) / length * radius,
                                         y: radius + (other.y - corner.y) / length * radius))
            }
        }
        .stroke(color, lineWidth: 2)
    }
}

/// One edge's length, on a plate because imagery can be any color.
private struct EdgeLength: View {
    let meters: Double

    var body: some View {
        Text(UnitSystem.current.shortDistance(meters).text)
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }
}

/// Defers building a Metal-backed Map until layout has handed down a first non-zero size.
struct MapMountGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > 1, geometry.size.height > 1 {
                content()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                Color.black
            }
        }
    }
}
