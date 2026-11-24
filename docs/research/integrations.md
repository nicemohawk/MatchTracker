# Integrations: what to build, and how

Researched 2026-11-23 against the working tree on `claude/apple-watch-sports-app-1224d7`
(including its uncommitted recorder changes), the Xcode 27.2 SDK headers, Apple documentation and
vendor documentation. Deployment targets stay at **iOS 17.0 / watchOS 10.0**. Anything newer below
is `#available`-gated.

Confidence labels: **[doc]** primary documentation or SDK header, **[forum]** Apple DTS/vendor
forum, **[second-hand]** press or search summary, **[verify]** needs a device test.
Nothing here was built or run. Effort: S = about a day or less, M = 2-5 days, L = 1-2 weeks.

## 1. Conclusions

1. **Writing a correct HKWorkout does not get a match into Strava.** Strava's support article says
   only workouts recorded with Apple's native Workout app in the last 30 days sync from Health.
   "Activities uploaded to Apple Health from an app made by another company will not sync."
   [doc] Metadata cannot change this. The routes are file export, a bridge app (HealthFit, RunGap),
   or Strava's upload API.
2. **Do not start with the Strava API.** It needs a subscription, a server-side secret, and a review
   to pass 10 athletes. A good TCX file plus Strava's web upload page needs none of them.
3. **Best value for effort is on-device**: HealthKit workout quality, Action button/Siri, effort
   score, TCX export. All four need no owner account work and can be built now.
4. **Garmin is closed, TrainingPeaks is partner-only, Veo has no public API we could find.** Skip.
5. **Fixtures should come from the iOS calendar**, not from TeamSnap/Spond APIs. Both already put
   events there.

## 2. Ranked plan

