# User demand: soccer tracking on Apple Watch

Desk research, 2026-11-23. Public pages only. Everything below is a paraphrase.

## How far to trust this

- **Reddit was not read.** Reddit blocks Anthropic's user agent for both search and fetch, and it was not worked around. Nothing here is from r/bootroom, r/AppleWatch, r/Referees, r/SoccerCoachResources, r/Strava or any other subreddit. This is the largest hole in the sample.
- **Evidence grades.** **[P]** = page fetched and read through a summarizing fetch tool. **[S]** = seen only as a search-engine extract, because the page refused fetches. All Apple Support Communities threads are [S] (they redirected), as are two of the three Strava Community threads and everything on RefChat. Re-open an [S] link before quoting it. **[C]** = checked in this repo's code by reading, not by running it.
- **Counts are distinct sources seen, not prevalence.** "5 sources" means five threads, reviews or rulebooks. App Store pages show only about four reviews per app, so counts there are a floor.
- **Sample bias.** Review-writers and forum posters over-represent enthusiasts and referees. Garmin owners stand in for "watch-wearing soccer players" in several rows. Parents are thin, and no one in the sample describes MatchTracker itself.
- Several threads are 2011–2019. Dates are shown where the page gave one.

## Ranked: what people want or complain about

| # | Want / complaint | Seen | Sources | MatchTracker today |
|---|---|---|---|---|
| 1 | Permission to wear it at all: referees and leagues make players take watches off | 12 sources, the strongest theme | See [Deal-breakers](#deal-breakers) | **Not addressed.** No pre-match rules help, no capture path without a wrist watch |
| 2 | A heatmap, or position picture, that is right | 10+: near-universal in competitor reviews | SoccerTrackr [US](https://apps.apple.com/us/app/id1348552393) and [UK](https://apps.apple.com/gb/app/soccertrackr/id1348552393), [Soccer Plus](https://apps.apple.com/us/app/id1577752006), [Outplay](https://apps.apple.com/us/app/id6444451247), [Training Tracker Pro](https://apps.apple.com/us/app/id1665755661), [Strava journal](https://communityhub.strava.com/insider-journal-9/football-is-more-than-just-a-game-1557) (13 likes), [Garmin request](https://forums.garmin.com/developer/connect-iq/f/app-ideas/812/request-soccer-football-performance-tracking-app) [all P] | **Yes.** Field geometry is the differentiator. A wrong heatmap loses trust ([SoccerTrackr UK](https://apps.apple.com/gb/app/soccertrackr/id1348552393)) |
| 3 | Believable distance and top speed. Users report 25–30 mph, 27 mph and about 74 mph sprints | 8 | [SoccerTrackr US](https://apps.apple.com/us/app/id1348552393) (3 reviews), [Garmin fenix 7](https://forums.garmin.com/outdoor-recreation/outdoor-recreation/f/fenix-7-series/293279/fenix-7x-football-activity), [REFSIX](https://apps.apple.com/us/app/id1235649461) [P]; [Apple dev forum](https://developer.apple.com/forums/thread/836159) (June 2026: 6.7 km in Workout vs 5.6 km third-party, 854 views, no answer) [P] | **Partly.** Speeds above 12 m/s (26.8 mph) are rejected [C]. That still lets an absurd 26 mph amateur "top speed" through. Expect "why is it lower than Apple's?" questions |
| 4 | Don't lose my game: silent stops, crashes, blank screens, duplicates | 7 | [Soccer Plus](https://apps.apple.com/us/app/id1577752006) (2 reviews), [REFSIX aggregate](https://justuseapp.com/en/app/1235649461/refsix-soccer-referee/reviews) (2), [SFRef](https://apps.apple.com/us/app/id1163321127) (resets at halftime), SoccerTrackr [release notes](https://apps.apple.com/gb/app/soccertrackr/id1348552393), [REFSIX US](https://apps.apple.com/us/app/id1235649461) [P] | **Being addressed.** Session recovery, route journal and the pending queue exist [C] |
| 5 | Fix it afterwards: split halves, drop bench time, correct start/end, trim | 5 | [Outplay](https://apps.apple.com/us/app/id6444451247), [BigSoccer smartwatch apps](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/), [SubTime](https://apps.apple.com/us/app/id1248650528), [Garmin soccer request](https://forums.garmin.com/apps-software/mobile-apps-web/f/garmin-connect-web/144143/please-add-soccer-as-an-activity/1676101) (forgot to stop, recorded the drive home); trimming shipped by Outplay 3.4 and SoccerTrackr 26.2.6 [P] | **Gap.** Events can be added or deleted on the phone, but an added event is stamped "now, clamped to the match", so a post-match add lands at full time. No time editing and no start/end trim found [C] |
| 6 | Apple's and Strava's own soccer support is not enough: no route, distance or speed | 8 | [Training Tracker Pro](https://apps.apple.com/us/app/id1665755661) (2) [P]; Apple threads [255171891](https://discussions.apple.com/thread/255171891), [252498239](https://discussions.apple.com/thread/252498239), [251058961](https://discussions.apple.com/thread/251058961) [S]; [Strava: no heatmap, 0 kph](https://communityhub.strava.com/devices-and-connections-6/apple-watch-soccer-workout-heatmap-11081), [Strava idea, "Not Currently Planned"](https://communityhub.strava.com/t5/ideas/gps-tracking-for-football-soccer/idi-p/4755) [S] | **Yes.** MatchTracker saves an `HKWorkoutRoute` [C]. This is the clearest acquisition message |
| 7 | Accidental input: sleeve, crown, side button, Action button | 7 | [BigSoccer](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/) [P]; Apple [254814945](https://discussions-cn-prz.apple.com/thread/254814945) (Ultra, football specifically), [254723918](https://discussions.apple.com/thread/254723918), [255490916](https://discussions.apple.com/thread/255490916), [254422426](https://discussions.apple.com/thread/254422426) (squash), [255005827](https://discussions.apple.com/thread/255005827) [S]; Pitch Pulse shipped Water Lock controls in [1.5.9](https://apps.apple.com/app/id6762101356) [P] | **Partly.** Lock tile exists. End has no confirmation, and sessions under 30 s are discarded silently [C]. Press-to-pause behavior in our session is untested |
| 8 | Protect the watch, and the other player | 6 | [MacRumors 1876810](https://forums.macrumors.com/threads/should-i-wear-my-apple-watch-while-playing-sports.1876810/), [MacRumors 2072850](https://forums.macrumors.com/threads/how-to-wear-watch-while-playing-sports.2072850/) [P]; Apple [252344053](https://discussions.apple.com/thread/252344053) (goalkeeper), [8194854](https://discussions.apple.com/thread/8194854), [7215565](https://discussions.apple.com/thread/7215565) [S] | **Not addressed** in product. Advice, not features |
| 9 | Goals, assists and score attached to the game | 5 | [Soccer Fitness Tracker](https://apps.apple.com/us/app/id6756504677) (a user asked; shipped in 6.0.0 as phone-side stats), [Garmin request](https://forums.garmin.com/developer/connect-iq/f/app-ideas/812/request-soccer-football-performance-tracking-app), [Memo Soccer](https://apps.apple.com/app/id6740020160), [SubTime](https://apps.apple.com/us/app/id1248650528), [HN comment](https://news.ycombinator.com/item?id=45871075) [P] | **Yes** on watch. Phone path is weak (row 5) |
| 10 | Indoor / futsal that records something sane | 5 | [fenix 8](https://forums.garmin.com/outdoor-recreation/outdoor-recreation/f/fenix-8-series/404083/indoor-football-soccer-does-not-count-the-distance-properly) (about 0.2 mi in 40 min vs 2–3 mi in treadmill mode), [vivoactive 3](https://forums.garmin.com/sports-fitness/healthandwellness/f/vivoactive-3-3-music/217898/indoor-soccer), [Garmin 144143](https://forums.garmin.com/apps-software/mobile-apps-web/f/garmin-connect-web/144143/please-add-soccer-as-an-activity/1676101), [Soccer Fitness Tracker 6.1](https://apps.apple.com/us/app/id6756504677), blue card for indoor refs in [REFSIX aggregate](https://justuseapp.com/en/app/1235649461/refsix-soccer-referee/reviews) [P] | **Partly.** Indoor mode is heart-rate led with no GPS [C] |
| 11 | Friends and team: compare after the game | 4 | [Pitch Pulse](https://apps.apple.com/app/id6762101356), [Zepp](https://apps.apple.com/us/app/id1021453611) (wanted self-over-time instead), [SoccerBeat](https://apps.apple.com/us/app/runmatch/id6470206109) badges [P] | **Yes** for rosters. Note the Zepp counter-request: compare me with me |
| 12 | Don't charge me every month for my own data | 5 | [REFSIX aggregate](https://justuseapp.com/en/app/1235649461/refsix-soccer-referee/reviews), [PitcheroGPS](https://uk.trustpilot.com/review/pitcherogps.com?page=4), [Soccer Fitness Tracker](https://apps.apple.com/us/app/id6756504677) (praised for being free) [P]; [SoccerBee](https://ie.trustpilot.com/review/soccerbee.io) [S]. Counter: one SoccerTrackr reviewer does not mind subscribing | Team subscription only [C: StoreKit, paywall]. Personal tracking stays free |
| 13 | Watch instead of a vest or pod | 3 | [Training Tracker Pro](https://apps.apple.com/us/app/id1665755661) (StatSports-like without the hardware) [P]; vest setup, fit and pairing complaints at [PitcheroGPS](https://uk.trustpilot.com/review/pitcherogps.com?page=4) [P], [PlayerTek](https://ca.trustpilot.com/review/playertek.com?page=2) [S] | **Yes**, but row 1 is why people buy vests |
| 14 | Lines and runs as well as a heatmap; bench time pollutes the heatmap | 2 (one long thread) | [Garmin heat vs tracks](https://forums.garmin.com/sports-fitness/healthandwellness/f/vivoactive-4-series/389550/how-can-i-change-the-setting-from-heat-tracking-back-to-the-standard-tracks), [Heatmapper](https://apps.apple.com/us/app/heatmapper/id1551397226) (half-time side switch) [P] | **Yes.** Runs view, per-half attack direction and substitution intervals [C]. Say so |

## Before the match

| Want | Seen | Paraphrase and source | MatchTracker |
|---|---|---|---|
| Will the ref let me wear it? | 12 | See deal-breakers | No |
| Start in one action, no set-up | 4 | Wants to start a match without filling in details first ([REFSIX](https://apps.apple.com/us/app/id1235649461)); one tap per game is the praised bit ([SoccerBeat](https://apps.apple.com/us/app/runmatch/id6470206109)); disliked locating the pitch every time ([Soccer Plus](https://apps.apple.com/us/app/id1577752006)); complication for quick start ([Pitch Pulse 1.5.4](https://apps.apple.com/app/id6762101356)) [P] | Start widget and auto field detection help. No Action button or App Intent start found [C] |
| Don't make me start two workouts | 1 | Did not realize the app already wrote to Health ([Outplay](https://apps.apple.com/us/app/id6444451247)) [P] | Writes to HealthKit. Tell users at onboarding |
| Refs: load fixtures and rosters for me | 6+ | Most repeated referee complaint in one 20-review aggregate ([REFSIX](https://justuseapp.com/en/app/1235649461/refsix-soccer-referee/reviews)); [SFRef](https://apps.apple.com/us/app/id1163321127) users fake matches to skip entry [P] | No. A zero-entry referee mode is arguably better than competing on import |

## During play

| Want | Seen | Paraphrase and source | MatchTracker |
|---|---|---|---|
| Nothing to do at all | 4 | One Garmin poster would track goals and assists mentally and cares only for distance ([Garmin](https://forums.garmin.com/developer/connect-iq/f/app-ideas/812/request-soccer-football-performance-tracking-app)); Pitch Pulse sells "no setup" ([listing](https://apps.apple.com/app/id6762101356)); referees revert to paper mid-match ([BigSoccer p.2](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/page-2)); "less is more" review ([Training Tracker Pro](https://apps.apple.com/us/app/id1665755661)) [P] | Auto subs and period detection fit this. The Events page does not |
| Not be paused or ended by contact | 7 | Ultra owner: accidental pauses playing football even with Water Lock on ([254814945](https://discussions-cn-prz.apple.com/thread/254814945)) [S] | Partly |
| Log goals anyway | 4 | [Memo Soccer](https://apps.apple.com/app/id6740020160) is built on it but has 4 ratings; Garmin users imagined the lap button ([812](https://forums.garmin.com/developer/connect-iq/f/app-ideas/812/request-soccer-football-performance-tracking-app)) [P] | Yes |
| Readable at a glance, no wake delay | 3 | Ref: the wrist-raise delay is distracting, stopwatch text too small (2015, [BigSoccer](https://www.bigsoccer.com/threads/apple-watch.2019869/)); larger numbers in [Pitch Pulse 1.5.9](https://apps.apple.com/app/id6762101356) [P] | Metrics page is the landing page |
| Refs: haptic alerts, up and down clocks, undo, fast cards | 6 | Vibrate at half/full time; dual clock; slow player lists; mistakes not fixable until full time ([BigSoccer](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/)); sin-bin timer; physical-button start vs touch start is disputed between two users ([p.2](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/page-2)) [P] | Cards, fouls and halves exist. No on-watch undo or dual clock seen in the files read [C, partial] |

### Will players tap the watch during play?

Evidence is mostly against it.

- **The rules make it risky to be seen.** 2025/26-era answers tell referees to stop watch-wearers ([Ask the Ref, Oct 2024](https://www.asktheref.com/atr_search.asp?QuestionID=35759)) [P]. A player who visibly taps a watch advertises it. One referee's stated line is that a tracker they cannot see is not their problem ([BigSoccer](https://www.bigsoccer.com/threads/fitbit-as-secondary-watch.2038749/page-2)) [P].
- **Compliance means covering it.** The 2026/27 Law 4 allows accessories only if covered (see below). A covered watch cannot be tapped.
- **Locking removes the taps.** Water Lock blocks touch, and Apple lists it, with Low Power Mode, among the things that disable double tap ([HT210931](https://support.apple.com/en-us/HT210931), [108413](https://support.apple.com/en-us/108413)) [P]. So the Lock tile and the double-tap shortcut cannot be used together.
- **Double tap is a poor in-play input.** Apple says gestures are less reliable while moving, need a raised wrist, need Series 9 / Ultra 2 / SE 3 or later, and can fire unintentionally ([108413](https://support.apple.com/en-us/108413)) [P]. In our code the shortcut is attached only on the Controls and Events pages, and the wrist-raise page is Metrics, so it probably does nothing from the landing page [C, inferred].
- **Even referees, who stand still and must log, struggle.** They mis-tap, find entry slow, and carry paper ([BigSoccer](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/)) [P].
- **A user who asked for goals got them elsewhere.** Soccer Fitness Tracker answered with score, goals, assists and notes in its phone app ([listing](https://apps.apple.com/us/app/id6756504677)) [P]. Whether a watch version exists is unverified.
- **Counter-evidence.** Memo Soccer and REFSIX do real-time watch entry, REFSIX added multi-sub entry on the watch in Oct 2025 ([listing](https://apps.apple.com/us/app/id1235649461)), and a goal leaves a stoppage in which a tap is feasible. Nobody in the sample reported whether they actually tap mid-game, so this stays an inference. Instrument it in the beta.

## Halftime and substitution

| Want | Seen | Paraphrase and source | MatchTracker |
|---|---|---|---|
| Bench time kept out of my stats and map | 3 | Heatmap mostly showed the bench ([Garmin](https://forums.garmin.com/sports-fitness/healthandwellness/f/vivoactive-4-series/389550/how-can-i-change-the-setting-from-heat-tracking-back-to-the-standard-tracks)); wants to remove sub time ([Outplay](https://apps.apple.com/us/app/id6444451247)) [P] | Yes: auto subs, manual toggle |
| One recording across both halves | 4 | Each interval became its own activity ([BigSoccer](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/)); had to run two workouts because sides switch ([Heatmapper](https://apps.apple.com/us/app/heatmapper/id1551397226)); matches reset at half ([SFRef](https://apps.apple.com/us/app/id1163321127)) [P] | Yes: period detection and per-half direction |
| Auto-pause at half, alert on a missed sub | 1 | [SubTime](https://apps.apple.com/us/app/id1248650528) coach [P] | Not for coaches |
| Coaches: equal minutes per child | 2 | Running totals plus time since last sub ([SubTime](https://apps.apple.com/us/app/id1248650528), 740 ratings) [P]; other coach apps [S] | Only for children wearing a watch, which youth rules often ban |

## Right after the match

| Want | Seen | Paraphrase and source | MatchTracker |
|---|---|---|---|
| A saved match, every time | 7 | Row 4 | In progress |
| Compare with a mate on the spot | 2 | Enjoys comparing speed and distance after games ([Pitch Pulse](https://apps.apple.com/app/id6762101356)) [P] | Roster leaderboard |
| Beat my top speed | 2 | A max-speed chase is what makes it fun ([Training Tracker Pro](https://apps.apple.com/us/app/id1665755661)) [P] | Top speed yes. Personal bests not verified |
| A shareable image | 3 | Instagram Stories sharing broken and noticed ([SoccerTrackr](https://apps.apple.com/us/app/id1348552393)); share styles and highlight video ([Pitch Pulse](https://apps.apple.com/app/id6762101356)); redesigned sharing ([Soccer Plus 1.6.2](https://apps.apple.com/us/app/id1577752006)) [P] | **Gap.** Export menu offers GPX and CSV. No image or story card found there [C] |

## At home

| Want | Seen | Paraphrase and source | MatchTracker |
|---|---|---|---|
| Strava and Apple Health without fuss | 4 | Praised when it links ([Outplay](https://apps.apple.com/us/app/id6444451247)); football type and heatmap prized over logging as a run, which ruins running stats ([Strava journal](https://communityhub.strava.com/insider-journal-9/football-is-more-than-just-a-game-1557)); [HN](https://news.ycombinator.com/item?id=22175014) commenters use HealthFit to get workouts out [P] | Health route yes. No direct Strava code found [C]. Whether our workouts arrive in Strava with a map is **untested** |
| Understand it, not just see it | 3 | Wants guidance on reading the data ([PitcheroGPS](https://uk.trustpilot.com/review/pitcherogps.com?page=4)); insights praised ([Soccer Fitness Tracker](https://apps.apple.com/us/app/id6756504677)); used the heatmap to rethink position ([SoccerTrackr](https://apps.apple.com/us/app/id1348552393)) [P] | Run narrator, position and load sections |
| Align the field by hand when needed | 2 | Aligning is hard when the overlay hides the field ([Zepp](https://apps.apple.com/us/app/id1021453611)); refs want a movable heatmap ([REFSIX](https://apps.apple.com/us/app/id1235649461)) [P] | Corner editor |
| Calories that agree with Apple's | 2 | Half of Apple's number ([SoccerTrackr US](https://apps.apple.com/us/app/id1348552393)); doubts calorie count ([UK](https://apps.apple.com/gb/app/soccertrackr/id1348552393)) [P] | Uses HealthKit active calories |
| VO2 max | 2 | [Outplay](https://apps.apple.com/us/app/id6444451247), [Training Tracker Pro](https://apps.apple.com/us/app/id1665755661) [P] | Shown as load context |

## Between matches and across a season

- **Me against me:** one Zepp reviewer preferred comparing their own games over time to comparing teammates ([Zepp](https://apps.apple.com/us/app/id1021453611)) [P]. Trends, per-90 and monthly recaps keep shipping elsewhere ([Outplay 3.4](https://apps.apple.com/us/app/id6444451247), [Pitch Pulse 1.4](https://apps.apple.com/app/id6762101356)). MatchTracker has a season heatmap comparison and training load. No per-90 metric found [C].
- **Bring old and other-device matches in:** Garmin `.fit` and any-HealthKit-source import ([Soccer Fitness Tracker](https://apps.apple.com/us/app/id6756504677)) [P]. MatchTracker imports the HealthKit backlog only.
- **Team comparison:** monthly leaderboards and head-to-head shipped within a month of Pitch Pulse launching ([listing](https://apps.apple.com/app/id6762101356)) [P]. Roster leaderboard exists.
- **Motivation for kids:** a parent says the tracker makes their child run further ([PitcheroGPS](https://uk.trustpilot.com/review/pitcherogps.com?page=4)) [P]. Youth wearing rules limit this on a wrist.
- **Parents following live:** strong for team apps ([GameChanger](https://gc.com/soccer) and similar) [S]. Nothing read shows parents asking for live player GPS.

## Deal-breakers

### 1. Wearing a watch in play

**The law changed on 1 July 2026, and not simply in our favor.**

- Law 4 no longer bans "jewellery" outright. Accessories are allowed if not dangerous and "safely and securely covered"; dangerous items must come off and cannot be covered instead. The stated reason is that the ban was confrontational and inconsistently applied. [IFAB changes](https://www.theifab.com/law-changes/latest/), [change document](https://downloads.theifab.com/downloads/changes-to-the-laws-of-the-game-202627?l=en), in force 1 July 2026, or the next competition start at the latest ([Circular 32](https://downloads.theifab.com/downloads/circular-32?l=en)) [P]
- **No source says whether a smartwatch counts as a non-dangerous accessory.** Treat any claim that watches are now legal as unverified. The referee still decides.
- Law 4 separately bars players from electronic communication equipment except permitted tracking systems ([FA Law 4](https://www.thefa.com/football-rules-governance/lawsandrules/laws/football-11-11/law-4---the-players-equipment)) [P]. A cellular or connected watch could be refused under that clause. That is our inference.

| Venue | Rule | Source |
|---|---|---|
| FXA (US adult leagues) | Watches and trackers off, named explicitly; a player seen wearing one must leave the field to remove it before returning | [policy](https://help.fxasports.com/jewelry-policy), [soccer rules](https://help.fxasports.com/soccer) [P] |
| City of Irvine adult 11v11, Summer 2026 | Watches off | [bylaws](https://www.cityofirvine.gov/sites/default/files/legacy-documents/adult-soccer-league-bylaws-11v11-summer-2026-1.pdf) [P] |
| UMass Lowell indoor intramural | Watches off | [rules](https://uml.edu/campusrecreation/programs/intramurals/sports-rules/soccer.aspx) [P] |
| SCSL | Apple Watch named as banned | [rules, search extract only, page now 404](https://apch.org/wp-content/uploads/2024/01/SCSL-Soccer-Rules-1.pdf) [S] |
| Oakville youth rec U12 and under | Watches, Fitbits and Apple Watches off | [policy](https://www.oakvillesoccer.ca/wp-content/uploads/policies-documents/club-info/jewelry-policy.pdf) [P] |
| US high school (NFHS 2026-27) | Bars audio/video devices that record, transmit or livestream; electronic communication on field prohibited | [NFHS comments](https://nfhs.org/resources/sports/soccer-comments-on-the-rules-2026-27) [S] |
| **Alaska outdoor** | **Fitness watches allowed if smooth-edged and tight to the wrist** | [rules 5.6.2](https://socceralaska.com/outdoor-rules) [P] |
| Northeastern intramurals | No jewelry in contact sport. Watches not mentioned | [policy](https://recreation.northeastern.edu/?p=2355) [P] |

These sources predate, or do not mention, the July 2026 change. Some leagues may update.

**Referee opinion** has leaned against for years: treat wristband trackers as jewelry in competition, with each referee deciding on the day ([Ask A Soccer Referee, 2013](https://www.askasoccerreferee.com/?p=3915)) [P].

**Practice differs from the rule.** An indoor player in 2020 wanted to report an opponent's Apple Watch, then saw about a third of both teams wearing one ([HN](https://news.ycombinator.com/item?id=22175014)); a reply hides theirs under a wristband. A rec basketball player's league allows hair bands only. An adult rec league in Canada was proposing to allow watches, and a referee wrote in to object ([2024](https://www.asktheref.com/atr_search.asp?QuestionID=35759)) [P].

**Implications:** lead with pickup, 5-a-side, indoor and training, and with referees, who may wear a watch. Verify a covered watch still gives usable heart rate, GPS and Water Lock. Add a "check your league, cover it" line at onboarding. A phone-in-pocket mode like [Outplay's](https://apps.apple.com/us/app/id6444451247) is the only existing answer for banned leagues, and it is praised.

### 2. Accidental taps and presses
Seen 7 times (row 7). Water Lock does not stop hardware-button pause ([254814945](https://discussions-cn-prz.apple.com/thread/254814945)) [S]. Users' fix for Apple's own Workout app is turning off Press to Pause ([254422426](https://discussions.apple.com/thread/254422426)) [S]. **Test:** side button plus crown, and the Action button, during a live MatchTracker session.

### 3. Broken screen, hurt opponent, warranty
Seen 6 times. Advice runs from "take it off" through Spigen cases and AppleCare to sweatbands. One 5-a-side player bought the watch to track soccer and stopped using it for that until a case shipped ([MacRumors 2015](https://forums.macrumors.com/threads/should-i-wear-my-apple-watch-while-playing-sports.1876810/)) [P]. Goalkeepers are told to leave it off ([252344053](https://discussions.apple.com/thread/252344053)) [S]. Some respondents said a chest strap or under-shirt sensor is the right answer ([MacRumors](https://forums.macrumors.com/threads/how-to-wear-watch-while-playing-sports.2072850/), [BigSoccer](https://www.bigsoccer.com/threads/fitbit-as-secondary-watch.2038749/page-2)) [P]. Chest-strap support on our watch app is unverified.

### 4. Battery
Weaker than expected. Three mentions: refs cover only a limited number of matches per charge ([BigSoccer 2022](https://www.bigsoccer.com/threads/smartwatch-apps.2121234/)); one match used a large chunk in 2015 ([BigSoccer](https://www.bigsoccer.com/threads/apple-watch.2019869/)); HN runners report roughly 10% an hour as fine ([HN](https://news.ycombinator.com/item?id=22175014)) [P]. Battery matters for **referees and tournaments**, not a single 90 minutes. Note Low Power Mode also disables double tap.

### 5. Heart rate at high intensity
Two mentions, both wrist: 60 bpm while sprinting ([Garmin](https://forums.garmin.com/sports-fitness/healthandwellness/f/vivoactive-3-3-music/217898/indoor-soccer)); implausibly high ([SoccerTrackr UK](https://apps.apple.com/gb/app/soccertrackr/id1348552393)) [P].

## What people do with the data

1. **Chase a number** (top speed, distance) and compare with one friend or team.
2. **Read position:** was I defending or attacking, am I where I think I am.
3. **Close rings / keep Apple Health right.**
4. **Post to Strava** as football, not as a run, with a heatmap rather than a scribble.
5. **Share an image** (Stories, posters, animated heatmap).
6. **Judge fitness over time** (heart rate and distance for amateur games).
7. **Referees:** replace the notebook, self-review, report cards. The data is work, not vanity.

## Suggested next steps from this evidence

1. Make post-match correction first-class: timestamps on added events, trim, sub and half edits (rows 5 and 9).
2. Reposition watch buttons as stoppage, bench and referee tools, and measure in-play taps in beta.
3. Verify Strava import with map; add a share image.
4. Add a wear-it-legally line, a covered-watch test and a Lock-by-default option; test hardware-button pause.
5. Consider lowering the 12 m/s cap, or an amateur plausibility rule, before any "top speed" leaderboard.
6. Have a human read Reddit; this document cannot.
