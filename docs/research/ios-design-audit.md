# MatchTracker for iPhone — design audit

Independent audit, 23 November 2026. iPhone 17 Pro and iPad Pro 11-inch simulators, iOS 26.5, US locale, built from this worktree (including its uncommitted changes). No tracked file was changed. Line numbers refer to commit 2d39c4b plus the changes uncommitted at the time; `0910501` landed while the audit ran.

**Method.** Every screen was driven by a throwaway UI-test copy of the repo in light, dark and Accessibility XL text. The copy stubbed the network layer (team stats, comments, formation, benchmark) and fed synthetic live updates through the real `LiveMatchStore.ingest`, so the team and live screens render with content. It also carried one behaviour patch, needed to get past issue 1 below; that issue was first reproduced without it. Screenshots: `/private/tmp/claude-501/-Users-ben-Development-MatchTracker--claude-worktrees-heuristic-meitner-343b2f/b7ef35b9-cace-4905-bd51-1d1861fdb9c9/scratchpad/audit-ios/` (about 170 PNGs, prefixed `light-`, `dark-`, `ax-`, `ipad-`) and, for issue 1, the sibling folder `audit-race/`.

Each claim is marked where it matters: **[seen]** = in a screenshot, **[code]** = read in source, not exercised.

---

## The verdict

**Overall: C+.** The engineering underneath is ambitious and the dark-mode Matches list is respectable. But this is an analysis console with a consumer skin. The app never answers a question; it offers six equal pills and lets you go find out. Three problems dominate:

1. **No hero.** The largest thing on match detail is "53 — Composite effort score". Nobody walks off a pitch asking for their composite effort score. The score of the game is absent from the hero; it is on the fifth pill. There is no season screen at all, although the data model clearly wants one.
2. **It does not survive contact with Apple's basics.** Kilometres in a US locale. Dynamic Type that inverts the hierarchy. Section labels at 1.6–2.5:1 contrast. A tab bar that changes shape. Zero VoiceOver on any chart or pitch.
3. **It contradicts itself.** One match shows 7.60 km and 7.34 km; 217 runs and 20 runs; three definitions of a sprint. A stats app gets one chance at trust.

The visual system is the other structural fault. `Theme` defines a house style — tinted tile, hairline stroke, 11-pt tracked caps, capsule — and applies it to everything. There are 95 hand-drawn `Capsule()` uses across 26 files, 34 `captionLabel()`s, and 68 fixed `.system(size:)` fonts, but only three `glassEffect` calls and no `.buttonStyle(.glass)`, no `GlassEffectContainer`, no native segmented control outside the coach dashboard. It reads as a well-made web dashboard from 2021.

---

## 1. Grades per screen

Against Fitness, Sports, Health, Weather and Slopes. A = could ship from Cupertino.

| Screen | Grade | Why |
|---|---|---|
| Onboarding | **D+** | The Health sheet lands on top of page 1 at first launch, unexplained **[seen]**. Pages don't scroll; AX text is cut off with no way to reach it **[seen]**. |
| Matches — empty | **D** | In light mode the background paints only a grey band behind the content; white above and below **[seen]**. Same screen appears when Health access was denied, with no hint. |
| Matches — list | **B−** | Best screen in dark. Field is usually missing, opponent doesn't exist, score is the smallest element, all rows weigh the same. Filter row asks "Has GPS?" |
| Search | **B−** | Native, minimised, fine. Plain text only: no tokens, suggestions or recents, and filter chips stay behind it. |
| Match detail — hero | **C** | Wrong hero, four pastel tiles, metadata at footnote size. |
| Detail — Heatmap | **C+** | Correct idea; blocky cells with visible seams, rendered in landscape on a portrait phone, two rows of chips above it. |
| Detail — Satellite | **C−** | Rotated 180° from the pitch view of the same match **[seen]**. Route toggle is a diagnostic shipped as a feature. |
| Detail — Compare | **F** | "Play more matches to compare" with seven matches recorded **[seen]**. |
| Detail — Runs | **C−** | The #1 "key run" is 14 m at 8.7 km/h. AI titles leak enum names **[seen]**. |
| Detail — Workrate | **C−** | Nine stacked modules, no headline, two that show the same data twice. Charts bleed off the glass. |
| Detail — Position | **C** | One dot on an empty pitch plus "Confidence 50%". Illegible chip in light mode. |
| Detail — Events | **C−** | A debug log: red trash can on every row, "Add note" 18 times, auto-detected noise outweighs goals. |
| Detail — Video | **B−** | Clear invitation, good copy. Buried as the sixth pill. |
| Comments | **C+** | Glued under every section, so each analysis page ends in a chat box. |
| Live match | **D** | Layout is decent (B). The sheet closes itself within about a second **[seen]**. |
| Live accessory | **B** | Right pattern. "LIVE" at 2.5:1; score doesn't say who is winning. |
| Fields map | **C+** | Pretty. Custom zoom buttons on a pinchable map, three competing CTAs, purple accent from nowhere. |
| Fields list / detail | **C** | Badge soup; field name printed three times on one sheet. |
| Add field / editor | **C** | Custom form under the map. Saves a "pitch" 2,000 km wide **[seen]**. Cancel button unreadable **[seen]**. |
| Team | **C** | Six stacked cards. Team is called "TEST01" in monospace. |
| Formation | **C+** | Fine idea, wrong orientation, unhelpful "Confidence 72%". |
| Match Chat | **C** | Second UI for the same comments; its tab bar button floats under the composer **[seen]**. |
| Coach dashboard | **D** | Unreachable on iPhone, though the iPhone paywall sells it **[code]**. Split view pushed inside a stack. |
| Paywall | **D+** | No price or CTA when StoreKit fails, no Terms or Privacy link, sells a list of nouns **[seen]**. |
| Settings | **C−** | "Server URL override" is the third row a customer sees. |
| Share / export | **F** | GPX and CSV only. There is no shareable picture of a match. |
| iPad | **C−** | A phone column centred on a desk (graded from empty states and code). See note at end of section 2. |
| Widgets | **D** | Watch only. No iPhone widget, Live Activity, Control or App Intent. |
| Motion / haptics | **B−** | Restrained and mostly Reduce-Motion-aware. Exceptions in issue 41. |

