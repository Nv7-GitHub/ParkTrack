# ParkTrack

## Testing

`xcodebuild test -project ParkTrack.xcodeproj -scheme ParkTrack -destination 'platform=iOS Simulator,name=iPhone 17'` runs the default `Unit` test plan — the everyday check, well under a minute. Add `-testPlan Full` to also run the screen tour, which launches the app repeatedly and lets a real map sweep run (minutes), and only run it when a change needs a screenshot to confirm.

## Project file

`ParkTrack.xcodeproj` is generated — edit `project.yml` and run `xcodegen generate`, including after adding a source file.
