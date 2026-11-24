# MatchTracker design

Platform: iOS 17+ and watchOS 10+ (newer features behind availability checks; never raise the minimum).
Native first: if Apple ships a control for it, use that control.

## Who and when

- **Walking off the pitch** — tired, outdoors, one hand. "How did we do, how did I do, is it saved?" One screen, no interaction.
- **On the couch that night** — "Show me the good bit. Was I any good?" Scrub, replay, share.
- **Between matches** — "Am I getting better? Who's next?" The season.
- **During play (watch)** — a half-second glance. Nothing to tap. Tapping happens on the bench and at stoppages.

## Rules

1. **One hero per screen**, answering that moment's question. Everything else is visibly secondary.
2. **Big and few.** Three numbers beat nine. Body text is `.body`; nothing a player reads is smaller than `.footnote`. Targets are 44 pt or larger.
3. **Text styles only** (`.largeTitle`, `.title2`, `.headline`, `.body`, `.subheadline`, `.footnote`) so Dynamic Type works; `ViewThatFits` or a stack at accessibility sizes. SF Rounded is for numerals only.
4. **Sentence case.** No all-caps, no letter-spacing, no eyebrow labels above headings.
5. **No pills, no chips, no cards inside cards, no tinted tiles with hairline strokes.** Choices are a segmented `Picker`, a `Menu`, or a `List`. Groups are whitespace or an inset-grouped `List`/`Form`.
6. **Color has three jobs:** green is you and your team; red is the opponent and destructive; rose is heart rate. Everything else is primary/secondary label. Color never carries meaning alone.
7. **System materials and bars.** Let navigation bars, tab bars and scroll edges be the system's (Liquid Glass on iOS 26). No custom glass, glows, gradient text or shadows on text.
8. **Plain words.** "Effort: strong", not "Composite workrate score". Never show a confidence percentage, an enum name, or pipeline vocabulary (trained, inferred, observations).
9. **Say what's true.** A number has one definition and one value everywhere. Unknown is "—" or absent, never 0. Failure is not absence: say what failed and offer Try Again.
10. **Units follow the region** through `UnitSystem` in MatchTrackerKit: miles, mph, yards / kilometers, km/h, meters.
11. **Every picture speaks.** Pitches and charts carry one generated sentence for VoiceOver.
12. **Destructive things confirm or undo.** Motion respects Reduce Motion. Haptics via `.sensoryFeedback`.
