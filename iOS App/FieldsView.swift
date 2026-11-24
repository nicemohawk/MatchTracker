// FieldsView.swift
// MatchTracker

import SwiftUI
import MapKit
import CoreLocation
import MatchTrackerKit

/// The places you play: a satellite map with your fields listed beside it.
///
/// Three native containers, one model. Presented on iPhone (from Settings) it is a map under a
/// persistent sheet, as in Maps and Find My. As a tab, where a sheet would cover the tab bar, the
/// list sits under the map. At regular width it is a split view.
struct FieldsView: View {
    @EnvironmentObject private var fields: FieldsModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(NearbyFieldSeeder.self) private var seeder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    @State private var model = FieldsMapModel()
    @State private var showingSheet = false
    @State private var containerHeight: CGFloat = 800
    @ScaledMetric(relativeTo: .title3) private var peekHeight: CGFloat = 92

    /// Automatic seed passes are throttled so revisiting this screen doesn't rescan the area.
    @AppStorage("lastNearbySeedAt") private var lastAutoSeed: Double = 0
    private let autoSeedInterval: TimeInterval = 30 * 60

    var body: some View {
        container
            .onAppear {
                model.frameInitially(fields.fields)
                autoSeedIfNeeded()
            }
            .onChange(of: model.selection) { _, selected in
                guard let selected, let field = fields.field(id: selected) else { return }
                model.path = [.field(selected)]
                focus(on: field.rectangle)
            }
            .onChange(of: model.path) { _, path in
                if path.isEmpty { model.selection = nil }
            }
    }

    @ViewBuilder
    private var container: some View {
        if horizontalSizeClass == .regular {
            splitLayout
        } else if isPresented {
            sheetLayout
        } else {
            stackLayout
        }
    }

    // MARK: Layouts