### The three moments

| Moment | Question | What the app shows today |
|---|---|---|
| Walking off the pitch | "What happened, how did I do, is it saved?" | The list; then "53". No "your match is ready", no notification, no Live Activity ending in a summary. Hero answer: **none**. |
| Couch, that evening | "Show me the good bit. Was I any good?" | Six pills. The answer is spread over Runs, Events, Video and Workrate. Nothing to send the group chat. Hero answer: **none**. |
| Between matches / season | "Am I getting better? Fit to play?" | Nothing. Month headers say "6 matches · 35 km". Trend text is buried mid-Workrate in caption2. Hero answer: **none**. |

---

## 2. Ranked issues

### P0 — broken or dishonest

**1. Cold launch can brand a good match "No GPS Data Recorded", workrate 0, score 0–0, for the whole session [seen].**
`MatchStore.swift:368-374`, `MatchDetailModel.swift:79-80`, `MatchesView.swift:657-667`. The cold-cache rows have neither workout nor record. `MatchRow.loadBadge()` builds and loads a detail model from that shell; `load()` sets `hasLoaded = true` before doing any work, finds nothing, returns. The empty model stays in `detailCache` after `refresh()` brings in the real workout. The list says 3–1 and 7.60 km; the detail says 0–0 and "No GPS". This is the walking-off-the-pitch case exactly.
*Fix:* rebuild the cached model in `detailModel(for:)` whenever the summary has gained a workout or record; set `hasLoaded` only on success; don't run the cold path for a summary with no workout and no record.

**2. The Live sheet dismisses itself [seen].** `LiveMatchAccessory.swift:37`, `MatchTrackerApp.swift:194-197, 251-263`. The sheet is owned by the accessory's content. Likely mechanism: the next watch update re-evaluates `RootTabView`, the accessory is rebuilt and `@State showingDashboard` resets. Reproduced on two builds with an update every 3 s. Frames `light-live-tap1` → `light-live-tap2`. There is also no Done button.
*Fix:* hoist `showingLive` to `RootTabView` and present from there; add a `.close` toolbar button; keep the accessory a dumb button.

**3. Failure is reported as absence.** `loadFailed` is written in four places and read in none (`MatchDetailModel.swift:40, 138`). A HealthKit error renders "This match has no GPS route" (`MatchDetailView.swift:469-472`).
*Fix:* separate `ContentUnavailableView("Couldn't Load Match", …)` with Try Again.

**4. Season comparisons only know the matches you opened this session [seen].** `MatchStore.swift:409-424` (Compare), `:487-501` (run baselines), `:511-518` ("4-week average", and the 7-day : 28-day ratio built on it, `WorkrateSection.swift:82-85`). The load ratio is a health-adjacent number computed from browsing history.
*Fix:* persist a small `MatchDigest` per match (score, distance, minutes, workrate, top speed, sprint count, grid, position) beside `MatchBadge`; compute every cohort from digests. This is also the prerequisite for any season screen. Until then, hide the ratio.

