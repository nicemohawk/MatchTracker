# MatchTracker Roadmap — Future Features & Improvements

Prioritized backlog beyond the current 2026 modernization. Effort tags are rough: **S** = days,
**M** = 1–2 weeks, **L** = 3+ weeks / multi-milestone.

## On-watch experience

- **Live phone-side match dashboard via WatchConnectivity streaming (M).** Stream periodic
  `TrackPoint`/HR/event deltas from watch to phone during an active match (not just at the end)
  using `WCSession.sendMessage`/`updateApplicationContext`, so a coach or parent on the sideline
  can watch live distance, HR, and events on the phone without waiting for workout end.
- **watchOS widget/Smart Stack complication to start a match (S).** A `WidgetKit` complication
  that surfaces "Start Match" and, when a match is scheduled, jumps straight into the countdown
  screen — removes the app-launch step on match day.
- **Smart Stack / complications for next match + last match stats (S).** Relevance-driven
  complication that shows the next scheduled match countdown, then flips to last match summary
  (distance, time on pitch, goals) after a match ends.
- **Automatic period detection from clustered bench time (M).** Infer half/period boundaries
  from GPS stillness + `subOut`/`subIn` clustering when the wearer doesn't manually tag
  `periodStart`/`periodEnd`, so stats are still period-aware for players who forget to tag.
- **Referee mode (M).** Alternate watch flow for officiating: card/foul event types, running
  match clock with stoppage time, no GPS-based player analytics — different event vocabulary and
  summary screen, same recording infrastructure.
- **Double-tap gesture customization (S).** Let users remap the hands-free double-tap action
  (currently hardcoded to Flag) to Sub In/Out or Goal, since not everyone flags moments as their
  primary in-match action.

## Analysis & visualization

- **GPS + heading sensor fusion for sharper heatmaps (M).** Blend `CMDeviceMotion`/compass
  heading with GPS in `MatchTrackerKit` to reduce heatmap smear during rapid direction changes —
  GPS alone under-resolves sharp cuts common in soccer.
- **Post-match auto-tagging of flagged moments with video timestamp sync (L).** If the user
  records match video separately (or via a paired iPhone camera), align `MatchEvent.flag`
  timestamps to video wall-clock time and generate a scrubbable highlight list — needs a video
  import/sync UI and clock-drift correction.
- **ML position/formation detection across the team (L).** Once multiple players on one team
  upload matches for the same `field_uuid`/time window, cluster `PositionEstimate`s across
  devices to infer the team's formation (4-4-2, 4-3-3, etc.) and flag positional drift — requires
  backend-side cross-device aggregation, not just on-device analytics.
- **Fatigue/tactical-period breakdown (S).** Extend `WorkrateReport` presentation to show
  workrate score per 15-minute bucket, surfacing second-half drop-off directly in the Workrate
  tab (data already exists in `distancePerMinute`; this is UI-only).
- **Field boundary extraction from satellite imagery (L).** Auto-detect pitch markings
  (touchlines, penalty boxes, center circle) from aerial/satellite tiles around a field's known
  center and snap inferred/trained rectangles to the painted lines — turns a rough
  GPS-observed rectangle into survey-grade geometry and can seed the community field database
  for venues nobody has trained yet. Needs an on-device or server-side vision model and tile
  licensing review.
- **Confidence-weighted field editor (M).** In the Fields tab, surface each field's provenance
  (trained vs. inferred vs. community) and confidence, render low-confidence edges differently,
  and let users nudge individual corners on the satellite map — manual corrections upload as
  high-weight observations that anchor the community geometry.
- **Comparative heatmap overlay (S).** Overlay two matches' heatmaps (e.g. this match vs.
  season average) on the same field diagram to spot positional habit changes.
- **Export match to GPX/CSV (S).** Share sheet action from Match Detail exporting track +
  events, for users who want to run their own analysis or import into third-party tools.

## Team & social

- **Coach iPad view with all players live (L).** iPadOS layout (or a lightweight web dashboard
  backed by the new `/teams/{code}/stats` and streaming endpoints) showing every rostered
  player's live position dot and vitals during a match — needs the live-streaming backend work
  and a multi-device aggregation view.
- **StoreKit subscription for team features (M).** Gate roster stats, live dashboard, and
  multi-team support behind a subscription; free tier stays solo-player local analytics only.
  Needs `StoreKit 2` integration and a backend entitlement check.
- **Privacy controls for minors on teams (M).** Many soccer teams are youth teams; add a consent
  flow (parent/guardian acknowledgment), option to display initials instead of full name on
  team stats, and a data-deletion request path — treat as a compliance requirement, not just a
  feature, before shipping team stats broadly.
- **Team chat / match commentary thread (M).** Lightweight per-match comment thread (backend:
  new `match_comments` table) so parents/coaches can react to a match without leaving the app.
- **Multi-team support per player (S).** A player who plays club and school currently has one
  `team_code` on their profile; let a device belong to multiple teams and tag each match with
  which team it was played for.

## Platform & infrastructure

- **Multi-sport support: lacrosse, field hockey, rugby, ultimate (L).** Generalize
  `MatchTrackerKit`'s field/position/workrate model behind a sport profile (field dimensions,
  position roles, event vocabulary differ per sport) — biggest architectural lift on the
  backlog; touches `FieldModel`, `PositionRole`, `HKWorkoutActivityType`, and every analysis
  screen.
- **HealthKit training load / VO2max integration (M).** Pull `HKQuantityType` training-load and
  cardio-fitness samples to contextualize workrate score against the player's broader fitness
  trend, not just single-match numbers.
- **CloudKit sync replacing custom backend for personal (non-team) data (L).** For users who
  never join a team, sync matches/fields via CloudKit private DB instead of the custom backend —
  removes server dependency for the common single-player case, keeps the backend focused on
  team aggregation. Significant data-layer rework; do after the backend upgrade stabilizes.
- **Offline upload queue with retry/backoff (S).** `APIClient` currently assumes connectivity at
  upload time; add a persistent queue (app group storage) that retries failed uploads with
  exponential backoff and surfaces a "pending uploads" indicator in Settings.
- **watchOS/iOS background App Refresh reconciliation (S).** Periodically reconcile the phone's
  match list against HealthKit + pending `MatchRecord` transfers in case a `transferFile` was
  dropped, so a match doesn't silently vanish if the watch-to-phone handoff fails mid-transfer.
- **Server-side field imagery via satellite tile caching (S).** Cache MapKit/Apple Maps satellite
  tiles for trained fields server-side so the Fields tab loads instantly offline instead of
  re-fetching tiles per device.
- **Structured logging + crash reporting (S).** Add lightweight, privacy-respecting diagnostics
  (no location data in logs) to both targets — currently no visibility into watch-side
  `HKWorkoutSession` failures in the field.
