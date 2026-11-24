# MatchTracker competitive teardown

Researched 23 November 2026. Internal and candid. Supersedes the parts of `docs/COMPETITIVE_BENCHMARK.md` flagged in section 2.

**How this was gathered**

- Price, rating, rating count, version and update date come from Apple's public lookup API, US storefront unless noted: `https://itunes.apple.com/lookup?id=<id>`. In-app prices come from the US App Store page. Both can change daily.
- Reviews come from Apple's public feed: `https://itunes.apple.com/<cc>/rss/customerreviews/page=1/id=<id>/sortBy=mostRecent/json`. Reviews are paraphrased and dated. Feeds return at most 50 recent reviews, and for the small apps that is the entire sample.
- MatchTracker facts come from grep and reading source on branch `claude/apple-watch-sports-app-1224d7`. Nothing was run on a device.
- **[U]** means I could not verify the claim. **[J]** means it is my judgement rather than a sourced fact.

---

## 1. Bottom line

1. **The category is crowded with weak apps and has no winner.** About 15 Apple Watch soccer trackers are live and most launched in 2025 or 2026. The oldest, SoccerTrackr, has 113 US ratings after eight years. Nobody owns it, but nobody has proved it is a large market either.
2. **Reliability decides the stars.** Across SoccerTrackr, Outplay, Soccer Plus, Soccer Training Tracker Pro, REFSIX, Playermaker and Trace, the dominant one-star themes are lost matches, missing heatmaps, failed sync and stuck end screens. Missing features come a distant second.
3. **A rule change opened the market five months ago.** Law 4 for 2026/27 permits non-dangerous accessories that are safely and securely covered. US high-school rules allow wearables under the uniform and not on the arm. A bare wrist watch is the wrong form factor for organised matches, and MatchTracker has no vest or pocket mode.
4. **Field detection is no longer unique.** REFSIX's 30 October 2026 release advertises automatic field finding with no corner calibration. Heatiz recognises saved pitches. Our lead is now quality and pipeline, not existence.
5. **MatchTracker's analysis depth is ahead of every direct rival I found, and its system integration is behind most of them.** It has no App Intents, Live Activity, iPhone widget, share card, season or trends screen, personal bests, localisation or imperial units.

---

## 2. Where we actually stand (from source)

| Area | State | Evidence |
|---|---|---|
| Watch recording, indoor, formats, countdown, crash recovery | Yes | `WorkoutManager.swift`, `RouteRecorder.swift` |
| Field detection (walk, inference, imagery, community) | Yes | `FieldFitter`, `SatelliteFieldDetector`, `NearbyFieldSeeder` |
| Auto-subs, automatic halves | Yes | `AutoSubDetector`, `PeriodDetector` |
| Events on watch, Double Tap, Water Lock, Always On | Yes | `EventsView`, `ControlsView`, `MetricsView` |
| Event add, delete and note on iPhone | Yes | `EventsSection.swift` |
| Trim start/end, edit halves after the match | **Not found** | grep of `iOS App` |
| HSR, sprint, accel/decel, 7:28 load, GPX/CSV export | Yes | `SoccerLoadMetrics`, `WorkrateSection`, `ExportMenu` |
| On-device AI run titles | Yes | `RunNarrator.swift` (FoundationModels) |
| Sideline camera and event auto-clips | Yes | `SidelineCameraView`, `VideoHighlightsSection` |
| Coach dashboard, chat, formations, cohort percentiles | Client done; server pieces open per `ROADMAP.md` | |
| Watch complications | Four families: circular, corner, rectangular, inline | `Watch Widgets/` |
| App Intents, Siri, Action button, Control Center | **None** | no `AppIntent` in repo |
| Live Activity, Dynamic Island | **None** | no `ActivityKit` in repo |
| iPhone or iPad widgets | **None** | no iOS widget target |
| Share image or story card | **None**; GPX/CSV files only | `ExportMenu.swift` |
| Season recap, trends screen, personal bests | **None found**; season data feeds heatmap compare only | |
| Units | **Metric hard-coded** (`km/h`) | `GeometryBridge.swift:79`, `WorkrateSection.swift:201` |
| Localisation | **English only** | no `.xcstrings` or `.lproj` |
| Charts accessibility, Dynamic Type handling | No `accessibilityChartDescriptor`, no `dynamicTypeSize`; about 88 fixed-size or scale-factor text uses | grep |
| Workout effort score, HealthKit workout zones | **None** | no `EffortScore`; zones are new in watchOS 27 |
| Forgot-to-stop detection | **Not found** | grep of `Watch App` |
| Referee mode | Cards, fouls, score; no stoppage time, sin bin, extra time, shootout or report | grep |
| Schedule or calendar, notifications | **None** | no EventKit or UNUserNotification |
| Personal sync without a team | Custom backend; CloudKit only touched in `UploadService` | `ROADMAP.md` |
| Price | $3.99/month team plan; solo free; **history import is paywalled** | `MatchTracker.storekit`, `BacklogImportView.swift:161` |

