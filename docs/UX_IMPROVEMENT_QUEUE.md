# UX Improvement Queue

Working queue for the screen-by-screen polish loop. Every screen and element in
the app gets an entry; nothing is skipped. Status: `todo` → `in-progress` → `done`.
Reference apps: The Outsiders (structure/expansiveness), Strava (leaderboards,
social), AllTrails (maps), Apple Fitness/Workout (rings, live metrics, sharing).

## iOS

| Element | Status | Notes |
| --- | --- | --- |
| Team tab — roster/leaderboard | done | Weakest screen. Bare Form + 7-col abbreviated table. Redesign as Strava-style leaderboard cards with rank, initials avatar, hero metric, "you" highlight, metric picker, numeric transitions. |
| Team tab — join/setup flow | done | Text fields exposed at top of form permanently; should collapse into an inviting "join a team" card once configured. |
| Watch app — full visual pass | done | Watch never got the Theme pass. Start/Events/Controls/Summary to Apple-Workout-app quality. |
| Matches list — row press/appear animation | done | scrollTransition subtle rise/fade, pressed-state scale, numericText transitions on live card. |
| Matches list — empty/first-run state | done | First-launch experience: no onboarding exists (missing feature). Design a welcome + permissions primer. |
| Match detail — section entrance choreography | done | Sections pop in all at once; stagger hero ring draw-on, count-up stats. |
| Match detail — comments | done | Comments API exists (Kit) but no UI surfaces it on match detail. Missing feature. |
| Heatmap — hold-to-flip affordance | done | Discoverability: first-view hint, spring on flip. |
| Runs carousel — page indicator & haptic ticks | done (haptic steps already present; verified) | Verify swipe affordance is discoverable; add subtle haptics per step. |
| Fields — drawer content polish | done (custom in-content drawer; tab bar stays reachable) | Row design, empty state, scan progress animation. |
| Fields — field detail / corner editor | done | Corner editor usability pass; magnifier loupe? |
| Settings — visual pass | done | Themed section icons OK to stay plain, but Save affordance + grouped styling review. |
| Paywall — visual pass | done | Should feel premium; review layout, feature list, animation. |
| Backlog import view | done | Progress presentation, celebratory completion. |
| Coach dashboard | done | Timeline density, labeling flow, pitch/timeline transition. |
| Live match view + tab accessory | done | Accessory expanded state richness; live pulse consistency. |
| Formation view | done | Pitch rendering consistency with SoccerPitch. |
| Team chat | done | Bubble styling, input bar, theming. |
| App icon & launch screen | done | Verify they exist and match the new palette. Missing feature? |

## Watch

| Element | Status | Notes |
| --- | --- | --- |
| StartView | done | Format chips, sport picker hierarchy. |
| EventsView (in-game) | done | Button sizing/color semantics, tap feedback, luminance-reduced state. |
| ControlsView | done | Parity with Apple Workout controls page. |
| SummaryView | done | Ring/summary hierarchy, celebration moment. |
| Watch settings | done | Grouping, labels. |
| Widgets/complications | done | Verify against palette; add live-match complication? |

## Missing/incomplete features noticed

- ~~No onboarding/first-run permission primer (iOS).~~ Shipped in wave 2.

## Wave 2 candidates (noticed during wave 1)

- Demo data realism: every generated season match shares one date ("Sun, Jul 12 10:00 AM") and identical distance/duration — vary per index in DemoMatchFactory.
- Watch MetricsView (in-game metrics page) still needs the WatchTheme pass (was outside wave 1 ownership).
- Heatmap toggles band (Overlay on satellite / Compare) reads muddy olive — restyle as chips or quieter rows.
- Settings Player fields lose their labels once filled (bare values in Form) — use explicit labels.
- Comments composer shows even when comments are unavailable — consider hiding or inline-disabling with hint.

## Wave 3 notes (in-game watch walk, first capture)

- In-game metrics page verified: Workout-app quality, semantic tints. Units were MI/MPH — fixed to km/km-h to match iOS.
- The in-game page walk (testWalkInGamePages) lands on the metrics page and horizontal swipes did not switch to events/controls pages — refine navigation (crown/vertical?) next round; events page + goal flash + controls + summary still uncaptured.
- Drawer half-expanded state not yet visually verified (field rows, proposal cards).
- Export/share flow (ExportMenu) unreviewed. iPad width pass unreviewed.

## Wave 4 (in flight)

- Watch in-game fixes from live-capture review: Sub Out tint collision, Flag vs Goal hierarchy, US/THEM score captions, muted metrics palette, events top padding, flash coverage, summary subtitle.
- iOS fixes from live-capture review: Team header/error reconciliation + human copy, comments empty/unavailable styling, "nearest 0 m", drawer action hierarchy + clip + hint, chip-band tint artifact, nav-title scroll collision, export glyphs.

## Next big wave: iPad

- iPad ships the iPhone single-column layout: needs readable max-width / split layouts (Matches, detail sections grid, Fields side panel, coach dashboard already regular-width aware).
- UI-test helpers are iPhone-calibrated: selectTab must handle the iPad top pill; HK sheet "Turn On All" coordinate misses on iPad.
- Walk brittleness: team-code field accumulates across runs (append vs replace) — clear before typing.

## Wave 5 (in flight): benchmark gap #1/#3 — metric credibility + load context

