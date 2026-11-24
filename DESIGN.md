# MatchTracker design

Platform: iOS 17+ and watchOS 10+ (newer features behind availability checks; never raise the minimum).
Native first: if Apple ships a control for it, use that control.

## Who and when

- **Walking off the pitch** — tired, outdoors, one hand. "How did we do, how did I do, is it saved?" One screen, no interaction.
- **On the couch that night** — "Show me the good bit. Was I any good?" Scrub, replay, share.
- **Between matches** — "Am I getting better? Who's next?" The season.
- **During play (watch)** — a half-second glance. Nothing to tap. Tapping happens on the bench and at stoppages.

## The look: woven

Every match is knitted into its own cloth, and the numbers on it are kit numbers. Evidence and the full
palette are in `docs/research/football-fashion-2026.md`.

- **Cloth** is the color of the team's kit (bottle green until somebody chooses), the same by day and by night, with a pinstripe and a hem. Every shade comes from `KitColors`, which holds lightness fixed so any team's color is as readable as any other's; never write a brand color by hand. One cloth surface per screen, and it holds the hero. Everything around it is a native list on the canvas.
- **Pattern says what kind of match it was:** stitches where you ran outdoors, hoops for stints indoors, pinstripe when nothing was located. A stitch is never finer than 3 pt. No pattern under text stronger than the pinstripe, and none with Increase Contrast on.
- **Names are wide** (SF Pro Expanded heavy). **Numbers are narrow** (Compressed heavy for heroes, Condensed in rows). A hero of 44 pt or more is cut once.
- **Ivory** is what's written on cloth. **Copper** means a best, always beside words that say so.
- **Motion is knitting:** a new match weaves in once, and the halves of a kit number slide home. Nothing loops, and nothing moves with Reduce Motion on.
- **On the watch during play** it's the same type and colors on black, with no pattern. Legibility at a glance wins.
- **Keep clear of real clubs and brands:** never three parallel stripes, crests or shields, red-and-white checks, or presets named after a club.

## Rules

1. **One hero per screen**, answering that moment's question. Everything else is visibly secondary.
2. **Big and few.** Three numbers beat nine. Body text is `.body`; nothing a player reads is smaller than `.footnote`. Targets are 44 pt or larger.
3. **Text styles only** (`.largeTitle`, `.title2`, `.headline`, `.body`, `.subheadline`, `.footnote`) so Dynamic Type works; `ViewThatFits` or a stack at accessibility sizes. Kit numerals are the one exception: they scale with `ScaledMetric` and shrink before they wrap.
4. **Sentence case.** No all-caps, no letter-spacing, no eyebrow labels above headings.
5. **No pills, no chips, no cards inside cards, no tinted tiles with hairline strokes.** Choices are a segmented `Picker`, a `Menu`, or a `List`. Groups are whitespace or an inset-grouped `List`/`Form`.
6. **Color has three jobs:** the kit's color is you and your team; red is the opponent and destructive (a red team's opponent is blue); rose is heart rate. Copper marks a best. Everything else is primary/secondary label. Color never carries meaning alone.
7. **System materials and bars.** Let navigation bars, tab bars and scroll edges be the system's (Liquid Glass on iOS 26). No custom glass, glows, gradient text or shadows on text.
8. **Plain words.** "Effort: strong", not "Composite workrate score". Never show a confidence percentage, an enum name, or pipeline vocabulary (trained, inferred, observations).
9. **Say what's true.** A number has one definition and one value everywhere. Unknown is "—" or absent, never 0. Failure is not absence: say what failed and offer Try Again.
10. **Units follow the region** through `UnitSystem` in MatchTrackerKit: miles, mph, yards / kilometers, km/h, meters.
11. **Every picture speaks.** Pitches and charts carry one generated sentence for VoiceOver.
12. **Destructive things confirm or undo.** Motion respects Reduce Motion. Haptics via `.sensoryFeedback`.