**5. Numbers disagree with themselves [seen].**
- 7.60 km list vs 7.34 km detail (`MatchesView.swift:546` swaps on badge arrival; month totals at `MatchListSupport.swift:163` use a third source).
- 217 runs (`RunsSection.swift:137`, includes jogs) vs 20 (`WorkrateSection.swift:316`).
- A sprint is >5.5 m/s (`Analytics.swift:50`), >7.0 m/s (`SoccerLoadMetrics.swift:66`), or >5.5 over the last 300 points (`LiveMatchView.swift:17, 158`). The last can *go down* as the ring buffer drops points (`LiveMatchStore.swift:42`).
- Speed Zones show 1:31 sprinting; Match Load shows 0.17 km of sprint.
- Top speed is one unsmoothed sample capped at 12 m/s (`SoccerLoadMetrics.swift:124-129`). The demo player hits 41.7 km/h, near Usain Bolt's peak.

*Fix:* one glossary enforced in the Kit: Distance (route), Run, Sprint, Top Speed (best sustained second or more). One source per number.

**6. Metric units for US users, everywhere [seen].** `GeometryBridge.swift:61-81` plus 15 hardcoded sites: `WorkrateSection.swift:186, 189, 198, 201, 204, 266, 279`; `LiveMatchView.swift:128`; `LiveMatchAccessory.swift:126`; `MatchesView.swift:280`; `MatchListSupport.swift:189`; `TeamRosterViews.swift:71, 83, 326`; `CoachDashboardView.swift:103, 312`; `FieldSheets.swift:108, 252`; `FieldsListSheet.swift:113, 173`; `RunNarrator.swift:158-159`. It also prints "0 m" for an indoor session.
*Fix:* `Measurement` + `.formatted(.measurement(width:, usage:))`: miles for match distance, **yards** for runs and pitch dimensions (US soccer speaks yards), mph for speed. Return value and unit as data so `MatchDetailView.splitMeasure` (line 392), which splits on an ASCII space and breaks in other locales, can be deleted. Add a Units row in Settings: Automatic / Imperial / Metric.

**7. AI titles leak raw enum names and change every launch [seen].** Same run, three launches: "Late-match burst toward goalMine", "…toward own goal" (subtitle: "Just before your goal"), "Late-match burst". `RunsSection.swift:302-306` feeds `rawValue`; results aren't persisted.
*Fix:* pass `kind.title`; reject any output containing camelCase or contradicting `reasons`; persist once per run — or drop it. The deterministic reason is better copy.

**8. Health permission ambush [seen].** `MatchTrackerApp.swift:138` → `MatchStore.swift:197` asks during bootstrap, behind the onboarding cover. "Enable Health Access" on page 3 then does nothing. After a denial the app says "No matches yet" forever.
*Fix:* no `requestAuthorization` in `refresh()` until `hasOnboarded`; make it onboarding's one job. On an empty result with a watch paired, show "Not seeing your matches?" with the path to Health settings (read denial cannot be detected, so always offer it).

**9. Add Event always logs the final minute [code].** `EventsSection.swift:102-105`: `Date()` clamped to the match ends at `matchEnd`. Forgot to log your goal on the watch? It is now in minute 92, or stoppage, with no way to move it.
*Fix:* a sheet with kind grid and minute wheel/scrubber; tap a row to edit time, kind, note.

**10. A pitch can be any size [seen].** `AddFieldView.swift:45-47`, `FieldBoundsEditor.swift:205`. `light-add-field-adjust.png` enables Save on a rectangle from Colorado to Guatemala. `SportProfile.typicalLengthRange` exists and is ignored.
*Fix:* show live dimensions while dragging; disable Save outside plausible bounds with the reason inline.

**11. Satellite heatmap is rotated 180° against the pitch heatmap [seen].** `HeatmapSection.swift:585` uses bearing + 90, so the u-axis runs right-to-left. The hot cell is left of centre on the pitch and right of centre on satellite; the compass reads S.
*Fix:* derive the heading from `corners[0]→corners[1]` so u is left-to-right. Better: normalise every pitch to "attacking up" (proposal B).

### P1 — accessibility and platform

**12. Dynamic Type inverts the hierarchy [seen].** `Theme.swift:193, 199, 205`; `MatchDetailView.swift:496, 504, 512`; 60-odd more fixed sizes; no `ScaledMetric`, `ViewThatFits` or `dynamicTypeSize` anywhere. At AX XL the date is larger than the distance, tile labels spill through the border, Workrate scores wrap into "7/4", "Defensive" hyphenates to "De-fen-sive", times read "10:00A/M", roster names become "Marc…", and Add Field covers the field list.
*Fix:* text styles (`.largeTitle.bold()` for heroes, `.title2` for stats, `.subheadline` for labels); `ViewThatFits` from row to stack; at accessibility sizes tiles become a `LabeledContent` list.