**Corrections to `COMPETITIVE_BENCHMARK.md`:** it says no consumer product auto-detects a pitch (now false, see REFSIX), it omits every direct Apple Watch rival, and it has no player-rule analysis.

---

## 3. Direct rivals

Ratings are US unless stated.

### 3.1 Snapshot

| App | Price | Rating (count) | Last update | First release |
|---|---|---|---|---|
| [SoccerTrackr](https://apps.apple.com/us/app/id1348552393) (MyndArc, also makes Athlytic) | Free; $2.99/mo, $19.99/yr | 4.41 (113); GB 4.24 (37) | 27 Oct 2026 | Aug 2018 |
| [Outplay](https://apps.apple.com/us/app/id6444451247) | Free; $2.99/mo, $24.99/yr | 4.17 (24); GB 4.42 (57) | 22 Oct 2026 | Mar 2023 |
| [Pitch Pulse](https://apps.apple.com/us/app/id6762101356) | First session free; $4.99/mo, $29.99/yr | 5.0 (14) | 9 Nov 2026 | May 2026 |
| [Heatiz](https://apps.apple.com/us/app/id6761580343) | Free, no IAP listed | 5.0 (2) | 15 Nov 2026 | Sep 2026 |
| [Ballers Club](https://apps.apple.com/us/app/id6745950225) | Free; $6.99/mo, $39.99/yr | 5.0 (2); GB 4.5 (12) | 13 Nov 2026 | Oct 2025 |
| [Memo Soccer](https://apps.apple.com/us/app/id6740020160) | Free; $0.99/mo, $4.99/half-year | 5.0 (4) | 23 Nov 2026 | Feb 2025 |
| [Soccer Plus](https://apps.apple.com/us/app/id1577752006) | $3.99 once | 4.25 (8) | 3 Nov 2026 | Sep 2021 |
| [Soccer Training Tracker Pro](https://apps.apple.com/us/app/id1665755661) | Free; $4.99 sub | 4.44 (43) | 17 Jul 2026 | Feb 2023 |
| [Soccer Fitness Tracker](https://apps.apple.com/us/app/id6756504677) | Free, tips only | 4.91 (11) | 19 Oct 2026 | Dec 2025 |
| [FullPitch](https://apps.apple.com/us/app/id6791011566) | Free; $4.99/mo, $24.99/yr | none | 14 Oct 2026 | Sep 2026 |
| [MatchDay](https://apps.apple.com/us/app/id6762024858) | Free; $4.99 once | 5.0 (4) | 11 May 2026 | Apr 2026 |
| [PlayHeat](https://apps.apple.com/us/app/id6814869600) (Health routes only) | $1.99/wk, $19.99/yr, $39.99 life | 4.75 (4) | 18 Nov 2026 | Oct 2026 |
| [iFootball Plus](https://apps.apple.com/us/app/id6759049511) | $1.99/mo, $17.99/yr, $29.99 life | none | 8 Nov 2026 | Apr 2026 |
| [Scorza](https://apps.apple.com/gb/app/id6748314338) (REFSIX Ltd; GB) | App £34.99/yr IAP; [vest + app £49.99/yr](https://scorza.com) | 5.0 (2) GB | 8 Nov 2026 | Dec 2025 |
| [Footbar](https://apps.apple.com/gb/app/id1519230644) (leg sensor; GB) | £3.99/mo, £34.99/yr plus sensor | DE 4.59 (511) | 19 Nov 2026 | Jul 2020 |

"Footy Tracker" / "FootyTracker": no soccer app by that name surfaced in US search. [Hoof](https://apps.apple.com/us/app/id1642305811) (last update Aug 2024) and [ActionLog](https://apps.apple.com/us/app/id6449056590) (Jul 2024) look abandoned **[J]**.

Search ranking: for "soccer apple watch" SoccerTrackr ranks first, ahead of score apps; for "soccer tracker" score apps (FotMob, OneFootball) take the top slots and SoccerTrackr is third. This is API search order, not a logged-in App Store session.

### 3.2 SoccerTrackr: the incumbent, revived

- **Praise:** far cheaper than a vest (Sep 2024), heatmap useful for players who change position (Nov 2025).
- **Complaints:** almost every metric locked (Aug 2026, 1 star); workouts never reach phone (Aug 2025); impossible top speeds, including one report of 74 mph (Aug 2024) and several from 2018 to 2021; heatmap pinned to the sideline because the phone in the bag supplied GPS (Apr 2024); battery death lost the match (Sep 2021); no sub or half editing, halves mixed in one heatmap (Jan 2026). [US feed](https://itunes.apple.com/us/rss/customerreviews/page=1/id=1348552393/sortBy=mostRecent/json), [GB feed](https://itunes.apple.com/gb/rss/customerreviews/page=1/id=1348552393/sortBy=mostRecent/json).
- **Beats us:** v27 (27 Oct 2026) shipped Siri and Shortcuts start with parameters, Action button, Smart Stack suggestion, "Get Last Session" for Siri, share images, Goalie and Practice modes, and watch-side save confirmation. It also has effort and efficiency history. This is the closest thing to a checklist of what we lack.
- **We beat it:** field geometry, auto-subs, halves, run detection, event-aligned video, team, GPX export, free depth.
- **Threat level: high.** MyndArc has Athlytic (4.79, 11,309 ratings) and just started investing again.

### 3.3 Outplay: the best small-team execution

- **Praise:** best on the store (GB Nov 2023), per-match comparison across a season (GB Jun 2024), iPhone-in-pocket recording (Mar 2025), Strava and Health link (Jan 2026).
- **Complaints:** GPS failed on match two after paying (Apr 2025); 4.25 km recorded over 90 minutes (GB Jul 2026); matches fail to transfer (GB Mar and Apr 2025); wants score keeping (GB May 2025); must be able to edit halves, bench time and a forgotten stop (Jan 2026); asks how the numbers are derived (GB Jul 2025). [US feed](https://itunes.apple.com/us/rss/customerreviews/page=1/id=6444451247/sortBy=mostRecent/json), [GB feed](https://itunes.apple.com/gb/rss/customerreviews/page=1/id=6444451247/sortBy=mostRecent/json).
- **Beats us:** phone-only recording, per-90 comparison, user-set sprint threshold, iCloud sync, new-match notification and badge, permission status screen, declared accessibility features, iPhone Duo update.
- **We beat it:** score and events, auto halves and subs (two of its users' explicit requests), field detection, live view, video, HR-only indoor.

### 3.4 Pitch Pulse: the fastest mover

- Six months old, 14 US ratings, localised in 11 languages. Feeds contain only three early, positive US reviews, so treat the 5.0 as noise.
- **Beats us:** AI match read in prose, monthly recap as a story, automatic same-match teammate detection with head-to-head, share cards, career stats and venues.
- **We beat it:** auto field geometry (it asks users to map boundaries), events, subs, halves, live, team, and no paywall on match two.

### 3.5 Heatiz: the best-specified newcomer

- **Beats us:** on-watch heatmap preview, goals/assists/self-rating/position entry at the whistle, season and trends tabs, WeatherKit conditions, readiness score, Home Screen widgets, forgot-to-stop prompt, end confirmation, start and end time editing, story-safe share cards. CloudKit only, no server.
- **We beat it:** auto field detection, auto halves (it needs a tap to switch sides), run intelligence, live, team, video, referee.
- Two ratings, so quality is **[U]**. Feature list is the clearest statement of current table stakes.

### 3.6 Ballers Club, Memo, Scorza, the rest

- **Ballers Club:** clubs with leaderboards are what reviewers mention (GB Nov 2026: sessions more competitive). Adds Garmin, training plans, 3D exercise guides. Highest price in the set. No event or field depth advertised.
- **Memo Soccer:** rotational multi-team pickup mode with scoring and sub timer, competitions, 10 languages, HUAWEI watch. Cheapest. Serves the pickup night we do not.
- **Scorza:** sells a padded vest pocket for the watch and argues from Law 4 that a covered watch is the compliant one. Its claim that the IFAB confirmed smartwatches is **[U]**; I found the accessory text but no IFAB statement on players' watches. Strategically the sharpest idea in the category.
- **FullPitch:** one share card per match free forever, medals, monthly challenges.
- **MatchDay:** 30-second route recap video, hall of fame, PDF scouting report, $4.99 once.
- **Soccer Plus:** reviews cite sessions stopping unrecorded and having to locate the pitch each time (May 2025, Chinese).

### 3.7 Apple Workout app

- Soccer is a workout type with HR, energy, zones, effort and training load. Users and developers report no route exposed for it: a [developer thread, June 2026, unanswered](https://developer.apple.com/forums/thread/836159) compares ~6.7 km from Apple with ~5.6 km from a third-party builder at matching step counts, and [PlayHeat's listing](https://apps.apple.com/us/app/id6814869600) tells users Apple Watch saves no route in team-sport modes. I did not test this on a device **[U]**.
- [watchOS 27](https://support.apple.com/149077) adds Workout Buddy without a nearby iPhone, better indoor distance and more accurate route maps. Nothing on that page mentions soccer or team sports.
- **Beats us:** trust, start reminders, Workout Buddy voice, effort rating, zero install. **We beat it:** everything that makes a match a match.
- **Implication:** users will compare our distance with Apple's and may see less (about 16% in that one report, so not a general figure). We need to explain the difference before they file a review.

### 3.8 Strava

- [Football (Soccer) is a type with an activity heatmap](https://communityhub.strava.com/t5/strava-insider-journal/football-is-more-than-just-a-game/ba-p/3981). February 2026 added [padel, basketball, volleyball, cricket, dance](https://the5krunner.com/2026/02/22/strava-new-sports/), no match model. $11.99/mo, $79.99/yr; 4.81 (382k); 2025 [Apple Watch App of the Year](https://apple.com/newsroom/2025/12/apple-unveils-the-winners-of-the-2025-app-store-awards).
- Strava sync is a repeated explicit request to Outplay (GB Mar and Apr 2024). We export GPX by hand. Direct upload is worth more than another chart **[J]**.

### 3.9 Garmin

- Soccer activity exists on some models; I found no native soccer heatmap. Third parties fill the gap, such as a [Connect IQ app also named Pitch Pulse](https://forums.garmin.com/developer/connect-iq/f/app-ideas/812/request-soccer-football-performance-tracking-app/2051482). Whether it shares an owner with the iOS app is **[U]**. Ballers Club, Soccer Fitness Tracker and The Outsiders import or support Garmin; we do not.

---

## 4. Hardware and video

| Product | Cost | App signal | Reviews | Versus us |
|---|---|---|---|---|
| [STATSports Apex Athlete](https://statsports.com/us/apex-athlete-series) | [$299.99, no subscription](https://shop.statsports.com/products/apex-athlete-series) (page undated) | 4.8 (2,223); app last updated **Mar 2024** | Motivating; but stale app and basic insight (Jan 2025), pairing failures | Better sprint data. Their consumer app looks parked **[J]** |
| [Sonra Watch](https://apps.apple.com/us/app/id1503020611) | With pro system | 3.67 (3) | n/a | Coach's watch showing up to 8 players live; proof of the coach-wrist concept |
| [Catapult One](https://us-store.catapultsports.com/pages/subscribe) | $14.99/mo or $179.99/yr | 4.54 (507); app last updated **Nov 2023** | Dead pods, failed sessions, no response | Formally discontinued? **[U]**; app looks abandoned |
| [PlayerData EDGE](https://playerdata.com/our-products/edge-individual) | [About £120/yr UK or $219/yr US plus vest](https://playerdata.com/new-pages/product); pages conflict | 4.0 (10) | Thin | Team pricing per unit |
| [Playermaker 2.0](https://apps.apple.com/us/app/id6466816303) / [City.Play](https://apps.apple.com/us/app/id1606915551) | One 2025 review says $149/yr; list price **[U]** | 3.36 (25) / 3.28 (90) | Sensors die, cancellation friction, one parent asks for a watch app | Only ball metrics. Unloved |
| [Oliver](https://futbolemotion.com/gb/buy/others/oliver/tracker-gps-blue) | £106.95 retailer listing | not in US search | no independent review found | Shin-worn, rule-friendly position |
| [Veo](https://apps.apple.com/us/app/id1573754839) | Prices are placeholders on the [public page](https://www.veo.com/en-us/pricing) **[U]** | 4.76 (13,848) | Recent feed is mostly 1 to 2 stars: sign-in, upload, jersey detection | Analytics 2 now gives distance, sprints and top speed from video; Veo Go folded into main app. The real long-term threat to player stats **[J]** |
| [Trace](https://apps.apple.com/us/app/id1351001083) | [About $25 to $35/mo per player](https://pricingsaas.com/companies/traceup) (third party) | 4.76 (4,819) | October 2026 crash-on-launch wave, missed recordings | Automatic per-player highlights parents pay for |
| [Techne](https://apps.apple.com/us/app/id1298569303) | $37.99/mo, $279.99/yr | 4.75 (17,170) | n/a | Training, not tracking. Shows development-minded families pay heavily |
| Metasoccer, JOGO | **[U]** | not found in US search | | Not a live rival from what I found |

**Read:** hardware wins on 10 Hz data and loses on trust, pairing and support. GPS reviews agree that short, sharp accelerations are the weak spot ([over 3 m/s² accuracy is compromised even on sport GPS](https://pmc.ncbi.nlm.nih.gov/articles/PMC8008313)), and I found no published Apple Watch versus 10 Hz soccer study **[U]**. Our accel/decel counts should carry a confidence label.

---

## 5. Referee apps

| App | Price | Rating | Updated |
|---|---|---|---|
| [REFSIX](https://apps.apple.com/us/app/id1235649461) | Free; Plus $2.99/mo; Pro $11.99/mo or $79.99/yr | 4.37 (319); GB 4.55 (284) | 30 Oct 2026 |
| [Soccer Referee Timer by WTSB](https://apps.apple.com/us/app/id6449088307) | $1.99/mo, $17.99/yr, $149 life | 4.6 (15); DE 4.68 (151) | 17 Nov 2026 |
| [Referee Watch PRO](https://apps.apple.com/us/app/id1346806001) | $3.99/mo, $29.99/yr | 4.42 (38) | 18 Nov 2026 |
| [SFRef](https://apps.apple.com/us/app/id1163321127) | $3.99 / $6.99 | 4.44 (162) | Jan 2024 |
| [Match Keeper](https://apps.apple.com/us/app/id1558022379) | $2/mo, $12/yr | 5.0 (15) | 23 Nov 2026 |

- **REFSIX praise:** whole match from the wrist, positioning heatmaps and distance, pays for itself with one match fee (Apr 2026, Nov 2023). **Complaints:** getting worse and freezing on watch (Apr 2026), $80 called outrageous (Apr 2026), lost matches (Nov 2024), subscription not recognised (Nov 2025, GB Nov 2025, GB Oct 2026), 60 to 70% battery per match (Jun 2024), heatmap never appears for a paying user (May 2026). [US](https://itunes.apple.com/us/rss/customerreviews/page=1/id=1235649461/sortBy=mostRecent/json), [GB](https://itunes.apple.com/gb/rss/customerreviews/page=1/id=1235649461/sortBy=mostRecent/json).
- **WTSB** has the momentum: German reviewers switching from REFSIX for ease of use (Sep 2026), automatic stoppage time, voice notes on cards, Season Replay, trading cards, Strava, Action button.
- **Beat us on:** stoppage-time clocks, sin bins, extra time, shootouts, rosters, assignment import (Assignr, Arbiter), match report, weather suspension, training resources.
- **We beat them on:** free movement analytics.
- **Mistake to fix:** our watch `SummaryView` hides the referee's athletic stats as noise. Movement data is exactly what referees pay REFSIX $80 a year for. Referees are also the one group for whom a wrist watch is normal kit.
- **Recommendation [J]:** either build a proper referee mode (stoppage clock, sin bin, report, own heatmap) or drop it from the store copy. A shallow one invites one-star reviews from people whose match depends on it.

---

## 6. Team, parents and live

| App | Price | Rating (count) | Lesson |
|---|---|---|---|
| [GameChanger](https://apps.apple.com/us/app/id1308415878) | Plus $9.99/mo or $39.99/yr; Premium $14.99/mo or $99.99/yr | 4.88 (923k) | Free scoring by any member; families pay for live video and stats. [Soccer stats supported](https://gc.com/post/stats-added-in-multiple-new-sports-including-soccer-and-lacrosse). No iPad-class Duo support and freezing in Nov 2026 reviews |
| [TeamSnap](https://apps.apple.com/us/app/id393048976) | $1.99 to $59.99 tiers | 4.76 (60k) | Schedule, availability, chat are settled. Do not rebuild |
| [Spond](https://apps.apple.com/us/app/id755596884) | Free, payment-funded | 4.85 (4.0k) | Free team admin is the norm |
| [Heja](https://apps.apple.com/us/app/id1157335714) | Plus $3.99/mo or $29.99/yr; Pro $13.49/mo or $99.99/yr | 4.85 (24k) | One coach pays for the team |
| [SubTime](https://apps.apple.com/us/app/id1248650528) | $24.99 to $34.99/yr | 4.73 (740) | Fair minutes is a paid coach problem; listing claims 60k coaches |
| [SEV7N](https://apps.apple.com/us/app/id6766226399) | $2.79 / $22.99 | none yet | Parent journal with live share and Live Activities |

Our live view is mostly same-device or same-team; GameChanger's is a link for grandma. A roster does not all own watches, so a team product that needs every player to wear one will look empty **[J]**. The coach-side manual events and minutes must work with zero watches.

---

## 7. Design benchmarks

- **Slopes** (4.86, 88k; updated the day of this research). [2022 Apple Design Award, Interaction](https://www.apple.com/newsroom/2022/06/apple-announces-winners-of-the-2022-apple-design-awards/). [Apple's profile](https://developer.apple.com/news/?id=wq48r7mj): one press then hands-free; choose the device by situation; auto-lock against gloves; curate stats into a story; full function on GPS alone; accuracy treated as a named design problem. [Live Activity](https://slopes.helpscoutdocs.com/article/225-live-activities) has two user-chosen stats, friends present and a day timeline. [iOS 18 redesign](https://news.getslopes.com/slopes-app-comes-with-a-new-look-alongside-features-for-ios-18/): map-linked data cards, Control Center and Siri control, double tap, Smart Stack, tinted icon. Season recap, 3D and AR replay, iMessage, 18 languages. Declares six App Store accessibility features. Free tier is ad-free and complete. Reviewers credit the free tier (Sep 2026) and complain when redesign hides things (Nov 2026).
- **Gentler Streak** (4.71, 8.9k). [2024 ADA Social Impact; 2022 Watch App of the Year](https://developer.apple.com/news/?id=3m0ht22s). Progress instead of comparison, plain charts, encouraging voice, core free, 10 languages, on-device.
- **The Outsiders** (4.59, 142). Same team, [2026 ADA Interaction finalist](https://developer.apple.com/design/awards/) and Editors' Choice within a year. Already our visual reference, so a close resemblance would undercut originality **[J]**. Reviewers praise clarity and dislike unexplained jargon (Jul 2026).
- **Bevel** (4.85, 18k; $14.99/mo, $99.99/yr) and **Athlytic** (4.79, 11k; $29.99/yr). One answer first, detail second.
- **WorkOutDoors** (4.69, 1.7k; $8.99 once). Configurability wins experts; [needs no subscription](https://apps.apple.com/us/app/id1241909999). September to October 2026 reviews show a watchOS break costs goodwill within weeks.
- **2026 ADA winners** ([Apple](https://www.apple.com/newsroom/2026/06/apple-reveals-winners-of-the-2026-apple-design-awards/)): Tide Guide (full-screen charts, custom animation, sky-driven palette, glanceable hour-by-hour), Moonlitt (Liquid Glass, many platforms, approachable onboarding), Guitar Wiz (VoiceOver, Dynamic Type, Differentiate Without Color), NBA (3D court on Vision Pro). **Structured** was an Inclusivity finalist. I found no "Tempo" among winners I checked **[U]**.

**Pattern:** one subject, one strong visual metaphor, deep platform breadth, accessibility and localisation as features, usually small teams.

---

## 8. Rules: the constraint nobody on our side has designed for

- **IFAB Law 4**: players may not wear electronic communication equipment except permitted EPTS; wearable EPTS in organised competition must be safe and meet FIFA quality requirements ([Law 4](https://www.theifab.com/laws/latest/the-players-equipment/)). From 1 July 2026 [accessories are allowed if not dangerous and safely and securely covered](https://www.theifab.com/law-changes/latest/). Whether a covered smartwatch counts as an accessory or as communication equipment is **[U]** and will be a referee and competition decision.
- **NFHS (US high school) 4-2-11**: wearables may be in the shoe or under the uniform, secured, and not on the arm ([rule change](https://www.nfhs.org/sports-resource-content/soccer-rules-changes-2023-2024/)). The page blocked direct fetch; wording is from search extracts and an [OHSAA memo](https://ohsaaweb.blob.core.windows.net/files/Officiating/dod/Soccer/20230808SoccerMemo.pdf). For [2026-27](https://www.njsiaa.org/sites/default/files/documents/2026-07/nfhs-soccer-rules-changes-2026.pdf) devices that record, transmit or livestream audio or video are banned; live telemetry is ambiguous.
- **Evidence it bites:** a GB SoccerTrackr reviewer was told to remove the watch at half-time (Feb 2020); another covers it with a sweatband (Feb 2023).
- **Product consequence:** body-worn recording changes everything on the watch. No wrist HR, no taps, no raised wrist, wrist detection may lock the watch, and music or Siri can fire in a pocket. It needs scheduled start, auto halves, auto subs, auto stop and no dependence on HR. We already have most of those detectors. No rival found advertises that combination.
- Also: minors plus live location is our highest privacy risk. Default live sharing off in organised youth matches **[J]**.

---

## 9. Table-stakes gaps (ranked by user pain)

1. **Never lose a match, and prove it.** Visible saved state on watch and phone, transfer status, retry, recovery. The most common one-star theme in the category.
2. **Repair after the fact.** Trim, set halves, bench spells, undo a forgotten stop, exclude the drive home. Explicit in SoccerTrackr and Outplay reviews.
3. **Forgot-to-stop and end confirmation.** Heatiz has both.
4. **Believable speed and distance.** Show method and confidence; suppress bad top speeds; explain why Apple's number differs. Our top speed is the maximum instantaneous sample after an outlier cap, so a single bad sample under the cap wins. Use a sustained window (for example one second or more) **[J]**.
5. **Imperial units.** US users see km/h.
6. **Share card.** At least nine rivals have one; we share GPX.
7. **Seasons, trends, personal bests.** Reviewers across apps describe comparing games as the reason they return.
8. **Siri, Shortcuts, Action button, Control Center, Smart Stack start.** SoccerTrackr shipped in October.
9. **Live Activity and Home Screen widgets.**
10. **Strava upload.**
11. **Localisation.** Pitch Pulse 11, Memo 10, PlayHeat 8, Footbar 8. Soccer is the least English-centric sport we could have chosen.
12. **Personal iCloud sync.**
13. **Phone-only or Garmin import** for non-watch teammates.
14. **Declared accessibility.** Most rivals declare nothing, so this is cheap leadership.

---

## 10. Differentiators we could own

1. **Wear-it-anywhere recording.** One tap (or a schedule), watch goes in a vest, nothing else to touch, full match comes out with halves and bench time.
2. **The self-correcting match.** We show what was inferred, how sure we are, and one gesture fixes it. No rival shows uncertainty.
3. **Pitch Atlas.** Community field geometry so the first match at a new ground just works. REFSIX has auto-find; nobody showed an open, refining atlas.
4. **Your match, relived.** Pitch-space replay with runs, HR and events, Slopes-style, exportable as a 15-second vertical video. MatchDay sells a crude version.
5. **Moments.** Goal tap on the wrist finds the clip on a parent's phone. Already built; hide the machinery. Trace parents pay $25 or more a month for this.
6. **Bench-aware load.** Minutes actually played, per-90, and how the team's load is shared. Fair-minutes evidence for coaches.
7. **Sideline link.** A guest watches a Live Activity from a link with no account: score, minute, player on or off. Consent first.
8. **Run stories.** On-device AI titles already exist; extend to a short plain-language match read that cites the numbers it used. Pitch Pulse paywalls this.
9. **Private by default.** On-device analysis, iCloud only, no account, guardian controls. Believable against hardware vendors and video companies.
10. **Referee movement, free.** Only if section 5's depth is built.

---

## 11. Pricing recommendation

**Evidence**

- Direct player apps: $12 to $30 a year typical ($19.99 SoccerTrackr, $24.99 Outplay and FullPitch, $29.99 Pitch Pulse, $39.99 Ballers Club). One-time exists at $3.99 to $4.99.
- Adjacent quality: Athlytic $29.99, Slopes $34.99 plus $3.99 single pass and $59.99 family, Gentler $39.99, Strava $79.99.
- Coach or family payers: SubTime $34.99, Heja Pro $99.99, GameChanger $39.99 to $99.99.
- Anti-evidence: locked metrics produced SoccerTrackr's most recent one-star; $80 REFSIX called outrageous; hardware subscriptions resented. Reviewers praise free tiers at Slopes and Outplay.

**Recommend [J]**

| Tier | Price | Contains |
|---|---|---|
| Free | $0 forever | Unlimited recording, heatmap, events, halves, subs, score, share card, Live Activity, Siri, Strava, iCloud, **history import** |
| Plus | **$24.99/yr**, $3.99/mo; Family Sharing at $39.99; test a one-off season pass, as Slopes does with day passes | Replay export, season recap, trends, AI read, cohort percentiles, readiness |
| Team | **$59.99/yr per team, one payer** (replace $3.99/mo) | Coach dashboard, minutes fairness, clips library, chat. Players' Plus is separate |

- Move backlog import out of the paywall. It is the single best first-run moment: a new user with two years of Health matches sees a season in a minute.
- Offer Family Sharing; Athlytic, Memo, SubTime and Slopes do.
- $3.99 a month for a team (about $48 a year) is below what coaches pay for single-purpose tools, and the monthly-only shape fits a 10-week season badly. Annual plus a season option is better.
- These price points are positioned by comparables, not tested. Run a price test before committing.

---

## 12. What ADA-class apps do that we must match

| Interaction | Bar | Ours |
|---|---|---|
| Start | Siri, Shortcuts, Action button, Control Center, Smart Stack, geofence automation | Complication only |
| Live Activity | Lock Screen, Dynamic Island, Smart Stack: score, minute, on/off, two user-picked stats | None |
| | Caveat: Slopes needs the iPhone app opened once when recording starts on watch. [Background start is restricted](https://developer.apple.com/forums/thread/731252); push-to-start or an intent may avoid it. Workout mirroring as a trigger is **[U]**, prototype first | |
| App Intents | StartMatch(format), LogEvent(kind), EndHalf, GetLastMatch, OpenMatch; match, field and season as entities for Spotlight | None |
| Widgets | Last match pitch card, season, readiness, next match; interactive; StandBy; tinted; iPhone and iPad | Four watch families, two widgets |
| Share images | Story-safe 9:16, square and transparent overlay, pitch-first, privacy toggle for place and health, animated route | None |
| Season recap | Auto story at season end, monthly mini-recap, shareable | None |
| Replay | Scrub a single timeline that drives map, HR and events | Separate sections |
| Progress | Personal bests announced at the whistle, like Apple's awards, without shaming | None |
| Watch | Haptic vocabulary per event, Crown to adjust, Double Tap, Water Lock auto, on-wrist heatmap at the end, effort rating, watchOS 27 [workout zones](https://developer.apple.com/watchos/whats-new/) | Partly |
| Accessibility | VoiceOver description and audio graph for the heatmap, Larger Text, Differentiate Without Color (heat ramp and team colours), Sufficient Contrast, Reduce Motion, Voice Control; **declare them on the App Store** | Labels and Reduce Motion only |
| Localisation | es, pt-BR, de, fr, it, ja, ko, ar with RTL, culturally correct terms (football or soccer, pitch or field) and units | None |
| Onboarding | Value before permission; sample match; import history | Good sample, import gated |
| Failure | Every missing thing says why and what to do | Improving |
| New hardware | iPhone Duo support comes up in GameChanger and WorkOutDoors reviews and Outplay's release notes | Not checked |

**Featuring** ([Apple](https://developer.apple.com/app-store/getting-featured/)): user experience, UI design, innovation, uniqueness, accessibility, localisation, product page. Nominate at least two weeks ahead and up to three months for wider consideration. **ADA categories** ([Apple](https://developer.apple.com/design/awards/)): Delight and Fun, Inclusivity, Innovation, Interaction, Social Impact, Visuals and Graphics. Best fits: **Interaction** (hands-free match) and **Visuals and Graphics** (the pitch). Youth inclusion could support Social Impact later.

---

## 13. Would Apple acquire or feature this?

### What Apple has bought

| Deal | Date | Outcome | Verified |
|---|---|---|---|
| Workflow | Mar 2017 | Shortcuts; whole product and team; 2015 ADA praised for VoiceOver | [TechCrunch](https://techcrunch.com/2017/03/22/apple-has-acquired-workflow-a-powerful-automation-tool-for-ipad-and-iphone/) |
| Gliimpse | 2016 | Health records effort | [MacRumors](https://www.macrumors.com/2016/08/22/apple-acquires-gliimpse) |
| Beddit | May 2017 | Sleep sensing | [Wikipedia list](https://en.wikipedia.org/wiki/List_of_mergers_and_acquisitions_by_Apple) |
| Tueo Health | Reported May 2019 | Asthma monitoring | [9to5Mac](https://9to5mac.com/2019/05/24/apple-tueo-health/) |
| Dark Sky | Mar 2020 | Weather, WeatherKit; Android closed | [MacRumors](https://www.macrumors.com/2020/03/31/apple-acquires-weather-app-dark-sky/) |
| NextVR | May 2020 | Immersive video, sports rights experience | [MacRumors](https://www.macrumors.com/2020/05/14/apple-acquires-nextvr/) |
| AI Music | Feb 2022 | Adaptive music; product outcome unclear | [AppleInsider list](https://appleinsider.com/inside/acquisitions), single source |
| Pixelmator | Announced Nov 2024 | Retained apps | [MacRumors](https://www.macrumors.com/2024/11/01/apple-acquires-pixelmator/) |
| Color.io, Play, Samplab, MotionVFX, Sonera, Q.ai | 2026 reports | Creative tools, sensing, AI | [MacRumors](https://www.macrumors.com/guide/apple-acquisition) |
| **Union.ai** | n/a | **No evidence Apple bought it.** Likely confusion with Union Bay Networks, 2014 | searched |

I found **no Apple purchase of a consumer fitness or sports tracking app** in these lists (MacRumors 2024 to 2026; part of the Wikipedia list, which I did not read in full). Fitness consolidation happens elsewhere: Strava bought [Runna and The Breakaway](https://techcrunch.com/2025/05/22/strava-is-buying-up-athletic-training-apps-first-runna-and-now-the-breakaway) in 2025.

### Why not

- Apple buys sensing, infrastructure, data assets and creator tools. A single-sport tracker is an app category Apple can build and has chosen not to deepen.
- No scale: direct rivals measure US ratings in tens.
- Custom backend with minors' location and team chat is a liability in diligence.
- Health strategy is being cut back rather than expanded: [Health+ coach reportedly scaled back](https://macrumors.com/2026/02/05/apple-reportedly-scales-back-ios-27-feature), Feb 2026 (Gurman).
- No moat if it is heuristics on public APIs. The player-rule ambiguity limits addressable matches.

### Why maybe

- Workflow and Dark Sky both show Apple buys when one small team owns a capability and the data behind it. Ours would be **a worldwide pitch-geometry dataset plus a robust bounded-field-sport engine** (period, bench and run inference from wrist sensors), generalisable to rugby, hockey, lacrosse. The Workout app has no match model.
- Soccer matters to Apple: all MLS matches are on [Apple TV from 2026](https://www.apple.com/newsroom/2026/07/major-league-soccer-returns-to-apple-tv-tomorrow/), and Apple Sports covers leagues. Participation plus viewing is an appealing story. No evidence Apple plans it **[U]**.
- Eddy Cue now runs [Health and Fitness](https://www.macrumors.com/2025/10/10/apple-health-fitness-teams-eddy-cue-reshuffle/) alongside sports media, which is the only organisational link **[J]**.

**Honest odds [J]:** acquisition is very unlikely and should not shape decisions, beyond keeping data on device, licences clean and the engine in `MatchTrackerKit`. Editorial featuring is realistic with sections 9 and 12 done. ADA finalist is a multi-year stretch; The Outsiders shows a small watch-first team can do it in one, with a pedigree.

**If we want to be featured, the order is:** reliability, accessibility declared, eight languages, App Intents and Live Activity on the newest SDK, one iconic pitch visual, then a nomination roughly three months before a soccer moment (MLS season start in February; northern autumn season).

---

## 14. Open questions to close with a device or a person

1. Apple Workout outdoor soccer versus ours on one match: distance, route, energy.
2. Watch in a vest: GPS quality, wrist detection lock, accidental input, Double Tap off.
3. Does mirroring let the iPhone raise a Live Activity without opening the app?
4. Written answers from two state associations, one county FA and the IFAB on covered watches.
5. Hands-on with Heatiz, Pitch Pulse, SoccerTrackr 27 and WTSB. Everything here about them is listing-level.
6. Validation against a 10 Hz pod for distance, HSR and top speed.
