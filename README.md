# MatchTracker iOS + watchOS

MatchTracker records soccer matches on Apple Watch (GPS route + heart rate + events) and
analyzes them on iPhone (heatmaps, runs, workrate, position), with optional backend upload
for team-level aggregation. See `docs/ARCHITECTURE.md` for the binding design contract.

## Structure

```
MatchTracker.xcodeproj          # Xcode 16 project (objectVersion 77, synchronized groups)
MatchTrackerKit/                # local Swift package: value types + analytics + APIClient
  Sources/MatchTrackerKit/
  Tests/MatchTrackerKitTests/
iOS App/                        # SwiftUI iOS app target "MatchTracker"
Watch App/                      # SwiftUI watchOS app target "MatchTracker Watch App" (embedded)
docs/
```

- iOS bundle id: `com.nicemohawk.MatchTracker` (iOS 17+). Watch: `com.nicemohawk.MatchTracker.watchkitapp` (watchOS 10+).
- The watch app is embedded in the iOS app. Both link the local `MatchTrackerKit` package.
- `iOS App/` and `Watch App/` are filesystem-synchronized groups: new source files are picked
  up automatically without editing `project.pbxproj`.
- No third-party dependencies (URLSession async/await; Alamofire/Locksmith removed).

## Build & test

```bash
# Kit unit tests (pure Swift, runs on macOS)
cd MatchTrackerKit && swift test

# iOS app (embeds the watch app)
xcodebuild -project MatchTracker.xcodeproj -scheme "MatchTracker" \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# watchOS app
xcodebuild -project MatchTracker.xcodeproj -scheme "MatchTracker Watch App" \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Then open `MatchTracker.xcodeproj` in Xcode to run on a simulator or device.

## Todo

- Replace MatchTrackerKit algorithm stubs with real implementations (geometry fit, run
  detection, workrate/position analytics, heatmap binning).
- Watch match-recording flow (HKWorkoutSession + route/events) and iOS analysis screens.
- Backend upload wiring (fields + sessions) and team stats.
- Make use of CLLocation course + speed; store weather metadata on the workout.