**13. Tinted caps labels fail contrast badly [seen, measured].** `captionLabel()` hard-codes `.foregroundStyle(.secondary)` (`Theme.swift:208`), so a later `.foregroundStyle(tint)` yields *secondary of the tint*. Light: COMMENTS 2.06:1, FIELD NAME 1.60:1, RUN 1.93:1, LIVE 2.53:1. Untinted captions 3.3:1, "Add note" 1.7:1. Dark is nearer passing (6.1:1 untinted).
*Fix:* delete `captionLabel()`. Sentence-case `.subheadline`, `.secondary`, no tracking; colour the value or the glyph, never the label.

**14. VoiceOver can't see the product [code].** No label or representation on `PitchHeatmapCanvas`, `SatelliteHeatmapOverlay`, `RunsPitchView`, `PositionPitch`, `FormationPitch`, `LiveMatchView.pitchCard`; no chart descriptors beyond Swift Charts defaults; `KeyRunCard` and `RunRow` use `onTapGesture` so aren't buttons (`RunsSection.swift:158, 206`); the corner handles say "drag to adjust" with no adjustable action (`FieldBoundsEditor.swift:290`); hold-to-flip is drag-only.
*Fix:* one generated sentence per pitch ("Mostly central midfield; 89 percent of time in the middle third"); buttons for cards; `accessibilityAdjustableAction` for corners; `accessibilityAction(named: "Show season average")`.

**15. Settings is wearing the Search tab's clothes [seen].** `MatchTrackerApp.swift:214-223`. `role: .search` for a gear, while real search sits top-right, and the tab exists only on the Matches root. The bar changes width and slides when you change tab or push, and VoiceOver's tab count changes.
*Fix:* a profile/settings button top-trailing, opening a sheet (Fitness, Health, App Store). Give `role: .search` to search. Never add or remove tabs at runtime. Delete `isAtRoot`, `isScrolledDown` and `ScrollDownTracker`.

**16. Card shadow leaks onto the text [seen].** `Theme.swift:307-316`: `.shadow` on an uncomposited stack shadows every child. In light mode every headline, text field and progress bar has a grey smudge (`light-empty-team.png`).
*Fix:* put the shadow on the background shape, or drop it. Light-mode cards in iOS 26 need none.

**17. Nav bar collides with content [seen].** `MatchDetailView.swift:84-97`: hidden bar background plus soft edge over a fixed 340-pt wash. "Nov 22" sits on "Speed Zones", on tile values, on the position chip; the glass flips light/dark as the dark pitch passes under a light page.
*Fix:* delete `.toolbarBackground(.hidden)` and the wash; let the system scroll edge work. If the hero is imagery, use `backgroundExtensionEffect()`.

**18. Light mode is an afterthought.** The wash stays pinned as mint fog while scrolling; `surfaceStroke` is white 8% (`Theme.swift:68`) so ring track, bar tracks and card edges vanish on white (see the empty Workrate ring and thirds bars); position chip text is dark on grey glass over dark turf.
*Fix:* `Color(.separator)` and `.quaternary` fills, or commit to dark-only as Fitness does. I'd commit.

**19. Hit targets under 44 pt.** Filter chips 32 (`MatchListSupport.swift:287`); display, window, mode chips 34 (`HeatmapSection.swift:222, 297, 325`); Position chips 34/40 (`PositionSection.swift:101, 182, 196, 227`); event trash about 13 pt (`EventsSection.swift:159`); field info 34 (`FieldsListSheet.swift:197`); hint dismiss 26 (`FieldsMapChrome.swift:239`); star, minus, "Initials" (`TeamJoinCard.swift:185-212`); refresh, camera close 40. Fixed heights also clip at large text.

**20. Coach dashboard can't be opened on iPhone [code].** `MatchesView.swift:71` gates the only entry on regular width; `PaywallView.swift:92` and `TeamJoinCard.swift:278` sell it on iPhone. It also pushes a `NavigationSplitView` in a `NavigationStack`, and its toolbar icon has no label (line 77).
*Fix:* a Team-tab row; on iPhone a plain stack.

