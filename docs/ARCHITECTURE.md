# MatchTracker Architecture (2026 modernization)

MatchTracker records soccer matches on Apple Watch (GPS route + heart rate + events) and
analyzes them on iPhone (heatmaps, runs, workrate, position) with optional backend upload
for team-level aggregation. This document is the **binding contract** for all implementation
work. Do not change public API signatures defined here without updating this file.

## Targets & toolchain

| Target | Tech | Min OS |
|---|---|---|
| `MatchTracker` (iOS app) | SwiftUI | iOS 17.0 |
| `MatchTracker Watch App` (watchOS app, embedded in iOS app) | SwiftUI single-target watch app | watchOS 10.0 |
| `MatchTrackerKit` (local SPM package at `MatchTrackerKit/`) | Pure Swift + CoreLocation/HealthKit types only where unavoidable | iOS 17 / watchOS 10 / macOS 14 |

- Swift 5.10+ language mode (Swift 6 compiler OK; do not enable strict concurrency `complete` — use `minimal`).
- No third-party dependencies. Alamofire and Locksmith are removed; use `URLSession` async/await and a small Keychain wrapper.
- The Xcode project uses **filesystem-synchronized groups** (Xcode 16 `PBXFileSystemSynchronizedRootGroup`) for the three source folders so files can be added without editing `project.pbxproj`.
- Legacy `Watch Extension/`, `Watch App/` (storyboard), `Packages/`, `Package.swift` (root), old UIKit controllers are deleted.

### Folder layout

```
MatchTracker.xcodeproj
MatchTrackerKit/                  # local swift package
  Package.swift
  Sources/MatchTrackerKit/...
  Tests/MatchTrackerKitTests/...
iOS App/                          # synchronized group -> iOS target
Watch App/                        # synchronized group -> watch target
docs/
```

**MatchTrackerKit must build and test on macOS** (`swift test` from `MatchTrackerKit/`) —
analytics are pure functions over value types. Anything importing HealthKit/WatchKit UI stays
in the app targets. CoreLocation types (`CLLocation`, `CLLocationCoordinate2D`) are allowed in
the Kit (available on macOS).

### Identifiers

- iOS bundle id: `com.nicemohawk.MatchTracker` (unchanged). Watch app: `com.nicemohawk.MatchTracker.watchkitapp`.
- App group (per-device shared storage): `group.com.nicemohawk.MatchTracker`.
- Capabilities: HealthKit (both apps), Location (when-in-use + always usage strings), watch background mode `workout-processing`.

## Data flow