    private var splitLayout: some View {
        NavigationSplitView {
            panel(showsClose: isPresented)
                .navigationSplitViewColumnWidth(min: 340, ideal: 380)
        } detail: {
            map.ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .primaryAction) { locateButton } }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sheetLayout: some View {
        NavigationStack {
            map
                // Frame and center fields in the part of the map the sheet leaves visible.
                .safeAreaPadding(.bottom, model.detent == .height(peekHeight) ? peekHeight : containerHeight * 0.5)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                            containerHeight = height
                        }
                    }
                }
                // Keeps the status bar readable over pale roofs; the map has no title bar to do it.
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .primaryAction) { locateButton } }
        }
        // The map runs under the status bar; light text reads on imagery.
        .preferredColorScheme(.dark)
        .onAppear { showingSheet = true }
        .sheet(isPresented: $showingSheet) {
            panel(showsClose: true)
                .modifier(FieldsSheetDetents(model: model, peekHeight: peekHeight))
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $model.path) {
            VStack(spacing: 0) {
                map.frame(maxHeight: .infinity)
                list.frame(maxHeight: .infinity)
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { locateButton } }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .modifier(FieldsPanelChrome(model: model, showsClose: false, showsPicture: true,
                                        onClose: {}, onDetect: detect))
        }
    }

    private func panel(showsClose: Bool) -> some View {
        NavigationStack(path: $model.path) {
            list.modifier(FieldsPanelChrome(model: model, showsClose: showsClose, showsPicture: false,
                                            onClose: close, onDetect: detect))
        }
    }

    private var list: some View {
        FieldsList(model: model, detected: detected) { field in
            model.path = [.field(field.id)]
            focus(on: field.rectangle)
        } onReview: { candidate in
            model.path = [.detected(candidate)]
            focus(on: candidate.rectangle)
        } onDetect: {
            detect()
        }
    }

    private func close() {
        // The sheet goes first; dismissing under it would only dismiss the sheet.
        showingSheet = false
        dismiss()
    }

    // MARK: Map

    private var detected: [DetectedField] {
        let candidates = model.detected + seeder.proposals.map(DetectedField.init)
        return candidates.filter { candidate in
            !model.dismissed.contains(candidate.id)
                && FieldSizeCheck.isPlausible(candidate.rectangle)
                && !fields.fields.contains {
                    FieldRing.meters($0.rectangle.center.clCoordinate, candidate.rectangle.center.clCoordinate) < 40
                }
        }
    }

    private var map: some View {
        Map(position: $model.camera, selection: $model.selection) {
            UserAnnotation()
            ForEach(fields.fields) { field in
                MapPolygon(coordinates: field.rectangle.coordinateRing)
                    .foregroundStyle(FieldsMapModel.outline.opacity(0.18))
                    .stroke(FieldsMapModel.outline,
                            style: StrokeStyle(lineWidth: 2.5, dash: field.needsOutlineCheck ? [6, 4] : []))
                Marker(field.name, systemImage: "sportscourt.fill", coordinate: field.rectangle.center.clCoordinate)
                    .tint(Theme.turf)
                    .tag(field.id)
            }
            ForEach(detected) { candidate in
                MapPolygon(coordinates: candidate.rectangle.coordinateRing)
                    .foregroundStyle(.white.opacity(0.12))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .mapStyle(.hybrid(elevation: .flat))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            model.region = context.region
        }
    }

    /// Not `MapUserLocationButton`: that one stays inert until location is allowed, and this is the
    /// only place the app asks.
    private var locateButton: some View {
        Button("Show My Location", systemImage: "location") { Task { await locate() } }
            .tint(.primary)
    }

    private func focus(on rectangle: OrientedRectangle) {
        if model.detent == .height(peekHeight) { model.raiseSheet() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            model.camera = .region(rectangle.mapRegion)
        }
    }

    private func locate() async {
        guard let coordinate = await model.location.requestCurrentLocation() else {
            model.notice = model.location.isDenied ? .locationOff : .locationUnavailable
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            model.camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600,
                                                      longitudinalMeters: 600))
        }
    }

    // MARK: Detection

    /// Looks for fields in the satellite picture on screen. Never silent: it ends in candidates to
    /// review or a plain explanation.
    private func detect() {
        guard !model.isDetecting else { return }
        guard let region = model.region,
              region.span.latitudeDelta * metersPerDegreeLatitude < 2500 else {
            model.notice = .zoomIn
            return
        }
        model.isDetecting = true
        Task {
            let found = await SatelliteFieldDetector().detectFields(in: region)
            model.detected = found.prefix(4).map(DetectedField.init)
            model.dismissed = []
            model.isDetecting = false
            MatchLog.info("detect: \(detected.count) candidate(s) shown", category: "scan")
            if detected.isEmpty { model.notice = .nothingFound }
        }
    }

    /// A nearby pass when this screen appears, only with sharing on and location already allowed.
    private func autoSeedIfNeeded() {
        guard settings.contributeDetectedFields, seeder.isLocationAuthorized, !seeder.isScanning else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAutoSeed > autoSeedInterval else { return }
        lastAutoSeed = now
        Task { await seeder.seedAroundCurrentLocation() }
    }
}

// MARK: - State

/// A field found in satellite imagery that nobody has confirmed.
struct DetectedField: Identifiable, Hashable {
    let rectangle: OrientedRectangle
    var id: String { "\(rectangle.center.latitude),\(rectangle.center.longitude)" }

    static func == (lhs: DetectedField, rhs: DetectedField) -> Bool { lhs.rectangle == rhs.rectangle }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum FieldsRoute: Hashable {
    case field(UUID)
    case detected(DetectedField)
}

enum FieldsNotice: Identifiable {
    case nothingFound, zoomIn, locationOff, locationUnavailable
    var id: Self { self }

    var title: String {
        switch self {
        case .nothingFound: return "No Fields Found"
        case .zoomIn: return "Zoom In First"
        case .locationOff: return "Location Is Off"
        case .locationUnavailable: return "Couldn’t Find You"
        }
    }

    var message: String {
        switch self {
        case .nothingFound:
            return "MatchTracker couldn’t make out a field in this view. Try with one field filling the screen, or draw its corners."
        case .zoomIn:
            return "Detection works when a field takes up a good part of the screen."
        case .locationOff:
            return "Allow location for MatchTracker in Settings to show where you are on the map."
        case .locationUnavailable:
            return "Your location isn’t available right now. You can still move the map by hand."
        }
    }
}

@MainActor
@Observable
final class FieldsMapModel {
    /// Fixed, not adaptive: imagery is the same in light and dark.
    static let outline = Color(red: 0.19, green: 0.82, blue: 0.35)