**21. Destructive actions without a net.** Delete event: one tap, no confirm, no undo (`EventsSection.swift:107, 159`). Leave team: one tap (`TeamJoinCard.swift:208`). Remove video: one tap (`VideoHighlightsSection.swift`, `store.remove`). Meanwhile Delete Match is discoverable only by long press (`MatchesView.swift:131`).
*Fix:* swipe actions plus undo; confirm for team and video. Move Matches to `List`, or use iOS 27's swipe-actions-anywhere.

**22. Paywall is incomplete [seen].** `PaywallView.swift:122` is a dead end with no retry; no Terms of Use or Privacy links (App Review 3.1.2); says "per month" unconditionally (line 153); history import, a *solo* feature, sits behind *Team* (line 94), and "Backlog batch import" is developer speech.
*Fix:* `SubscriptionStoreView`, which supplies price, terms, restore and failure. Free the import: it is the onboarding wow.

**23. Empty Matches background band [seen].** `MatchesView.swift:44-58`: background hugs the non-filling VStack.
*Fix:* `ContentUnavailableView` in a filling frame. And "No matches match your filters" + Clear filters appears when nothing is filtered but a match is live (`:45, 121`) **[seen]**.

**24. Onboarding doesn't scroll [seen].** `OnboardingView.swift:33-41, 159, 208, 263`. At AX XL body copy truncates, card 1 is cut under Skip, "Enable Health Ac…". Titles are fixed 34/30 pt so body outgrows them.
*Fix:* `ScrollView` + `safeAreaInset(.bottom)`; drop team code from onboarding.

### P2 — hierarchy and content

**25. Six equal pills are the information architecture.** `MatchDetailView.swift:21-29, 181-222`. Two are hidden off the right edge, switching discards scroll position, each has a different selected colour (Heatmap and Runs share one), and a *second* chip row and sometimes a third and fourth sit below (`HeatmapSection.swift:53-64, 243`). Compare shows four rows of capsules above the content.
*Fix:* one scroll with a hero and ranked modules; display options in a single menu on the pitch.

**26. Workrate is the wrong hero.** `MatchDetailView.swift:263-284`. Unlabelled scale, no verdict, a ring implying a goal you could close. An indoor session scores 85 on heart rate alone and a 92-minute match scores 53; they're shown as the same thing **[seen]**. The explainer omits heart rate (`WorkrateSection.swift:319`) though it's 25% of the score. Subtitle "Composite effort score" is the definition of jargon.
*Fix:* demote to one row with words: "Effort · Strong · above your usual".

**27. The result is missing from the hero.** Score lives on pill five, "Us vs Them". There is no opponent field.
*Fix:* Sports-style scoreline first; add optional opponent.

**28. List row ranks the date first.** `MatchesView.swift:508-553`. Date is headline, score is a pill, field blank or caption. "Distance"/"Duration" captions repeat on every row forever. The GPS glyph tells a player nothing.
*Fix:* lead with result and place, then one secondary line ("4.6 mi · 92 min"), then a trailing heatmap thumbnail. Week and month as native section headers.

**29. "Has GPS" is a developer's filter,** and it is single-select with years and formats mixed (`MatchListSupport.swift:207-212, 256-266`).
*Fix:* one toolbar filter menu (Type, Season, Field) with a filled glyph when active.

**30. Runs picks bad runs [seen].** Card 1 is a 14 m jog tagged only for preceding a goal. Cards say "RUN" when there's no category (`RunsSection.swift:546`).
*Fix:* floor of sprint-class peak or 30 yd; cap at 3; lead with Fastest, Longest, Decisive. If none qualify, show none.

**31. Workrate stacks nine modules,** two of them the same series (15-minute blocks and per-minute, `WorkrateSection.swift:22-34`). Accel/decel counts with unit "count" (lines 192, 195) are noise at wrist GPS precision. "Industry-standard bands: HSR 19.8–25.2 km/h" is a lab note.
*Fix:* keep Intensity over time (HR + speed, half-time shaded), Speed, Effort. Move the rest to "All Metrics".

**32. Charts run off the screen [seen].** `.fullBleed()` on axes (`WorkrateSection.swift:281, 340, 426`) puts "m/min", "150", "bpm" against the glass and clips the last time label to "1". HR starts at zero, flattening everything (`:409-427`).
*Fix:* standard insets; `.chartYScale(domain: .automatic(includesZero: false))`; match minute on x; half-time band; selection scrubbing.

**33. Indoor shows empty GPS modules [seen].** Blank "Distance per Minute" with gridless void, a "Speed Zones" heading over nothing, "0 Runs / 0 Sprints" though the hero shows "—", and "TIME ON…" truncated. `WorkrateSection.swift:27-34` gates only HR.

