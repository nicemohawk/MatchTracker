# MatchTracker Roadmap — Future Features & Improvements

Prioritized backlog beyond the current 2026 modernization. Effort tags are rough: **S** = days,
**M** = 1–2 weeks, **L** = 3+ weeks / multi-milestone. See "Shipped" below for what the 2026-07
implementation waves already delivered client-side; "Remaining backlog" is what's left, re-tagged
against that baseline.

## Shipped (2026-07 roadmap waves)

- **Live phone-side match dashboard** — `Watch App/LiveStreamer.swift` streams periodic updates
  to `iOS App/LiveMatchStore.swift`, rendered in `iOS App/LiveMatchView.swift`.
- **watchOS Start-Match widget + last-match Smart Stack stats** — `Watch Widgets/`
  (`StartMatchWidget.swift`, `LastMatchWidget.swift`, `WidgetsBundle.swift`).
- **Automatic period detection** — `MatchTrackerKit/Sources/MatchTrackerKit/PeriodDetector.swift`,
  wired into `Watch App/WorkoutManager.swift` at match end.
- **Referee mode** — watch settings (`Watch App/WatchSettings.swift`) plus session UI in
  `ControlsView.swift`, `EventsView.swift`, `StartView.swift`, `SummaryView.swift`.
- **Double-tap gesture customization** — `Watch App/WatchSettings.doubleTapAction`, configurable
  in `WatchSettingsView.swift`, honored in `ControlsView.swift`/`EventsView.swift`.
- **GPS + heading sensor fusion** — `MatchTrackerKit/Sources/MatchTrackerKit/TrackSmoother.swift`
  fuses `Watch App/HeadingRecorder.swift` samples; smoothing is applied at analysis time on the
  phone via the optional `headings` array on `MatchRecord`/`Track` (`Track.swift`).
- **Video timestamp highlight sync (initial version)** — `iOS App/VideoHighlightsSection.swift`.
- **Fatigue/tactical 15-minute breakdown** — `iOS App/WorkrateSection.swift`.
- **Confidence-weighted field editor with corner nudging** — `CornerEditorView` in
  `iOS App/FieldSheets.swift`.
- **Comparative heatmap overlay** — season-average comparison in `iOS App/HeatmapSection.swift`.
- **GPX/CSV export** — `iOS App/ExportMenu.swift` driving
  `MatchTrackerKit/Sources/MatchTrackerKit/Exporters.swift` (`MatchExporter`).
- **Coach live dashboard (client side)** — `iOS App/CoachDashboardView.swift`; server endpoints
  per `docs/BACKEND_UPGRADE_PROMPT_V2.md`.
- **StoreKit team subscription** — `iOS App/EntitlementStore.swift`, `iOS App/PaywallView.swift`,
  `MatchTracker.storekit`.
- **Minors privacy: initials-only, guardian consent, deletion request** —
  `iOS App/SettingsView.swift` + `iOS App/TeamView.swift`, backend per
  `docs/BACKEND_UPGRADE_PROMPT_V2.md` §5.
- **Team chat (client side)** — `iOS App/TeamChatView.swift`; `match_comments` table per
  `docs/BACKEND_UPGRADE_PROMPT_V2.md` §2.
- **Multi-team support** — `iOS App/SettingsStore.swift` (`teamMemberships`) +
  `iOS App/TeamView.swift`.
- **Multi-sport core** — `MatchTrackerKit/Sources/MatchTrackerKit/SportProfile.swift`; watch sport
  picker in `Watch App/WatchSettingsView.swift`. Note: analysis screens (`HeatmapSection`,
  `PositionSection`, `LiveMatchView`, `CoachDashboardView`, `FormationView`) still render soccer
  pitch geometry (`SoccerPitch.swift`) for all sports — see follow-up in the backlog below.
- **HealthKit training load / VO2max context** — `iOS App/TrainingLoadService.swift`, consumed by
  `iOS App/WorkrateSection.swift`.
- **Offline upload queue with retry/backoff** —
  `MatchTrackerKit/Sources/MatchTrackerKit/UploadQueue.swift`, driven by
  `iOS App/UploadService.swift` with a pending-uploads indicator in `iOS App/SettingsView.swift`.
- **Background refresh reconciliation** — `BGAppRefreshTask` registration in
  `iOS App/MatchTrackerApp.swift`.
- **Structured logging** — `MatchTrackerKit/Sources/MatchTrackerKit/MatchLog.swift`; documented
  contract to exclude location/health values from log messages.
- **Formation detection (client side)** — `iOS App/FormationView.swift` renders backend-computed
  formations; clustering itself runs server-side per `docs/BACKEND_UPGRADE_PROMPT_V2.md` §3.

## Remaining backlog

### Analysis & visualization

- **ML position/formation detection, server-side clustering (L).** `iOS App/FormationView.swift`
  already renders a formation fetched from the backend, but the clustering pipeline itself
  (aggregating `PositionEstimate`s across devices for a shared `field_uuid`/time window) is spec'd
  but not yet built — see `docs/BACKEND_UPGRADE_PROMPT_V2.md` §3.
- **Server-side satellite seeding of the community field database (L).** On-device satellite
  detection (`SatelliteFieldDetector`: `MKMapSnapshotter` + Vision contour heuristics) already
  snaps inferred/trained rectangles to painted lines for a field a user has visited — extend
  this server-side so unvisited venues can be pre-seeded into `/fields/nearby` from satellite
  tiles alone, without waiting for a device to walk or play there. Spec'd in
  `docs/BACKEND_UPGRADE_PROMPT_V2.md` §8; needs server-side tile fetching/licensing and a batch
  detection pipeline.
- **Detection-quality improvements for satellite pitch detection (M).** Replace
  `SatelliteFieldDetector`'s contour-heuristic line detection with an ML pitch-marking
  segmentation model for more reliable corner extraction under occlusion, faded lines, and
  non-standard markings — current heuristics are best-effort and silently return no proposal on
  ambiguous imagery.
- **Video auto-sync via audio fingerprinting (new follow-up, M).** The shipped
  `VideoHighlightsSection` syncs highlights to video by timestamp only; add audio-fingerprint
  based alignment so highlight sync survives clock drift without manual offset entry.

### Platform & infrastructure

- **Per-sport pitch drawings + role-aware analysis screens (new follow-up, L).** `SportProfile`
  and the watch sport picker shipped, but `HeatmapSection`, `PositionSection`, `LiveMatchView`,
  `CoachDashboardView`, and `FormationView` all still draw `SoccerPitch` geometry regardless of
  the match's sport. Needs per-sport field diagrams and sport-aware position roles across those
  screens.
- **CloudKit sync replacing custom backend for personal (non-team) data (L).** For users who
  never join a team, sync matches/fields via CloudKit private DB instead of the custom backend —
  removes server dependency for the common single-player case, keeps the backend focused on
  team aggregation. Significant data-layer rework; do after the backend upgrade stabilizes.
- **Server-side field imagery via satellite tile caching (S).** Cache MapKit/Apple Maps satellite
  tiles for trained fields server-side so the Fields tab loads instantly offline instead of
  re-fetching tiles per device. Spec'd in `docs/BACKEND_UPGRADE_PROMPT_V2.md` §9.

### Team & social

- **Live streaming SSE upgrade (V2 stretch, S).** `CoachDashboardView` currently polls the team
  live endpoint; `docs/BACKEND_UPGRADE_PROMPT_V2.md` §1 notes Server-Sent Events as an optional
  stretch goal to replace polling with push updates.