- Kit: SoccerLoadMetrics (FIFA-convention bands: HSR 19.8–25.2 km/h, sprint >25.2 km/h,
  accel/decel efforts ±3.0 m/s² debounced, distance-per-minute, top speed) + tests.
- iOS: "Match Load" grid in WorkrateSection + acute:chronic (7v28) load context line.
- Later gaps (benchmark §4): video capture/highlight MVP, community flywheel
  (peer-cohort benchmarking), ball-skill metrics decision. Landscape iPad review
  requires a manually rotated sim (headless rotation documented as blocked).

## Waves 5–7 shipped (benchmark-driven)

- Wave 5: SoccerLoadMetrics (FIFA bands) + Match Load grid + 7D:28D acute:chronic context.
- Wave 6: sideline video MVP (import, event auto-clips, boundary playback, trim export, sync nudge).
- Wave 7: peer-cohort benchmarking (Kit wire type + endpoint, "How you compare" percentile card
  with quiet growth state, backend prompt §12 w/ k-anonymity).
- Remaining: video capture phase 2 (in-app AVCapture w/ wall-clock start, montage export,
  data overlays); ball-skill metrics strategic decision (benchmark §4.5); iPad landscape
  visual review (needs manually rotated sim); backend implementation of §12.

## Wave 9 shipped: long-tail traversal complete

- iOS sheets: FieldDetailSheet (hero + badges + mini-stats + action rows w/ delete confirm),
  AcceptProposalSheet (dashed satellite motif, truthful what-happens copy), GuardianConsentSheet
  (compact dark .medium sheet). Captured (36b) and verified.
- Watch: FieldTrainingView reskin (touchline-walk steps, live walk stats, success state);
  referee events variant to the wave-4 bar (Yellow/Red hero cards). Captured (67/68/68b),
  referee mode verified ON in-capture and left OFF after.
- Test infra: watch Form toggles need right-edge coordinate taps (switch.tap() hits the label);
  hard assertions prevent wrong-mode captures.
- Every screen/sheet/mode on both platforms has now had a design pass + live capture review.
  Accepted-manual leftovers: widget gallery visuals, iPad landscape (headless rotation blocked).

## Wave 10 shipped (user-driven Fields redesign)

- Fields tab: custom drawer DELETED. Standard patterns: control column (locate/zoom/style),
  "N fields" pill -> standard sheet, Add Field + Scan capsules, scan-result banner (never
  silent), single dismissible empty hint. Light + dark capture-verified.
- Detector rebuilt: VNDetectRectangles candidates + grass/line-ridge scoring, multi-scale;
  validated on real complexes (3/3 found, 2 negative controls clean, <1.6s).
- Add Field: one locate button; opens on the region framed in Fields; adjust phase — after
  4th corner, draggable numbered handles fine-tune before save (-AddFieldSeedCorners DEBUG
  hook for deterministic capture).

## Wave 11 shipped: performance — buttery first load, match start, maps, data loads

- iOS cold launch: MatchStore.init no longer decodes 330 per-match record files on main pre-paint
  (snapshot-only hydrate; records decode off-main and attach post-paint; refresh() awaits the
  init attach so launch-present records never read as "newly arrived"). Badge cache decodes
  async with a race gate (loadedBadge) so early rows never take the cold path. Summary + badge
  cache writes debounced (1s/1.5s) + off-main, flushed on scenePhase.background; per-render
  O(n) matchesSignature hash replaced by MatchStore.contentVersion.
- iOS analysis: computeAnalytics is a pure nonisolated pipeline on a detached task (inputs
  snapshotted on main incl. FieldsModel-dependent field resolution; publishes back with
  analyticsRevision). Field-save invalidation reanalyzes with yields + coalescing instead of a
  synchronous storm. Compare cohort cached in @State keyed on (compare, window, analyticsRevision)
  — was recomputed per render under a repeatForever pulse; venue map memoized in MatchStore
  (was O(fields²) built twice per call).
- iOS maps: satellite heat cells + pitch outline built once per (rectangle, grid) instead of
  ~600 MapPolygons per body pass; FieldBoundsEditor camera tick scoped to the handle overlay
  via CameraTicker (whole-Map re-render per pan frame eliminated); Route overlay coords cached.
- Watch: optimistic match start — live UI appears right after startActivity; beginCollection
  completes behind it (failure tears down to the start screen); in-progress persist moved to a
  serial utility queue (ordered writes, clear-behind-pending). Launch primes the field store
  off-main and runs HK auth + session recovery concurrently. Fields mirror: single replaceAll
  persist (no per-field pretty-printed writes), decode on WCSession queue, no-op mirrors don't
  bump fieldsRevision (no spurious location lookups). Metrics page: 1Hz elapsed-time subview
  (was 20Hz whole-page rebuild); HKUnits cached. Match end: summary appears before
  endCollection/analytics; runs detected once (summaryRunCounts, "--" while computing) —
  SummaryView no longer re-runs RunDetector per body; record transfer encodes off-main.
- Kit: FieldStore.replaceAll (single persist, additive) + test; on-disk fields JSON no longer
  pretty-printed. 145 Kit tests green.
- Validated: iOS + watch builds, cold-launch/cohort UI test on the real 330-match sim, all 4
  watch smoke tests (incl. in-game walk through the reworked start/end lifecycle).