**34. Events is a log.** Match Start, Period End and paired Sub Out / Sub In "Auto" rows around half-time outnumber the goals. Every row shows "Add note", a minute, a clock time and a red bin. Notes persist on each keystroke (`EventsSection.swift:91-100`).
*Fix:* key moments only, halves as dividers, auto subs collapsed into "Bench 40′–51′"; editing behind Edit.

**35. Position offers one dot and a shrug.** "Confidence 50%" (`PositionSection.swift:130`). At 50% the list badge also asserts CM (`MatchesView.swift:568`).
*Fix:* fold into the heatmap: "Mostly central midfield" with thirds; below 60% ask "Where did you play?" using a tappable pitch, not ten checkbox capsules.

**36. Comments are the footer of every analysis page** (`MatchDetailView.swift:67`) and also a separate paid "Match Chat" with a second UI. *Fix:* one comment thread, one toolbar button with count.

**37. No share artefact.** `ExportMenu.swift`: GPX/CSV three levels deep, writing files during menu body evaluation on the main thread (`:18, 24, 29, 55`). *Fix:* top-bar Share with a rendered card (score, heatmap, three numbers); file exports under "Export Data".

**38. Overflow menu is an ops panel.** "Re-upload to team" first. A circled ellipsis in a glass circle is a double circle (`MatchDetailView.swift:125`); use `ellipsis`.

**39. Field vocabulary is a data pipeline.** Trained, Inferred, GPS, Walked, Observations, Confirmed, "Low-confidence geometry… locks it in as trained" (`FieldSheets.swift:110, 137, 165`), two naming schemes for the same enum (`GeometryBridge.swift:51` vs `FieldSheets.swift:373`). Colours are raw `.blue/.orange/.purple/.teal` outside the theme. *Fix:* a field has a name, a size, matches played here, and at most one state: "Check outline".

**40. Map chrome.** Custom ＋/− on a pinchable map, hand-rolled locate (no `MapUserLocationButton`), tint glyphs on glass, list pill + Scan + Add Field, status bar unreadable over imagery **[seen]**. Scan proposed a pitch over a university building **[seen]** with "1 possible pitch… add them". *Fix:* persistent sheet (Maps/Find My), system controls, one ＋ menu: Draw Corners / Detect in This View.

**41. Motion gaps.** `LivePulseDot` (`LiveMatchAccessory.swift:152`), `Shimmer` (`TeamRosterViews.swift:387`), refresh spin and Coach `TimelineView(.animation)` ignore Reduce Motion. The heatmap hint pulses forever until used. `UIFeedbackGenerator` statics instead of `.sensoryFeedback`.

**42. Team tab is a settings page in costume.** Team named by code, refresh button duplicating pull-to-refresh (`TeamJoinCard.swift:107`), "My Teams" form and upsell inline, bronze drawn as dim amber. *Fix:* team name as title, leaderboard as `List`, management in a toolbar sheet.

**43. Settings.** Server override and "Upload all" (`SettingsView.swift:47-77`) ship in Release; "Re-authorize HealthKit" replies "HealthKit authorization requested."; About lists "App: MatchTracker" and "Records"; guardian consent sits beside data deletion; team code commits on every keystroke, pushing half-typed codes to the watch (`:165, 248-254`).

**44. Field detail and consent rebuild Form by hand.** `ThemedFieldTextField`, `FieldActionRow`, `nameCard`, `acceptBar`, JoinTeam fields. Name appears as hero, text field and nav context. *Fix:* `Form` with `LabeledContent`, `.buttonStyle(.glassProminent)`.

**45. Field tint on Cancel.** `AddFieldView.swift:64` `.tint(Theme.bench)` renders grey on amber glass, unreadable **[seen]**.

**46. Location permission on tab appearance** (`FieldsView.swift:78`) before the user asks for anything, with the wrong reason: "to record your route on the pitch", on a device that doesn't record routes **[seen]**. The purpose string should say what the Fields map does.

**47. Heat cells have visible seams [seen].** `HeatmapSection.swift:486` overdraws 0.5 pt translucent cells, producing a grid. Ramp starts at turf green on green turf, so the low end reads as pitch. *Fix:* render to a small image, upscale with interpolation; start the ramp transparent and end bright; single hue family.

**48. Pitches are landscape on a portrait device,** so the hero visual is about 250 pt tall and half the useful size.

**49. Every accent means two things.** Green is brand, goal, effort, jogging, balanced, "selected"; amber is sprint, heatmap, flag, warning, gold *and* bronze; rose is heart, goal against, live, high-speed. *Fix:* three roles: you (green), opponent/negative, heart. Everything else monochrome.

**50. Rounded type everywhere.** SF Rounded for titles, buttons, chips, body. Apple uses it for numerals in Fitness. Keep it for numbers.