| # | Integration | Value | Effort | Owner must supply | Test today? |
|---|---|---|---|---|---|
| 0 | Fix prerequisites (section 4) | High | S | nothing | Unit + sim |
| 1 | HealthKit workout quality: external UUID, brand, halves as segments, goals as markers | High | S | nothing | Sim + device |
| 2 | Action button, Siri, Shortcuts, Pause/Resume intents | High | S-M | nothing | Sim; Ultra for the button |
| 3 | TCX export + richer GPX, "Upload to Strava" help | High | S-M | nothing | `swift test` |
| 4 | Effort score (feeds Apple's effort UI) | High | S | nothing | Device |
| 5 | Mirroring + Live Activity | High | M-L | new extension App ID (automatic signing) | UI in sim; mirroring on device only |
| 6 | Calendar fixtures (EventKit) | High | M | nothing | Sim |
| 7 | iOS home/lock/StandBy widgets, Control Center | Medium | S-M after 5 | shares 5's App ID | Sim |
| 8 | Match-day photos (PhotosPicker) | Medium | S | nothing | Sim |
| 9 | Weather | Medium | S | WeatherKit capability on App ID | Mapping only |
| 10 | Start match from iPhone | Medium | S | nothing | Paired devices |
| 11 | Spotlight | Low-Med | S | nothing | Sim |
| 12 | Intervals.icu | Low-Med | M | OAuth app + server secret | Client with stub server |
| 13 | Strava API upload | High for Strava users | L | subscription, API app, review, broker | Client with stub server |
| 14 | Runalyze | Low | S-M after 12 | emailed app registration | Stub |
| - | Focus filter, State of Mind, SharePlay | Low | S / S / L | SharePlay capability | Not recommended now |
| - | WorkoutKit, Garmin, TrainingPeaks, Veo API, MusicKit, CarPlay app | None/blocked | - | - | Skip |

Suggested order: 0, 1, 2, 3, 4 as one release; 5 and 7 as the next; then 6, 8, 9, 10.

## 3. What exists

| Area | State |
|---|---|
| Export | GPX 1.1 (positions + time, events as waypoints), track CSV, events CSV. **No TCX or FIT.** GPX has no `<name>`, `<type>`, `<ele>` or heart rate. |
| HealthKit write | Watch saves the workout and a route. `finishRoute(with:metadata: nil)`, and no `addMetadata`, `addWorkoutEvents` or activities in the recorder (only the debug diagnostic import adds metadata). |
| HealthKit read | iPhone reads workouts, routes, HR, energy, distance. |
| Widgets | One **watchOS** extension: StartMatch (circular/corner), LastMatch (rectangular/inline). **No iOS widget extension.** |
| Live | `LiveStreamer` -> `WCSession` every 5 s (30 s `transferUserInfo` fallback) -> `LiveMatchStore`. No mirroring, no ActivityKit. |
| Double tap | Already done (`handGestureShortcut`, gated to watchOS 11) in `ControlsView`, `EventsView`. |
| Photos | `PhotosPicker` for sideline video; add-only save. |
| Deep link | `matchtracker://start` through `widgetURL` on the watch. No `CFBundleURLTypes` on either app, and no iOS `onOpenURL`. Enough for widgets, not for OAuth or links. |
| Entitlements | HealthKit, App Group on all; CloudKit on iOS. No WeatherKit, Group Activities, push. |
| Intents, EventKit, WeatherKit, Spotlight, ActivityKit | None. |

The Xcode project uses file-system-synchronized groups, so a new file in an existing folder needs no
`project.pbxproj` edit. A new target (item 5) does.

## 4. Prerequisites found while reading (fix first)

1. **A second live match can be ignored.** `LiveMatchStore.endSession()` has no callers, and
   `LiveStreamer.start` resets `sequence` to 0 each match. `ingest` drops
   `sequence <= latest.sequence`, so if the phone app stays alive the next match is dropped until
   it passes the previous sequence. Old events and points also persist. Add an optional `matchID`
   to `LiveMatchUpdate`, reset the store when it changes, and call `endSession()` after a
   `.matchEnd`. A Live Activity needs that ID too.
   Keep the field optional so old payloads decode, and strip it before backend relay if the server
   does not expect it.
2. **VO2 max is read without being requested.** `TrainingLoadService` queries `.vo2Max`, which is
   not in `HealthKitService.readTypes`, so on normal installs it cannot return data. Add it there.
3. **No source or overlap de-duplication.** `fetchSoccerWorkouts()` returns every `.soccer` workout
   from every source. If a match reaches Strava and the user enables Strava's "Send to Health",
   a second soccer workout can come back as a ghost row. The same happens when two apps record the
   match. In `MatchStore.refresh`, when two workouts overlap by at least 80% of the shorter one,
   keep ours (`sourceRevision.source.bundleIdentifier` prefix `com.nicemohawk.MatchTracker`), then
   the one with a record, then the one with a route. Put the pure overlap rule in the Kit and unit
   test it. Never delete the other app's sample. Must land before any Strava work.
4. **Non-soccer sports do not read back.** The watch can record other `SportProfile` activity types,
   but the phone predicate is `.soccer` only. Such matches rely on the record alone.
5. **`ExportMenu` writes files from `body`.** `ShareLink(item: stagedFile(...))` serializes on every
   evaluation. Use `Transferable` with `FileRepresentation(exportedContentType:)`, which is lazy.

## 5. Implementation notes

### 5.1 HealthKit workout quality (build first)

**Files:** `Watch App/WorkoutManager.swift` (`save`, `saveWorkout`), a new pure mapper in the Kit,
tests; read-back in `iOS App/MatchStore.swift`.

In `saveWorkout`, between `endCollection(at:)` and `finishWorkout()`:

```swift
try await builder.addMetadata([
    HKMetadataKeyExternalUUID: match.id.uuidString,
    HKMetadataKeyWorkoutBrandName: "MatchTracker"
])
try await builder.addWorkoutEvents(workoutEvents)   // segments for halves, markers for goals
```

| Field | Use |
|---|---|
| `HKMetadataKeyExternalUUID` | `match.id`. Gives `adoptOrphanRecords` an exact join instead of +/-3 minutes. Check it first, keep the heuristic for old data. Biggest win here. |
| `HKMetadataKeyWorkoutBrandName` | String [doc]. Apple does not document where Fitness displays it [verify]. Do not put scores or opponent names in it. |
| `HKMetadataKeyIndoorWorkout` | Already expected by `adoptOrphanRecords`; the configuration's `locationType` should supply it. Verify on a saved workout before setting it by hand. |
| `HKMetadataKeyTimeZone` | `TimeZone.current.identifier`. Useful for away matches. |
| `HKMetadataKeyWeatherTemperature` / `Humidity` / `Condition` | Only if known **before** `finishWorkout`; saved workouts are immutable. Humidity is an `HKQuantity` in percent, condition an `NSNumber` of `HKWeatherCondition`. |
| `HKMetadataKeyElevationAscended` | Skip. GPS altitude noise on a flat pitch makes a false climb. The route's `CLLocation`s already carry altitude. |
| `HKMetadataKeyAverageSpeed` / `MaximumSpeed` | Optional, low value. Header documents them mainly for distance workouts. |
| Title | **There is no public workout-title metadata key** in the 27.2 header. Use a private key such as `com.nicemohawk.MatchTracker.format` only for our own read-back. |

**Halves: use `HKWorkoutEvent(type: .segment, dateInterval:metadata:)`, not `HKWorkoutActivity`.**
Only lap and segment events may have duration [doc]. `beginNewActivity` is live, asynchronous,
and changes sensor algorithms; Apple documents it for multisport and intervals. Our halves are
often inferred after the match, so retroactive segments fit, and a missed period tap cannot corrupt
the session. Goals, cards and subs become zero-length `.marker` events with a namespaced metadata
key. Apple documents the API, not how Fitness renders third-party segments. [verify]

Pitfalls:
- `save()` currently runs `saveWorkout` **before** `PeriodDetector`. Either write only manually
  tagged periods, or run detection before finishing. If moved, keep it off-main and keep the
  provisional record write first.
- Wrap metadata and events in their own `do/catch` that only logs. They must never reach the outer
  catch and lose the workout.
- Clamp event dates to `match.start...match.end`. Do not re-add events on the `finishWorkout` retry.
- Do not turn half-time into pause/resume events. That changes duration and route semantics.
- Adding share types raises a new Health sheet. The metadata here needs none.

**Tests:** Kit tests for events -> segments (unclosed period, no periods, extra time, dates outside
the match); sim test that a saved workout reads back its UUID and events.

### 5.2 Action button, Siri, Shortcuts

**Files:** new `Watch App/MatchIntents.swift`, `WorkoutManager` hooks; later
`iOS App/MatchIntents.swift`. `StartWorkoutIntent`, `PauseWorkoutIntent`, `ResumeWorkoutIntent` and
`AppShortcutsProvider` are all watchOS 9 / iOS 16, so **no gating**. [doc]

- `MatchFormatOption: AppEnum` for match, small-sided, indoor. Keep it in the app target; do not
  make the Kit import AppIntents.
- `StartMatchIntent: StartWorkoutIntent`: `@Parameter var workoutStyle`, `suggestedWorkouts` with
  all formats, `displayRepresentation`. Leave `openAppWhenRun` alone (Apple: do not change it).
- `perform()` (`@MainActor`) calls `beginCountdown(field:format:seconds: 0)` and waits for the
  session to be running. Apple allows **30 seconds** to start a session. `startWorkoutSession()`
  launches a detached task, so expose an awaitable start result and throw if it failed.
- Pause and Resume forward to `WorkoutManager.pause()` / `resume()`. On Ultra, Action + side pressed
  together triggers them; without these intents the press is ignored.
- **Next action mid-match is the soccer feature.** Conform `ToggleSubIntent: AppIntent` (logs sub
  on/off) and donate once the session runs:
  `try await StartMatchIntent().donate(result: .result(actionButtonIntent: ToggleSubIntent()))`.
  Offer the same choice as the existing double-tap setting (sub / flag / goal). Referees: flag.
- `AppShortcutsProvider` phrases must include `\(.applicationName)`.

Pitfalls:
- Action-button intents must live in the watch app, not an extension. [doc]
- If the app has never asked for Health access, the button only opens the app. [doc]
- Guard on phase: during `.active`, Start must be a no-op; after `.summary`, do not discard results.
- `beginCountdown` starts HealthKit and GPS at once. A cold launch by URL or intent may not yet be
  frontmost, which is the background-start refusal this code already retries. Test cold start with
  the watch asleep. The same race exists in today's `onOpenURL` path.
- The physical Action button needs an Ultra; Simulator can exercise the intents.

### 5.3 TCX and better GPX

**Files:** `MatchTrackerKit/.../Exporters.swift`, `MatchTrackerKitTests`, `iOS App/ExportMenu.swift`.

Strava accepts FIT, TCX and GPX. Every point needs a time; lat/lng, elevation and HR are optional.
It also reads HR from GPX extensions. [doc] **Choose TCX over FIT**: it carries laps, distance,
calories and HR in text we can golden-test, and Strava requires an ANT+-assigned manufacturer in
FIT. Garmin TCX only allows `Sport` Running, Biking, Other: emit `Other`.

- Add `MatchExporter.tcx(track:heartRate:periods:distanceMeters:activeEnergy:startDate:endDate:)`.
  One `<Lap>` per half, each with `TotalTimeSeconds`, `DistanceMeters`, `Calories`,
  `AverageHeartRateBpm`, `MaximumHeartRateBpm`, `Intensity`, `TriggerMethod` in schema order,
  then `<Track>`. HR-only trackpoints are valid, so **indoor matches can export too**.
- `TrackPoint` has no altitude. Omit it; a flat pitch does not need it.
- GPX additions: `<metadata><name>`, `<trk><name>`, `<type>soccer</type>`, and `gpxtpx:hr` with its
  namespace declaration. Split `<trkseg>` at gaps longer than about 30 s so half-time is not a
  straight line. Bind each point to the nearest HR within 5 s, or omit it; never invent it.
- Keep 0-decimal HR and existing ISO formatting so output stays deterministic. Update goldens.
- Strava's app has no documented file import; web upload is `https://www.strava.com/upload/select`.
  In the export sheet: "Save the TCX, then upload it at strava.com/upload". Strava classifies web
  uploads of `Other` generically, so tell users to set the sport to Soccer.
- Do not put Strava logos in the app for this. Plain factual text is permitted by their guidelines.

### 5.4 Effort score

**Files:** `Watch App/SummaryView.swift`, `WorkoutManager`; or `iOS App/WorkrateSection.swift` and
`HealthKitService`. `HKQuantityTypeIdentifier.workoutEffortScore`, `HKUnit.appleEffortScore()` and
`relateWorkoutEffortSample` are **iOS 18 / watchOS 11**. [doc]

```swift
if #available(iOS 18, watchOS 11, *) {
    let sample = HKQuantitySample(type: HKQuantityType(.workoutEffortScore),
        quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: score),   // 1...10
        start: workout.startDate, end: workout.endDate)
    try await healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil)
}
```

- The DTS example does not save the sample first; `relate` does the association, and the value
  appeared in Fitness ("8 Hard"). It shared and read **both** workout and effort types. [forum]
- **Ask the player.** Do not write our computed workrate as `workoutEffortScore`: it is
  self-reported effort, and training load uses it. Offer the computed score only as a hint, and do
  not write `estimatedWorkoutEffortScore` unless Apple documents third-party use.
- DTS said automatic estimates cover walking, running, hiking and cycling, not soccer [forum, 2024].
  So a soccer match likely has **no effort unless we ask**. That is the reason to build this.
- Training load has **no public API** and no metadata switch. Apple documents that it compares
  7 days with 28. Whether our workouts count is undocumented; check on device. [verify]
- Request authorization lazily on first rating. Adding the type to launch authorization puts a
  Health sheet in front of kick-off.
- Re-rating: `unrelateWorkoutEffortSample`, delete our old sample, then relate the new one.
- Old workouts saved by the watch can be rated from the phone; rate only our own source.

### 5.5 Mirroring and Live Activity

Mirroring: watchOS 10 / iOS 17, so **no gating**. Live Activities: iOS 16.1. Smart Stack layout
(`supplementalActivityFamilies([.small])`): iOS 18. [doc]

The key fact: when a mirrored session starts, the system launches the iPhone app in the background
and grants **one-time permission to start a Live Activity from the background**
(`HKHealthStore.h`). Otherwise ActivityKit needs the foreground. This makes mirroring the trigger,
so do the two together.

**Watch** (`WorkoutManager.startWorkoutSession`): after `startActivity`, and without blocking it,
`try await session.startMirroringToCompanionDevice()`. Failure is logged only. Calling it on an
ended session fails. The existing retry path creates new sessions, so mirror each one.

**iPhone** new `iOS App/MirroredWorkoutService.swift`, installed in `MatchTrackerApp.init` (not a
`.task`): set `workoutSessionMirroringStartHandler`. It may fire repeatedly after reconnects and on
an arbitrary queue, so replace the session and hop to main. Start the activity from the handler.

**Data:** keep `WCSession` for the 5 s stream at first; the phone app launched in the background may
not be `isReachable`, so send the same compact state with `sendToRemoteWorkoutSession(data:)` as
well (limit 100 KB per 10 s, encode without track points). De-duplicate by `matchID + sequence`.
Do not build an `HKLiveWorkoutBuilder` on iPhone: that is iOS 26. The watch owns the workout.

**New target** `MatchTracker iOS Widgets` (app extension, iOS 17.0, embedded in the **iOS** app, not
the watch app), plus `NSSupportsLiveActivities = YES` in `Info.plist` **and `Info-Debug.plist`**,
the App Group entitlement, and Kit linked. Attributes in a file shared by app and extension.

- `MatchActivityAttributes`: static match ID, field, format. `ContentState`: score, period,
  clock anchor, paused value, on/off pitch, distance, HR. Total must stay under **4 KB**.
- Clock: send a start anchor and use `Text(timerInterval:)`. Do not push a tick each second.
- Update on score, period, sub and pause at once; metrics every 15-30 s. `staleDate` at 60-90 s.
- End with a final state (`.default` or `.after`); also reap leftovers from `Activity.activities`
  on launch. Maximum 8 hours active.
- HR on a lock screen is sensitive. Off by default, and `.privacySensitive()`.
- Apple shows Live Activities on a paired Watch and in CarPlay automatically. Two widgets chosen by
  `if #available(iOS 18, *)` in the `WidgetBundle` avoid returning mismatched configuration types.
  Our own watch session will already occupy the wearer's watch, so test how both coexist. [verify]
- Remote updates to other people's phones (parents) need APNs, a push key and server work. Defer.
- Mirroring needs physical devices (Apple's sample says so). Layout works in sim/previews.

### 5.6 Calendar fixtures

**Files:** new `iOS App/FixtureService.swift`, a Kit `Fixture` model and title parser + tests, both
iOS plists, `SettingsView`, `MatchListSupport`.

- iOS 17: `EKEventStore.requestFullAccessToEvents()`, key `NSCalendarsFullAccessUsageDescription`.
  No read-only access exists; missing key means automatic denial. [doc]
- Let the user select calendars (`EKCalendarChooser`), query
  `predicateForEvents(withStart:end:calendars:)` for -7...+60 days, and filter locally by title.
  Use `calendarItemExternalIdentifier` + occurrence start as the key.
- Match a fixture to a recording by start within 90 minutes, plus venue distance when
  `structuredLocation.geoLocation` exists. Suggest; do not silently rename.
- Send upcoming fixtures to the watch in `updateApplicationContext` so Start can show "vs Rovers
  10:30", preselect format and field, and drive a relevant Smart Stack entry.
- **TeamSnap** provides calendar-subscription URLs (emailed from its app). **Spond** writes events
  directly to the iOS calendar. Neither needs an API. Say so in the empty state.
- Saving a new fixture needs only `EKEventEditViewController` and no permission on iOS 17+.
- Privacy: a whole calendar is powerful. Process on device, never upload, ask only on tap.
- An in-app ICS/webcal parser is not worth it: RRULE, time zones and refresh belong to the OS.

### 5.7 iOS widgets and Control Center

Same extension as 5.5. Last Match and Next Fixture in `.systemSmall/.systemMedium`,
`.accessoryRectangular/.accessoryCircular/.accessoryInline`; StandBy reuses `.systemSmall`. iOS 17,
no gating. `LastMatchSnapshot` is written to the **watch's** App Group, which the phone does not
share, so the phone must write its own copy in `MatchStore` after refresh and reload timelines.

Controls (`ControlWidget`): iOS 18 / watchOS 26. [doc] Gate in the bundle. "Start match" on a phone
control should run 5.10; on watch, the 5.2 intent. Smart Stack: add timeline relevance to
`StartMatchWidget` around the next fixture (it currently has one timeless entry).

### 5.8 Match-day photos

**Files:** new `iOS App/MatchPhotosSection.swift`, modeled on `VideoHighlightsSection`.

- Phase 1: `PhotosPicker(matching: .images)` (no permission), read EXIF `DateTimeOriginal` and
  `OffsetTimeOriginal` via ImageIO, and place photos on the match timeline. Copy into App Group
  storage as video does. The picker cannot filter by date or place, so this is not automatic.
- Phase 2, opt-in: `PHPhotoLibrary.requestAuthorization(for: .readWrite)`, `PHAsset.fetchAssets` with
  a `creationDate` predicate from 45 min before to 45 min after. `location` is not a usable fetch
  predicate, so filter in memory within about 500 m, and keep photos without location. `.limited`
  sees only chosen assets.
- `SidelineVideoStore` deliberately avoids full-library access. Keep that stance unless users ask.
  `NSPhotoLibraryUsageDescription` mentions only footage and would need new wording.
- Photos include children. Never upload automatically or attach to team sharing by default.
- **Veo:** no public developer API found. Veo's help says users can download the follow-cam match as
  MP4 from its web app; the existing importer handles the file. A Veo file's creation date may be
  the render or download time, so the manual alignment nudge matters. Allow `.fileImporter` too.

### 5.9 Weather

iOS 16 / watchOS 9, no gating. `WeatherService.shared.weather(for:including:
.hourly(startDate:endDate:))`. History goes back to **1 Aug 2021**, so old matches can be backfilled.
500,000 calls/month are included with membership. [doc]

- **Owner:** enable the WeatherKit capability and App Service on the iOS App ID; Xcode adds
  `com.apple.developer.weatherkit`. Adding the entitlement before that breaks signing.
- Fetch on the phone after import, cache by match UUID, store in a sidecar rather than
  `MatchRecord`. Round the coordinate to about 1 km. Retry lazily and never block match detail.
- HealthKit weather metadata cannot be added to a saved workout. Watch-side fetch at start, with a
  2 s timeout and no retry, is the only way; optional phase 2.
- Must show the Apple Weather mark and legal link (`WeatherService.attribution`).
- Testable now: an injected provider protocol, unit conversion and `WeatherCondition` mapping.

### 5.10 Start from iPhone

`HKHealthStore.startWatchApp(with:)` on iPhone plus
`WKApplicationDelegate.handle(_ workoutConfiguration:)` in `WatchAppDelegate`, which is not
implemented today. The watch must treat this as a start tap and map `locationType == .indoor`.
It cannot carry our format or field, so use the watch's last-used values. Available below our
targets. Needs paired hardware to trust.

### 5.11 Spotlight

`CSSearchableIndex(name:)` is available at iOS 17; index title, date, score, field and opponent, with
domain `match`. Handle `CSSearchableItemActionType` through `onContinueUserActivity` to open the
match. Delete on hide/delete and on the privacy-deletion path. No HR or coordinates. `IndexedEntity`
is iOS 18, so add it only with a `MatchEntity` App Intent. CoreSpotlight is not on watchOS.

### 5.12 Intervals.icu

`POST /api/v1/athlete/0/activities`, multipart, with `name`, `description`, `external_id`; accepts
FIT, TCX, GPX, zipped variants. Personal API keys use Basic auth (`API_KEY` / key); **the vendor says
apps must use OAuth** (`ACTIVITY:WRITE`). [forum] The token exchange takes a client secret within
2 minutes of the code; tokens do not refresh. So it needs the same broker as Strava.

- Owner: register an app in `/settings`, read the API terms, hold the secret on the server.
- Do not ask users to paste personal keys as the shipping design. Good for an owner-only DEBUG test.
- Reuse the TCX from 5.3 and `external_id = match UUID`. Server de-duplication is undocumented; track
  our own success and retry only on timeout after checking.

### 5.13 Strava API

**Terms now in force: API Agreement and API Policy, effective 1 June 2026** (they replaced the
November 2024 regime).

| Rule | What it means here |
|---|---|
| 2.3 Data from a Strava user may be shown only to that user | Never show imported Strava data in team, coach, cohort or community features. |
| 5.3 No AI use: training, inference, grounding, embeddings, context windows, derived data | Never feed Strava-read data to `RunNarrator` or any model. |
| 5.4 No analytics, no combining with other customer data | No imports into workrate, baselines, fields. |
| 5.2 No competitive use | A genuine review risk for an app with activity feeds and leaderboards. |
| 5.5/6.2 No persistent store; cache 7 days; deletions mirrored in 48 h | Do not persist Strava responses. Store only our "sent" flag and external ID. |
| 2.5/7.4 Delete on disconnect, with confirmation | Build Disconnect using `/oauth/revoke`. |
| 5.8 No charging for Strava functionality | Keep it outside the paid team subscription. |
| 5.15 and Strava's 13+ rule | Hide for under-13 and guardian-managed profiles. |
| 5.16 No shared tokens or proxy re-exposure | Broker may serve our own app's users only. |

Agreement 7.1 permits uploading activities. **Upload-only** (`activity:write`) avoids nearly all
of the above, because these restrictions concern data read from Strava. Do not request
`activity:read`. This is a reading of the text, not legal advice.

Access:
- Standard tier: single-player by default; self-service to 10 athletes; review to pass 10, up to
  9,999. Extended tier about 10,000+. Review is discretionary and has **no SLA**.
- Subscription: required for Standard (new apps 1 June 2026, existing 30 June). Strava's developer
  post and Policy exempt Extended; its FAQ says Extended needs it too. Confirm with Strava.
  Press reports about $11.99/month [second-hand].
- Limits: default 200/15 min, 2,000/day overall; non-upload 100/15 min, 1,000/day. At 10 athletes,
  400/4,000 overall. One upload plus 1-3 polls per match is light, though polling is non-upload.

**Secret:** token exchange **and** refresh require `client_secret`; PKCE is not documented. A secret
in the IPA is public, so use the MatchTracker backend as broker:
1. App opens `strava://oauth/mobile/authorize` if available, else `ASWebAuthenticationSession` to
   `https://www.strava.com/oauth/mobile/authorize`. Needs `LSApplicationQueriesSchemes: strava`,
   a registered callback scheme (`CFBundleURLTypes` is absent today), and a random `state`.
2. App sends the code to our server over TLS. Server exchanges and returns tokens, or keeps the
   refresh token. Access tokens last 6 h; each refresh may rotate the refresh token, so store the new
   one atomically.
3. Check the returned `scope`; the athlete can untick `activity:write`.
4. Keep tokens in Keychain. `KeychainHelper` sets no accessibility class; use
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and it needs a delete method.

Upload: `POST https://www.strava.com/api/v3/uploads`, `data_type=tcx`,
**`sport_type=Soccer`** (listed as supported, case-sensitive), `name`, `description`,
`external_id=matchtracker-<uuid>`, `trainer=1` for indoor. Returns an upload ID; poll
`GET /uploads/{id}` at 1 s or slower until `activity_id` or `error`. Use `id_str`.

**Duplicates:** Strava rejects duplicates at processing ("duplicate of activity N"). Treat as success.
The remaining problems are (a) HealthFit/RunGap also uploading the same match; (b) the player also
recording in Apple's Workout app, which Strava auto-imports; (c) Strava writing it back to Health,
handled by section 4.3. Make upload explicit per match first, not automatic. Only `.soccer` maps to
`Soccer`; map other sports explicitly or use `Workout`.

Migration already announced: base URL `api-v3.strava.com` from January 2027; tokens in headers, and
`/oauth/deauthorize` gone by 1 June 2027. Build for the new endpoints.

Owner checklist: Strava subscription, API app, callback domain, secret on server, privacy-policy
text, support contact, "Connect with Strava" assets, reviewer screenshots, review submission.
Buildable now: 5.3 serializer, OAuth state machine against a stub, upload state machine with fake
responses. Not buildable: real OAuth, review, capacity beyond the owner's own account.

### 5.14 Others

| Integration | Verdict |
|---|---|
| **Garmin Connect** | Activity API reads data out; it offers no documented third-party upload. New applications reported paused since spring 2026, still unreopened in October [second-hand, with Garmin forum corroboration]. The Personal API is for a user's own key. Skip. |
| **TrainingPeaks** | API for approved commercial developers; not for personal use. Help page returned 403 to us, so this is from its search extract. TCX export covers users who want it. |
| **Runalyze** | Third-party OAuth with `activity_push`; register by email with callback and logo. Personal tokens are per account. Small audience. Do after Intervals.icu, on the same broker. |
| **WorkoutKit** | iOS 17 / watchOS 10. Sends planned workouts to **Apple's** Workout app, so it bypasses our recorder. Soccer support in `CustomWorkout.supportsActivity` is unverified. Skip for matches; maybe training drills later. |
| **State of Mind** | `HKStateOfMind`, iOS 18 / watchOS 11. Optional post-match mood. Sensitive data, especially for minors. Not now. |
| **SharePlay** | Not on watchOS. Needs the Group Activities capability. Co-reviewing a match is L effort and narrow. Skip. |
| **Focus filter** | `SetFocusFilterIntent`, iOS 16 / watchOS 9. Could choose a default team. Low value; cheap once intents exist. |
| **Double tap** | Shipped. Nothing to do. |
| **MusicKit / CarPlay app** | No use case. Live Activities reach CarPlay without an app. |

## 6. Availability at our targets

| API | Minimum | Gate? |
|---|---|---|
| Start/Pause/Resume workout intents, AppShortcuts, Focus filter | iOS 16 / watchOS 9 | No |
| `addWorkoutEvents`, metadata used above | below targets | No |
| `HKWorkoutActivity` / `beginNewActivity` | watchOS 9; iOS 17 for session method | No |
| Mirroring | watchOS 10 / iOS 17 | No |
| Live Activity / `LiveActivityIntent` | iOS 16.1 / iOS 17 | No (phone only) |
| ActivityKit on watchOS | not available; watch shows the phone's activity | - |
| Smart Stack activity family | iOS 18 | Yes |
| Interactive/configurable widgets via App Intents | iOS 17 | No on iPhone; watchOS 11 and older have no widget-configuration UI, so ship preconfigured ones |
| Controls | iOS 18 / watchOS 26 | Yes |
| Effort score | iOS 18 / watchOS 11 | Yes |
| State of Mind | iOS 18 / watchOS 11 | Yes |
| Double tap shortcut | watchOS 11 | Yes (already) |
| `IndexedEntity` | iOS 18 | Yes |
| WeatherKit | iOS 16 / watchOS 9 | No, needs entitlement |
| WorkoutKit | iOS 17 / watchOS 10 | No |
| EventKit full access | iOS 17 | No |
| `HKLiveWorkoutBuilder` on iPhone | iOS 26 | Do not use |

## 7. Must be verified on hardware

1. How Fitness shows our brand name, segments and markers.
2. Whether a rated soccer match changes Training Load.
3. Action button cold start from a sleeping Ultra, and the donated next action.
4. Background Live Activity start through mirroring with the phone app killed and locked.
5. Whether HealthFit/RunGap read our route and HR for soccer.
6. Strava's treatment of a soccer TCX through the web uploader, with and without GPS.

## 8. Sources

Strava
- Apple Health and Strava: https://support.strava.com/en-us/articles/15402024-apple-health-and-strava
- API Agreement (1 Jun 2026): https://www.strava.com/legal/api
- API Policy (1 Jun 2026): https://www.strava.com/legal/api_policy
- Uploads: https://developers.strava.com/docs/uploads/
- Authentication: https://developers.strava.com/docs/authentication/
- Rate limits and capacity: https://developers.strava.com/docs/rate-limits/
- Changelog: https://developers.strava.com/docs/changelog/
- Brand guidelines: https://developers.strava.com/guidelines/
- Developer program update: https://communityhub.strava.com/insider-journal-9/an-update-to-our-developer-program-13428
- API FAQ: https://communityhub.strava.com/developers-knowledge-base-14/strava-api-faq-12906
- Getting activities into Strava: https://support.strava.com/en-us/articles/15402066-how-do-i-get-my-activities-to-strava
- Price (press): https://mezha.net/eng/bukvy/7adff94f_strava_restricts_public/

Apple
- StartWorkoutIntent: https://developer.apple.com/documentation/appintents/startworkoutintent
- Action button: https://developer.apple.com/documentation/appintents/actionbuttonarticle
- Workout activities: https://developer.apple.com/documentation/healthkit/dividing-a-healthkit-workout-into-activities
- Mirroring start: https://developer.apple.com/documentation/healthkit/hkworkoutsession/startmirroringtocompaniondevice(completion:)
- Mirroring handler: https://developer.apple.com/documentation/healthkit/hkhealthstore/workoutsessionmirroringstarthandler
- Multidevice sample: https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app
- Effort relation: https://developer.apple.com/documentation/healthkit/hkhealthstore/relateworkouteffortsample(_:with:activity:completion:)
- Effort DTS example: https://developer.apple.com/forums/thread/763539
- Effort estimates thread: https://developer.apple.com/forums/thread/764884
- Training load guide: https://support.apple.com/guide/watch/track-your-training-load-apde4c07a6cf/watchos
- Live Activities: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- ActivityFamily: https://developer.apple.com/documentation/widgetkit/activityfamily
- Controls: https://developer.apple.com/documentation/widgetkit/controlwidgetbutton
- Configurable widgets: https://developer.apple.com/documentation/widgetkit/making-a-configurable-widget
- EventKit access: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- WeatherKit: https://developer.apple.com/documentation/weatherkit/weatherservice
- WeatherKit hourly history: https://developer.apple.com/documentation/weatherkit/weatherquery/hourly(startdate:enddate:)
- WeatherKit pricing and attribution: https://developer.apple.com/weatherkit/get-started/
- Photos picker: https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios
- Core Spotlight: https://developer.apple.com/documentation/corespotlight/cssearchableindex
- Double tap: https://developer.apple.com/documentation/swiftui/view/handgestureshortcut(_:isenabled:)
- WorkoutKit: https://developer.apple.com/documentation/workoutkit/customworkout
- State of Mind: https://developer.apple.com/documentation/healthkit/hkstateofmind
- SharePlay: https://developer.apple.com/documentation/groupactivities/defining-your-apps-shareplay-activities
- SDK headers read locally: `HKMetadata.h`, `HKWorkout.h`, `HKWorkoutBuilder.h`, `HKWorkoutSession.h`,
  `HKHealthStore.h`, `HKUnit.h`, AppIntents and GroupActivities interfaces (Xcode 27.2)

Others
- Intervals.icu cookbook: https://forum.intervals.icu/t/intervals-icu-api-integration-cookbook/80090
- Intervals.icu OAuth: https://forum.intervals.icu/t/intervals-icu-oauth-support/2759
- Runalyze API: https://runalyze.com/doc-api and https://runalyze.com/help/article/personal-api
- Garmin Activity API: https://developer.garmin.com/gc-developer-program/activity-api/
- Garmin pause: https://the5krunner.com/2026/09/14/garmin-developer-api-access-paused/
- Garmin Personal API: https://developer.garmin.com/gc-developer-program/personal/personal-api
- TrainingPeaks API: https://help.trainingpeaks.com/hc/en-us/articles/234441128-TrainingPeaks-API
- TeamSnap calendar: https://teams-help.teamsnap.com/article/3009-subscribing-to-team-schedules
- Spond calendar: https://help.spond.com/app/en/articles/115529-calendar-synchronisation
- Veo download: https://support.veo.com/hc/en-us/articles/4451733961361
- HealthFit: https://apps.apple.com/gb/app/healthfit/id1202650514
