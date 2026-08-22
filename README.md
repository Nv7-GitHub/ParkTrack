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

### Turning CloudKit on

`CloudKitAvailability` reads the embedded provisioning profile for
`com.apple.developer.icloud-container-identifiers` and falls back to the mock backend when it
finds nothing, so the entitlement is what decides whether friends are real. Settings → About
reports which of the three states the running build is in.

The repository side is done: `ParkTrack/ParkTrack.entitlements` requests
`iCloud.$(PARKTRACK_BUNDLE_ID)`, `project.yml` applies it, and `EntitlementsTests` fails if
either goes missing. What remains can only be done in Apple's web consoles:

1. **Certificates, Identifiers & Profiles → Identifiers → your App ID → iCloud.** Enable the
   capability, then create a container named `iCloud.` followed by the bundle id exactly —
   whatever `PARKTRACK_BUNDLE_ID` is set to in `Config/Signing.local.xcconfig`. The name has
   to match what the entitlement expands to or the build fails to provision.
2. **Xcode → Settings → Accounts → Download Manual Profiles**, or just build once, so the new
   entitlement lands in the profile. A device build warns if it did not.
3. **Run a debug build and use the feature once** — add a friend, publish. Saving a record in
   the *Development* environment is what creates the `Profile` and `FriendVisit` record types;
   there is no way to declare them from here.
4. **CloudKit Console → Schema → Indexes.** Add QUERYABLE on `FriendVisit.code` and SORTABLE
   on `FriendVisit.date`. `fetchVisits` queries and sorts on exactly those, and auto-generated
   schema does not include them, so the feed fails without this.
5. **CloudKit Console → Deploy Schema to Production.** Steps 3 and 4 all happen in
   *Development*; TestFlight and the App Store run against *Production*, where none of it
   exists until deployed. Skipping this is the classic failure: everything works in Xcode and
   every friends call fails on TestFlight.

Steps 4 and 5 are the two that cannot be caught before upload, so do them before the first
build goes out rather than after a tester reports empty friends.

### Changing signing team

Changing `DEVELOPMENT_TEAM` while keeping the bundle id still orphans the app's data: the
signed identity is `TEAMID.bundleid`, so iOS refuses to upgrade in place and the app has to be
deleted first, taking its container. Take a backup before switching, or copy the whole
container with Xcode's Devices and Simulators window (Download Container, then Replace
Container once the new build is installed) — that route is bit-for-bit and includes media.

## Backup

Settings writes a `.parktrackbackup` file: a length-prefixed container holding a JSON manifest
plus every photo and video as raw bytes. See `BackupArchive` for the layout and why it is
neither a zip nor an `AppleArchive`. It carries parks, visits, media, struck-off places,
scanned areas, region indexes, saved places, preferences, and friends' codes — everything
except friends' own feeds, which re-pull from CloudKit. Import merges on identities that
survive the trip between installs, so re-importing the same file changes nothing.