**iPad note.** Adds `readableWidth` and centres phone UI. Nothing uses the space: no sidebar-adaptable tabs, no list/detail split for matches, no keyboard shortcuts **[code]**. The gear lands inside the top tab pill as an unlabelled fourth tab, and disappears on Fields; the empty-state band (issue 23) spans the full width; the empty screen is a small illustration in a void **[seen]**. Populated iPad detail was not captured: Health authorisation on the fresh simulator did not complete.

---

## 3. Three structural proposals

All native: `TabView` with `Tab`/`role: .search`, `NavigationStack`/`NavigationSplitView`, `List`/`Form`, Swift Charts, `tabViewBottomAccessory`, Live Activities, `SubscriptionStoreView`, zoom navigation transitions. Iconography is SF Symbols; no custom capsules.

### Proposal A — "Season first": Summary · Matches · Team · Search

Replace a data-type IA (matches / fields / team) with a time-and-question IA.

```
┌────────────────────────────────────┐
│ Summary                        (BL)│  ← profile opens Settings sheet,
│                                    │    incl. Fields, Units, Data
│ ┌────────────────────────────────┐ │
│ │ [ heatmap fills the card, dark]│ │  LAST MATCH. The full-bleed card,
│ │                                │ │  zoom-transitions into detail
│ │  Won 3–1                       │ │
│ │  Sunday · Demo Park            │ │
│ │  4.6 mi   17 sprints   18 mph  │ │
│ └────────────────────────────────┘ │
│                                    │
│ This Season             Fall 2026 ▾│
│  W 4  D 1  L 1      ▂▅▃▇▆█         │  tappable bars = matches
│  You're covering more ground than  │  one generated sentence, from
│  in September.                     │  deterministic rules
│                                    │
│ Ready to Play                   >  │  plain words, not 0.97 ACWR
│  Your load is steady this week     │
│                                    │
│ Personal Bests                  >  │
│  Top speed 18.2 mph · Nov 22  NEW  │
├────────────────────────────────────┤
│ Summary   Matches   Team       (🔍)│  stable bar; real search role
└────────────────────────────────────┘
```

- **Answers:** season directly, post-match through the top card; between matches through Ready to Play.
- **Fields** leaves the tab bar: it is configuration. It lives in Settings and wherever a match needs it ("Field not right? Adjust"). Map of *places you've played* is a Season module.
- **Needs:** persisted `MatchDigest` (issue 4).
- **Risks:** Summary is thin with one match, so ship a deliberate one-, two- and three-match state; load language must not read as medical advice; demoting Fields weakens the community-mapping pitch, so prompt for it in context ("Help confirm this pitch").

### Proposal B — "The match is a story": one scroll, pitch as hero

Delete the pills. Match detail becomes a scoreline over an attacking-up portrait pitch, then at most four modules in order of interest.

```
┌────────────────────────────────────┐
│ (‹)                        (↑) (…) │  Share is first-class
│              Won                   │
│            3  –  1                 │  ← hero. largeTitle scale, SF Rounded
│     Sun, Nov 22 · Demo Park        │
│   ┌──────────────────────────┐     │
│   │            ▲             │     │  portrait pitch, always attacking up
│   │      ░░▒▒▓▓▒▒░           │     │  smooth heat; goals and your runs
│   │     ░▒▓███▓▒░    ⚽︎84′   │     │  as tappable marks
│   │       ░▒▓▒░              │     │
│   └──────────────────────────┘     │
│   ◀──────●───────────|────────▶    │  scrub the match; half-time tick
│   [ Heat │ Runs │ Average ]        │  one native segmented Picker
│                                    │
│   4.6 mi     92 min     17 sprints │  three numbers, no tiles
│   Covered 0.4 mi more than usual   │  one sentence
│                                    │
│ Moments                            │
│   11′ Goal      26′ Assist         │  with ▶ when video exists
│   84′ Your goal  ▶                 │
│ Best Runs                          │
│   18.2 mph · 52 yd · 64′        >  │
│ Effort                          >  │  HR + speed chart, "Strong"
│ All Metrics                     >  │  the lab lives here
└────────────────────────────────────┘
```

- **Answers:** off the pitch, the first screenful with no interaction; couch, scrub + Moments + Share.
- Satellite, Adjust Field and Compare move to one menu on the pitch. Position folds into the sentence and pitch. Comments become a toolbar button.
- **Landscape:** rotate for full-screen pitch replay.
- **Risks:** attack direction is inferred and can be wrong, so provide "Flip sides" and never label ends when confidence is low; scrubbing needs an hour of data decimated and pre-rendered; no-score, no-GPS and indoor matches each need a designed hero (duration + HR curve); some users will miss direct tabs.

