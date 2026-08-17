# ParkTrack
Track the local parks you've been to!

## Building

Simulator builds work straight from a clone, with no signing setup:

```
xcodegen generate
xcodebuild -project ParkTrack.xcodeproj -scheme ParkTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test CODE_SIGNING_ALLOWED=NO
```

## Testing

That command runs the everyday suite: the `Unit` test plan, a few seconds for the lot and
entirely offline — nothing in it reaches the network.

Two groups are opt-in. Both are minutes rather than seconds, and both spend real
`MKLocalSearch` requests against a rate limit shared with whatever your own phone is doing,
so neither belongs in a loop:

```
# Screenshot tour of every tab. Launches the real app, so it sweeps the map for real.
# For changes only a picture can confirm.
xcodebuild -project ParkTrack.xcodeproj -scheme ParkTrack -testPlan Full \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ParkTrackUITests test

# Probes against the live map service. Its rate limit is shared with your own phone,
# so these come out of someone's pocket — run them when you're investigating the
# service itself, not as a matter of course.
PARKTRACK_LIVE_PROBES=1 xcodebuild -project ParkTrack.xcodeproj -scheme ParkTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ParkTrackTests/LiveMapKitProbeTests test
```

## Signing

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
