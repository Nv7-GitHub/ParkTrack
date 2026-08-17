# ParkTrack
Track the local parks you've been to!

## Building

Simulator builds work straight from a clone, with no signing setup:

```
xcodegen generate
xcodebuild -project ParkTrack.xcodeproj -scheme ParkTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
```

To build onto a phone, create `Config/Signing.local.xcconfig` (gitignored) with this
machine's two values:

```
DEVELOPMENT_TEAM = ABCDE12345
PARKTRACK_BUNDLE_ID = com.yourprefix.parktrack.app
```

The committed `Config/Signing.xcconfig` holds only a placeholder, so nobody's team id or
bundle id ends up in a diff reassigning someone else's. A device build on the placeholder
fails on purpose rather than installing a second, empty ParkTrack beside the real one —
the bundle id owns the app's data, and the iCloud records behind friends once CloudKit is
enabled. Keep it stable.

iCloud sync and the friends features need a paid Apple Developer Program membership; without
one the app runs fully on local storage and the Friends tab shows sample data, labelled as
such.
