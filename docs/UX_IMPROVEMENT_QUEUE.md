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