### Proposal C — "The match lifecycle": one object from kickoff to season

The phone follows the state of the match instead of asking the player to navigate to it.

```
 BEFORE                LIVE                 JUST ENDED             SETTLED
┌───────────────┐ ┌───────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ Next match    │ │ ● 2–1   40:25 │ │ Full time        │ │ Won 3–1          │
│ Sat 10:00     │ │ On pitch      │ │ 3–1   4.6 mi     │ │ pitch + moments  │
│ Demo Park     │ │ ▁▃▅▂ HR 164   │ │ Best: 18.2 mph   │ │                  │
│ Watch ready ✓ │ │ [Log event ▾] │ │ [Who did you     │ │ → Season         │
│               │ │               │ │  play? Right?]   │ │                  │
└───────────────┘ └───────────────┘ └──────────────────┘ └──────────────────┘
 Widget / Control  Live Activity +    Live Activity ends   Summary card
                   accessory bar      as a summary; taps
                                      into a 15-second
                                      confirm sheet
```

- **Answers:** off-the-pitch perfectly. The confirm sheet (opponent, score, position, missed goal) captures facts at the only moment people will supply them, and fixes issues 9, 27 and 35 at source.
- **Uses:** ActivityKit, WidgetKit (last match, season), App Intents and Controls (start on watch, log goal), notification "Your match is ready".
- **Risks:** most engineering; watch-to-phone delivery must be dependable (issues 1–3 first); Live Activities update budget; the schedule half needs a calendar source, so ship it last.

### Recommendation

**B first, on a foundation of issue 4, then A, then C.** B is the product's reason to exist, it can be built inside `MatchDetailView` without disturbing tabs, and its hero becomes A's card, the share image, the widget and the Live Activity end state. If only one thing is done: **scoreline + portrait heat pitch + three numbers + one sentence**, with everything else a scroll below.

Suggested order: trust (1–5, 7, 11) → units and type (6, 12, 13, 16) → B → Share card → A with stable tabs (15) → Live sheet to Live Activity → C.

---

## 4. Delete

**Outright**
- Section pills and every other chip row: `sectionPicker`, `displayChips`, `windowPicker`, `modeControl`, `controlChips`, `MatchFilterBar`, `MetricPicker`, cohort chips. Replace with one segmented Picker and menus.
- `captionLabel()`, `metricTile`, `HeroStatTile`, `StatTile`, `SummaryChip`, `LoadTile`, `FieldStatTile`; `glow`; `heroWash`, `headerGradient`, `sectionTint`; `GlassCard`.
- `ScrollDownTracker`, `isAtRoot` / `isScrolledDown` plumbing, conditional Settings tab.
- Route diagnostic overlay; "Has GPS" filter and glyph; hold-to-flip and its hint.
- Accels, Decels, Dist/Min, "Industry-standard bands", ACWR number, VO₂max line, "Effort from GPS + heart rate", "Composite effort score".
- Per-minute chart (keep one time series); speed-zone donut (a single stacked bar does it).
- Confidence percentages in the UI (Position, Formation), Observations, source badges.
- AI run titles until they are deterministic and correct; with them, the "Labels by Apple Intelligence" footnote.
- "Re-upload to team"; Settings › Backend, About › App and Records (move to DEBUG).
- Custom zoom buttons, custom locate, Refresh button, `ThemedFieldTextField`, `FieldActionRow`, hand-built CTAs.
- Match Chat as a separate screen. Walk streak and badges.
- Glowing paywall mark; tinted feature cards.
- The pre-iOS-26 branches (`legacyTabView`, `liveCard`, material fallbacks). Two designs is one too many for a small team; consider an iOS 26 minimum.

**Demote:** Fields tab → Settings and contextual; raw metrics → All Metrics; GPX/CSV → Export Data; formation → inside Team; guardian consent → team join flow for minors.

**Keep:** dark palette, turf pitch drawing, live accessory pattern, Reduce Motion discipline on detail, month grouping, matches search, sideline-video copy, skeleton loading, the corner editor's handle mechanics, the honest comparison captions.

---

## Limits of this audit

Simulator only: no real haptics, glass performance, camera or watch pairing. Team, chat, formation and benchmark screens used stubbed data; stub content is not criticised, layout is. Demo matches place the pitch over a campus, so imagery alignment wasn't judged. Coach dashboard, Backlog Import, Accept Proposal and video alignment were read in code, not captured. Paywall was seen only in its product-unavailable state. Landscape was not captured.
