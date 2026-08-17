# ParkTrack

## Testing

`xcodebuild test -project ParkTrack.xcodeproj -scheme ParkTrack -destination 'platform=iOS Simulator,name=iPhone 17'` runs the default `Unit` plan — entirely offline and well under a minute, so it is the everyday check. Adding `-testPlan Full` also runs the screen tour, which launches the real app and so spends MapKit searches against a rate limit shared with your own phone; run it only when a change needs a screenshot to confirm, and never in a loop.

## Project file

`ParkTrack.xcodeproj` is generated — edit `project.yml` and run `xcodegen generate`, including after adding a source file.