1. **Field definition is both/and, improving gracefully with use:**
   - *Trained:* user walks the touchline as a warm-up (watch) or draws corners on a satellite
     map (phone). Outline → `FieldGeometry.fitOrientedRectangle` → `FieldModel(source: .trained)`.
   - *Inferred:* after any match with no matching field, `FieldStore.recordObservation` infers
     a rectangle from the match track itself and proposes it ("Looks like a new field — save
     it?"). Every subsequent match on a known field refines its geometry (weighted average)
     and increments `observationCount`.
   - *Community:* the backend merges field observations across devices by geometric proximity,
     so the field database sharpens as the user base plays more fields (see
     BACKEND_UPGRADE_PROMPT.md). Satellite-imagery extraction is a roadmap item.
   Watch sends new fields to phone via `WCSession.transferFile` (JSON-encoded `FieldModel`);
   phone is the field database of record and mirrors the field list back with
   `updateApplicationContext` so the watch can auto-detect fields offline.
2. **Match recording (watch):** `HKWorkoutSession` + `HKLiveWorkoutBuilder` (`.soccer`,
   `.outdoor`) + `HKWorkoutRouteBuilder`, exactly like the legacy `WorkoutController`.
   Locations requested at `kCLLocationAccuracyBestForNavigation` (`activityType = .fitness`)
   and filtered to `horizontalAccuracy <= 50 m` for match tracks, `<= 20 m` for field training. Events (`MatchEvent`) accumulate in
   memory and persist incrementally to the app group (crash safety). At workout end: route
   saved to HealthKit; a `MatchRecord` JSON (events, field id, team/score metadata, workout
   UUID) is `transferFile`'d to the phone.
3. **Analysis (phone):** match list = HK soccer workouts (as legacy `MatchesTableViewController`
   did) joined with received `MatchRecord`s by workout UUID. Track points come from
   `HKWorkoutRoute`. Analytics computed via MatchTrackerKit and cached.
4. **Upload (phone):** `APIClient` posts fields and match payloads to the existing backend
   (`/devices/{deviceUUID}/fields`, `/devices/{deviceUUID}/sessions`), extended payload per
   `docs/BACKEND_UPGRADE_PROMPT.md`. API key from CloudKit record `default` field `apiKey`
   (legacy behavior) stored in Keychain.

## MatchTrackerKit public API (binding)

```swift
// MARK: Geometry & fields
public struct Coordinate2D: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double)
}

public struct OrientedRectangle: Codable, Equatable, Sendable {
    public var center: Coordinate2D
    public var lengthMeters: Double      // long side
    public var widthMeters: Double       // short side
    public var headingDegrees: Double    // compass bearing of long axis, 0..<180
    public var corners: [Coordinate2D]   // 4, ordered, closed ring NOT repeated
}

public enum FieldGeometry {
    /// Minimum-area oriented bounding rectangle of the outline (convex hull + rotating
    /// calipers, computed in a local ENU meters projection around the centroid).
    public static func fitOrientedRectangle(to outline: [Coordinate2D]) -> OrientedRectangle?
    /// Ramer–Douglas–Peucker simplification, tolerance in meters.
    public static func simplify(_ outline: [Coordinate2D], toleranceMeters: Double) -> [Coordinate2D]
    /// Infer a field rectangle from a full-match GPS track (no training walk needed):
    /// filter to accurate points, trim occupancy outliers (warm-up/walk-off excursions,
    /// e.g. keep the 2nd–98th percentile band in local ENU space), fit the min-area
    /// oriented rectangle, and sanity-check against plausible pitch dimensions
    /// (length 60–130 m, width 35–90 m, aspect ratio > 1.2). Returns nil if the track
    /// doesn't look field-shaped.
    public static func inferFieldRectangle(from track: [TrackPoint]) -> OrientedRectangle?
}

public enum FieldSource: String, Codable, Sendable {
    case trained    // user walked the touchline (or drew on a map)
    case inferred   // derived automatically from match GPS tracks
    case satellite  // detected in Apple Maps satellite imagery on-device
    case community  // received from backend, aggregated across users
}

public struct FieldModel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var outline: [Coordinate2D]       // raw trained outline (may be empty for inferred fields)
    public var rectangle: OrientedRectangle  // fitted
    public var source: FieldSource
    public var observationCount: Int         // matches that confirmed/refined this field
    public init(id: UUID, name: String, createdAt: Date, outline: [Coordinate2D], rectangle: OrientedRectangle, source: FieldSource, observationCount: Int)
}

/// Projects GPS coordinates into normalized field space.
/// x ∈ [0,1] along the LONG axis, y ∈ [0,1] along the SHORT axis. Rotation-invariant.
public struct FieldProjector: Sendable {
    public init(rectangle: OrientedRectangle)
    public func normalizedPoint(for coordinate: Coordinate2D) -> CGPoint? // nil if > tolerance outside
    public func contains(_ coordinate: Coordinate2D, toleranceMeters: Double) -> Bool
}

/// JSON persistence + matching. Storage dir injected (app group container in apps, temp in tests).
public final class FieldStore {
    public init(directory: URL)
    public private(set) var fields: [FieldModel]
    public func load() throws
    public func save(_ field: FieldModel) throws        // insert or replace by id
    public func delete(id: UUID) throws
    /// Which field is this track being played on? Scores candidate fields by the fraction
    /// of samples inside (with tolerance), tie-breaking by distance to center — this makes
    /// side-by-side and rotated fields disambiguate correctly. Returns nil if best score < 0.5.
    public func bestMatch(for samples: [Coordinate2D]) -> FieldModel?
    /// Post-match learning hook: match the track against known fields. On a match, refine the
    /// stored rectangle (observation-count-weighted average of center/size/heading) and bump
    /// observationCount. With no match, try `FieldGeometry.inferFieldRectangle` and return a
    /// `.proposed` FieldModel (source: .inferred) for user confirmation — NOT auto-saved.
    public func recordObservation(track: [TrackPoint]) -> FieldObservationResult
}

public enum FieldObservationResult: Sendable {
    case matched(FieldModel)   // existing field found; geometry refined in place
    case proposed(FieldModel)  // plausible new field inferred; caller asks user to confirm/save
    case none                  // track unusable for field inference
}

// MARK: Track & events
public struct TrackPoint: Codable, Hashable, Sendable {
    public var coordinate: Coordinate2D
    public var timestamp: Date
    public var speedMetersPerSecond: Double   // -1 if invalid
    public var courseDegrees: Double          // -1 if invalid
    public var horizontalAccuracy: Double
    public init(coordinate: Coordinate2D, timestamp: Date, speedMetersPerSecond: Double, courseDegrees: Double, horizontalAccuracy: Double)
}

public enum MatchEventKind: String, Codable, CaseIterable, Sendable {
    case matchStart, matchEnd
    case periodStart, periodEnd
    case subIn, subOut                 // player enters/leaves the pitch
    case goalForUs = "goalFor", goalAgainstUs = "goalAgainst"
    case goalMine                      // wearer scored
    case assist
    case flag                          // generic "something happened" marker for post-game review
}

public enum MatchEventSource: String, Codable, Sendable { case manual, automatic }

public struct MatchEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var date: Date
    public var note: String?
    public var source: MatchEventSource   // decodeIfPresent, defaults .manual (wire compat)
    public init(id: UUID = UUID(), kind: MatchEventKind, date: Date, note: String? = nil, source: MatchEventSource = .manual)
}

/// Automatic substitution detection. Geometry-first by design: the signal for "benched" is
/// sustained presence OUTSIDE the touchline, never low movement — keepers and defenders can
/// stand still for long stretches while very much in the game. Heart-rate trend is only a
/// tiebreaker for fixes hovering in the ambiguous boundary band; it never vetoes geometry
/// (a sub warming up along the sideline has high HR and is still off the pitch).
public struct AutoSubDetectorConfiguration: Sendable {
    public var exitDistanceMeters: Double         // beyond-touchline distance that counts as off-pitch, default 5.0
    public var exitDwell: TimeInterval            // continuous off-pitch time before subOut, default 30
    public var enterDwell: TimeInterval           // continuous on-pitch time before subIn, default 15
    public var maximumFixAccuracy: Double         // ignore worse fixes for boundary calls, default 20
    public var manualOverrideCooldown: TimeInterval // auto suppressed after a manual sub event, default 60
    public init()
}

public final class AutoSubDetector {
    public init(projector: FieldProjector, configuration: AutoSubDetectorConfiguration = .init(), initiallyOnPitch: Bool = true)
    /// Feed one live sample; returns a confirmed auto sub event (dated at the transition
    /// moment, not the detection moment) or nil. heartRate optional, used only for
    /// ambiguous-band tiebreaks.
    public func process(point: TrackPoint, heartRate: Double?) -> MatchEvent?
    /// Manual events win: re-syncs detector state and suppresses auto output for the cooldown.
    public func recordManualEvent(_ event: MatchEvent)
    /// Offline pass over a complete track (iOS post-match reconciliation for matches with a
    /// resolved field and no manual sub events). Returns only the new automatic events,
    /// respecting any existing manual ones.
    public static func detectEvents(track: [TrackPoint], projector: FieldProjector,
                                    existingEvents: [MatchEvent],
                                    configuration: AutoSubDetectorConfiguration) -> [MatchEvent]
}

/// Watch-side record of one match; JSON codable, transferred watch -> phone.
public struct MatchRecord: Codable, Identifiable, Sendable {
    public var id: UUID                 // == HKWorkout.uuid when available
    public var startDate: Date
    public var endDate: Date?
    public var fieldID: UUID?
    public var events: [MatchEvent]
    public var teamCode: String?
    public init(id: UUID, startDate: Date, endDate: Date?, fieldID: UUID?, events: [MatchEvent], teamCode: String?)
}

public enum SubstitutionTracker {
    /// Intervals the wearer was on the pitch. Match starts "on" unless events start with subIn.
    public static func playingIntervals(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> [DateInterval]
    public static func timeOnPitch(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> TimeInterval
}

// MARK: Analytics
public struct HeatmapGrid: Codable, Sendable {
    public var columns: Int   // along long axis
    public var rows: Int
    public var cells: [Double]  // row-major, normalized 0...1 (max cell == 1), 0 if empty
    public subscript(column: Int, row: Int) -> Double { get }
    /// Bins time-weighted samples. Only points inside playingIntervals count (nil = all).
    public static func compute(points: [TrackPoint], projector: FieldProjector,
                               columns: Int, rows: Int,
                               playingIntervals: [DateInterval]?) -> HeatmapGrid
}

public enum RunIntensity: String, Codable, CaseIterable, Sendable { case jog, run, sprint }

public struct RunSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var interval: DateInterval
    public var distanceMeters: Double
    public var peakSpeed: Double
    public var averageSpeed: Double
    public var intensity: RunIntensity
    public var pointRange: Range<Int>   // indices into source track
}

public struct RunDetectorConfiguration: Sendable {
    public var jogThreshold: Double      // m/s, default 2.0
    public var runThreshold: Double      // default 4.0
    public var sprintThreshold: Double   // default 5.5
    public var minimumDuration: TimeInterval // default 2.0
    public var mergeGap: TimeInterval    // default 1.5 s below-threshold gap merged
    public init()
}

public enum RunDetector {
    /// Speed-threshold segmentation with hysteresis + gap merging. Uses GPS-derived speed
    /// (point-to-point) when speedMetersPerSecond invalid.
    public static func detectRuns(in track: [TrackPoint], configuration: RunDetectorConfiguration) -> [RunSegment]
}

public struct SpeedZones: Codable, Sendable {   // seconds in each zone
    public var standing: TimeInterval   // < 0.5 m/s
    public var walking: TimeInterval    // 0.5–2
    public var jogging: TimeInterval    // 2–4
    public var running: TimeInterval    // 4–5.5
    public var sprinting: TimeInterval  // > 5.5
}

public struct WorkrateReport: Codable, Sendable {
    public var totalDistanceMeters: Double
    public var distancePerMinute: [Double]      // meters covered in each minute-on-pitch
    public var speedZones: SpeedZones
    public var sprintCount: Int
    public var runCount: Int
    public var averageHeartRate: Double?        // filled by app layer when HR available
    public var timeOnPitch: TimeInterval
    /// 0–100 composite: distance rate, sprint frequency, high-intensity share.
    public var workrateScore: Double
}

public enum WorkrateAnalyzer {
    public static func analyze(track: [TrackPoint], runs: [RunSegment],
                               playingIntervals: [DateInterval]) -> WorkrateReport
}

public enum PositionRole: String, Codable, CaseIterable, Sendable { case goalkeeper, defender, midfielder, forward }
public enum PositionSide: String, Codable, CaseIterable, Sendable { case left, center, right }

public struct PositionEstimate: Codable, Sendable {
    public var role: PositionRole
    public var side: PositionSide
    public var confidence: Double        // 0–1
    public var meanPoint: CGPoint        // normalized field coords
    /// Per-period mean points let the UI show "played RB first half, RW second".
    public var periodMeanPoints: [CGPoint]
}

public enum PositionAnalyzer {
    /// Attack-direction ambiguity is resolved per period: within one period the team attacks
    /// one way; estimate uses the distribution along the long axis folded around midfield
    /// (position roles are direction-independent: GK/DEF sit near an end, MID central, FWD far),
    /// side from the short-axis mean with period-flip correction.
    public static func estimate(points: [TrackPoint], projector: FieldProjector,
                                events: [MatchEvent], playingIntervals: [DateInterval]) -> PositionEstimate
}

// MARK: Backend
public struct MatchPayload: Codable, Sendable { /* see BACKEND_UPGRADE_PROMPT.md; mirrors legacy
    "sessions" shape: track.coordinates [[lat,lon]], recorded_at ISO8601, uuid — plus events,
    field_uuid, team_code, stats (WorkrateReport summary) */ }

public struct APIClient: Sendable {
    public init(baseURL: URL, apiKey: String, deviceID: UUID)
    public func post(fields: [FieldModel]) async throws
    public func post(matches: [MatchPayload]) async throws
    public func teamStats(code: String) async throws -> TeamStats
}

public struct TeamStats: Codable, Sendable { /* per-player aggregates; see backend prompt */ }
```

Stub rule for scaffolding: every type above exists and compiles; algorithm bodies may
`return` empty/naive values marked `// STUB`. Tests come with the real implementations.

## Watch app UX contract (native-workout parity)

Session flow mirrors Apple's Workout app:
- **Start screen:** big "Start Match" button, field auto-detect status line, recent fields, "Train Field" and settings (team code) below.
- **Countdown → active session** with `TabView(.verticalPage)`: page 1 **Controls** (End / Pause / Water Lock / Sub In-Out toggle), page 2 **Metrics** (elapsed time, HR with animated heart, distance, cal, current speed; `TimelineView` for always-on; luminance-reduced variant), page 3 **Events** (Flag ⚑, Goal Us, Goal Them, My Goal/Assist buttons + event count).
- **Flag interaction:** giant ⚑ button; on watchOS 11+ also `.handGestureShortcut(.primaryAction)` so a **double-tap flags a moment hands-free**; every event gives `WKInterfaceDevice.play(.success)` haptic + brief overlay confirmation.
- **Sub tracking:** Sub Out pauses the route relevance (bench time excluded from analytics via subIn/subOut events; workout keeps running), button flips to Sub In.
- **Summary screen** after End: duration, time on pitch, distance, avg HR, runs, sprints, events count, then "Save" (already saved; dismiss) matching Apple's summary aesthetic.
- Water lock via `WKInterfaceDevice.current().enableWaterLock()`; session survives app backgrounding (workout-processing background mode); state restoration via `ExtensionDelegate`-equivalent `WKApplicationDelegateAdaptor` handing `HKWorkoutSession` recovery.

## iOS app UX contract

Tab bar: **Matches**, **Fields**, **Team**, (Settings via toolbar).
- Matches list (HK soccer workouts joined with MatchRecords) → Match detail: header stats, segmented views — Heatmap (field-relative Canvas render over a soccer-pitch drawing + optional MapKit satellite overlay), Runs (list + map polylines colored by intensity), Workrate (Swift Charts: distance/min bars, speed-zone donut, HR line), Position (role/side badge + mean-point diagram per period), Events timeline (editable notes, add/remove).
- Fields: map of saved fields (MKMapView/Map with polygon overlays), rename/delete, "Add Field" by drawing corners on satellite map, and **satellite auto-detection** (below): "Scan for fields" button scans the visible map region; detected pitches appear as tappable proposals.

### Satellite field detection (iOS app layer, `SatelliteFieldDetector`)

On-device pipeline, no custom backend or tile scraping:
1. `MKMapSnapshotter` with `MKImageryMapConfiguration` (or `.satellite` map type) renders the
   target region (~600 m square around a center, or current map viewport) at high resolution.
2. CoreImage preprocessing: boost white line contrast (low-saturation high-brightness mask)
   over green turf.
3. Vision `VNDetectContoursRequest` → closed contours → filter to convex quadrilaterals;
   score candidates by aspect ratio, line whiteness along edges, interior greenness.
4. Convert pixel corners → geo-coordinates using the snapshot's region affine mapping
   (inverse of `MKMapSnapshot.point(for:)`).
5. Corners → `FieldGeometry.fitOrientedRectangle` → the standard pitch-dimension sanity check
   → `FieldModel(source: .satellite)` proposal; user confirms before save (same confirmation
   flow as GPS-inferred fields).

Also used to *snap* GPS-inferred fields: after `recordObservation` proposes a field, the
detector runs on that location and, when a satellite rectangle overlaps ≥70%, replaces the
noisy GPS rectangle with the crisp satellite one. Detection is best-effort: failures fall
back silently to the GPS/trained geometry. watchOS never runs this (no snapshotter there).

The same detector powers **on-device community seeding** (`NearbyFieldSeeder`, iOS): tile a
~1.5 km radius around the user, scan un-visited tiles (30-day scanned-region log in the app
group), dedupe against known fields/prior seeds, then contribute new detections to the backend
as `source: satellite, observationCount: 0` community seeds (Settings toggle, upload queue) and
surface them locally as adoptable proposals. This is phase 1 of BACKEND_UPGRADE_PROMPT_V2 §8 —
client-side seeding has no imagery-licensing problem; the server-side batch pipeline for
unvisited venues remains phase 2.
- Team: enter team code, roster stats table from backend (`teamStats`), local fallback message when offline.
- Upload: automatic after a new match arrives; manual re-upload per match. Settings: server URL override, player name, team code.

## Roadmap-wave additions (binding, 2026-07)

New public Kit API for the roadmap implementation waves. Same rule: signatures are frozen once
written here; extend additively.

```swift
// MARK: Sport profiles (multi-sport core)
public struct SportProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String                     // "soccer", "lacrosse", "fieldHockey", "rugby", "ultimate"
    public var displayName: String
    public var workoutActivityTypeRawValue: UInt   // HKWorkoutActivityType.rawValue (Kit stays HK-free)
    public var typicalLengthRange: ClosedRange<Double>   // meters, plausibility + inference bounds
    public var typicalWidthRange: ClosedRange<Double>
    public var positionRoles: [String]        // sport-specific role vocabulary, ordered GK->FWD-like
    public var eventVocabulary: [MatchEventKind]  // kinds this sport's UI offers
    public static let soccer: SportProfile    // + lacrosse, fieldHockey, rugby, ultimate presets
    public static let all: [SportProfile]
}
// FieldModel gains `public var sportID: String?` (nil = soccer, wire "sport_id").
// MatchRecord gains `public var sportID: String?` (same default).
// MatchEventKind gains referee/multi-sport cases: yellowCard, redCard, foul, turnover, timeout
// (raw strings match case names; all optional in UIs via eventVocabulary).
// FieldGeometry.isPlausiblePitch + inferFieldRectangle gain an optional `sport: SportProfile = .soccer` parameter.
// PositionAnalyzer gains `sport:` parameter mapping folded-axis logic onto profile.positionRoles
// (roles list is ordered defensive->offensive; GK-like role only when profile.positionRoles.first is a keeper role).

// MARK: Automatic period detection
public struct PeriodDetectorConfiguration: Sendable {
    public var minimumBreak: TimeInterval        // default 300 (halftime-ish)
    public var maximumBreak: TimeInterval        // default 1500
    public var expectedPeriods: Int              // default 2
    public init()
}
public enum PeriodDetector {
    /// Infers periodStart/periodEnd events from sustained whole-team-off signals available to
    /// one device: long gaps where the wearer is off-pitch or stationary-at-edge AND HR decays,
    /// clustered around the match midpoint. Returns only events when none exist (source .automatic).
    public static func detectPeriods(track: [TrackPoint], events: [MatchEvent],
                                     projector: FieldProjector?,
                                     configuration: PeriodDetectorConfiguration) -> [MatchEvent]
}

// MARK: Sensor-fusion track smoothing
public struct HeadingSample: Codable, Sendable {   // from CMDeviceMotion on watch
    public var timestamp: Date
    public var headingDegrees: Double
    public init(timestamp: Date, headingDegrees: Double)
}
public enum TrackSmoother {
    /// Fuses GPS points with device-heading samples: constant-velocity interpolation between
    /// fixes, heading-consistent turn sharpening, accuracy-weighted smoothing. Output has
    /// >= input point count; safe no-op when headings is empty.
    public static func fuse(track: [TrackPoint], headings: [HeadingSample]) -> [TrackPoint]
}
// MatchRecord gains `public var headings: [HeadingSample]?` (wire "headings", optional).

// MARK: Live streaming (watch -> phone during a match)
public struct LiveMatchUpdate: Codable, Sendable {
    public var sequence: Int
    public var timestamp: Date
    public var elapsed: TimeInterval
    public var heartRate: Double?
    public var distanceMeters: Double
    public var currentSpeed: Double?
    public var onPitch: Bool
    public var latestPoints: [TrackPoint]     // small delta batch (<= ~10)
    public var newEvents: [MatchEvent]        // delta since last update
    public var score: (us: Int, them: Int)? -> encode as two optional Ints usGoals/themGoals
    public init(...)                          // memberwise
}
// Sent via WCSession.sendMessage (reachable) with transferUserInfo fallback, key "liveUpdate"
// = JSON Data, every ~5 s while phone reachable. Phone renders a Live tab on the match list.

// MARK: Offline upload queue
public struct PendingUpload: Codable, Identifiable, Sendable {
    public var id: UUID; public var kind: Kind; public var payloadJSON: Data
    public var attempts: Int; public var nextAttempt: Date; public var lastError: String?
    public enum Kind: String, Codable, Sendable { case match, fields }
}
public final class UploadQueue {
    public init(directory: URL, client: APIClient)
    public private(set) var pending: [PendingUpload] { get }
    public func enqueue(match: MatchPayload) throws
    public func enqueue(fields: [FieldModel]) throws
    /// Attempts everything due; exponential backoff 1min * 2^attempts capped 6h; returns remaining count.
    @discardableResult public func flush() async -> Int
}
// UploadService routes ALL posts through the queue; Settings shows pending count.

// MARK: Exporters
public enum MatchExporter {
    public static func gpx(track: [TrackPoint], events: [MatchEvent], startDate: Date) -> String
    public static func csv(track: [TrackPoint]) -> String
    public static func eventsCSV(events: [MatchEvent]) -> String
}

// MARK: Teams, chat, formation (client side of new backend endpoints; see BACKEND_UPGRADE_PROMPT_V2)
public struct TeamMembership: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    public var code: String
    public var name: String?
    public var displayInitialsOnly: Bool      // minors-privacy option, wire "initials_only"
}
// SettingsStore holds [TeamMembership]; MatchRecord.teamCode picks which team a match belongs to.
public struct MatchComment: Codable, Identifiable, Sendable {  // wire snake_case
    public var id: UUID; public var matchUUID: UUID; public var author: String
    public var body: String; public var postedAt: Date
}
public struct TeamFormation: Codable, Sendable {               // backend-computed
    public var name: String                    // "4-4-2"
    public var confidence: Double
    public var slots: [Slot]                   // player -> normalized mean point
    public struct Slot: Codable, Sendable { public var playerName: String; public var x: Double; public var y: Double; public var role: String }
}
// APIClient gains: comments(match:) / postComment(_:) / formation(code:matchWindow:) /
// liveTeam(code:) async endpoints per V2 prompt; all throw APIError on non-2xx.

// MARK: Diagnostics
public enum MatchLog {   // thin os.Logger facade; NEVER logs coordinates or health values
    public static func info(_ message: String, category: String)
    public static func error(_ message: String, category: String)
}
```

App-layer roadmap items and where they live:
- **Widget extension** `MatchTracker Widgets` (new watchOS WidgetKit extension target): Start-Match
  complication (deep link `matchtracker://start`) + last-match-stats Smart Stack widget reading a
  `LastMatchSnapshot` JSON the watch app writes to the app group after each match.
- **Referee mode** (watch): toggle in settings; session UI swaps Events page vocabulary to
  cards/fouls via `SportProfile`-style event list, hides player analytics on summary.
- **Double-tap remap** (watch): setting `doubleTapAction` (flag|subToggle|goalUs) applied where
  `.handGestureShortcut` is attached.
- **StoreKit** (iOS): `EntitlementStore` (StoreKit 2, product `com.nicemohawk.MatchTracker.team.monthly`,
  local `MatchTracker.storekit` config for testing); team tabs beyond 1 membership, live dashboard,
  chat, and formation gated behind `entitled(.team)` with graceful upsell view.
- **Video highlights** (iOS): PhotosPicker import per match; align flags to video time via
  creation-date offset + manual drift slider; scrubbable AVPlayer highlight list.
- **Training load** (iOS): read HK cardio fitness (VO2max) + 28-day soccer-workout load, show
  workrate score in context ("above your 4-week average").
- **Coach view** (iPad): NavigationSplitView dashboard — roster live dots on pitch (via
  `liveTeam`), per-player stat tiles; degrades to last-known data offline.

## Verification commands

```bash
cd MatchTrackerKit && swift test                                    # Kit unit tests
xcodebuild -project MatchTracker.xcodeproj -scheme "MatchTracker" \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project MatchTracker.xcodeproj -scheme "MatchTracker Watch App" \
  -destination 'generic/platform=watchOS Simulator' build
```
