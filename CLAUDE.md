# ParkTrack

## Testing

`xcodebuild test -project ParkTrack.xcodeproj -scheme ParkTrack -destination 'platform=iOS Simulator,name=iPhone 17'` runs the default `Unit` plan — entirely offline and well under a minute, so it is the everyday check. Adding `-testPlan Full` also runs the screen tour, which launches the real app and so spends MapKit searches against a rate limit shared with your own phone; run it only when a change needs a screenshot to confirm, and never in a loop.

Build freely with `xcodebuild build` to catch compile errors; save the test run for the end of a task rather than repeating it at checkpoints.

**Say so before starting anything slow.** Before the test suite, or any stretch of work over about a minute, state that it is coming and whether the code currently builds and is worth deploying. The phone gets redeployed and tested by hand while the slow thing runs, so an unannounced long operation is dead time for both of us.

**After adding test methods, run a clean test build.** An incremental build silently omits newly added test methods — the run reports success having never executed them. `xcodebuild clean` first, or check that the executed count actually went up.

## Project file

`ParkTrack.xcodeproj` is generated — edit `project.yml` and run `xcodegen generate`, including after adding a source file.