    var camera: MapCameraPosition = .automatic
    var region: MKCoordinateRegion?
    var selection: UUID?
    var path: [FieldsRoute] = []
    var detected: [DetectedField] = []
    var dismissed: Set<String> = []
    var isDetecting = false
    var isDrawing = false
    /// How far up the list sheet is, on iPhone.
    var detent: PresentationDetent = .medium
    var isRaisingSheet = false

    /// Setting the selection alone leaves the sheet where it is (iOS 26.5), so for a moment half
    /// height is the only height on offer.
    func raiseSheet() {
        isRaisingSheet = true
        detent = .medium
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            isRaisingSheet = false
        }
    }
    var notice: FieldsNotice?
    let location = MapLocationProvider()

    /// Open on the fields near the first one, rather than a continent holding all of them.
    func frameInitially(_ fields: [FieldModel]) {
        guard region == nil, let first = fields.first else { return }
        let nearby = fields.filter {
            FieldRing.meters($0.rectangle.center.clCoordinate, first.rectangle.center.clCoordinate) < 20_000
        }
        let corners = nearby.flatMap(\.rectangle.coordinateRing)
        let rect = corners.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: MKMapPoint($1), size: .init())) }
        camera = .rect(rect.insetBy(dx: -rect.width * 0.35, dy: -rect.height * 0.35))
    }
}

// MARK: - Chrome shared by the three layouts

/// The persistent sheet.
private struct FieldsSheetDetents: ViewModifier {
    @Bindable var model: FieldsMapModel
    let peekHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .presentationDetents(model.isRaisingSheet ? [.medium] : [.height(peekHeight), .medium, .large],
                                 selection: $model.detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
    }
}

/// Title, the one add menu, destinations and the alerts. Attached inside whichever container is
/// frontmost, so presentations never start from a view that is already covered.
private struct FieldsPanelChrome: ViewModifier {
    @Bindable var model: FieldsMapModel
    let showsClose: Bool
    /// Beside the map, the map is the picture.
    let showsPicture: Bool
    let onClose: () -> Void
    let onDetect: () -> Void

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .navigationTitle("Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: onClose).tint(.primary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isDetecting {
                        ProgressView().accessibilityLabel("Looking for fields")
                    } else {
                        Menu("Add Field", systemImage: "plus") {
                            Button("Draw Corners", systemImage: "skew") { model.isDrawing = true }
                            Button("Detect in This View", systemImage: "viewfinder", action: onDetect)
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationDestination(for: FieldsRoute.self) { route in
                switch route {
                case .field(let id):
                    FieldDetailView(fieldID: id, showsPicture: showsPicture) { model.path = [] }
                case .detected(let candidate):
                    DetectedFieldView(candidate: candidate, showsPicture: showsPicture) { added in
                        model.dismissed.insert(candidate.id)
                        model.path = [.field(added.id)]
                    } onDismissed: {
                        model.dismissed.insert(candidate.id)
                        model.path = []
                    }
                }
            }
            .fullScreenCover(isPresented: $model.isDrawing) {
                AddFieldView(initialRegion: model.region) { added in
                    model.path = [.field(added.id)]
                    model.camera = .region(added.rectangle.mapRegion)
                }
            }
            .alert(model.notice?.title ?? "", isPresented: .init(get: { model.notice != nil },
                                                                 set: { if !$0 { model.notice = nil } }),
                   presenting: model.notice) { notice in
                switch notice {
                case .nothingFound:
                    Button("Draw Corners") { model.isDrawing = true }
                    Button("OK", role: .cancel) {}
                case .locationOff:
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("Not Now", role: .cancel) {}
                case .zoomIn, .locationUnavailable:
                    Button("OK", role: .cancel) {}
                }
            } message: { notice in
                Text(notice.message)
            }
    }
}
