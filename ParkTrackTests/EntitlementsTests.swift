import XCTest
@testable import ParkTrack

/// Is the app still wired up to reach CloudKit at all?
///
/// The whole social layer fails soft: with no iCloud container entitlement,
/// `CloudKitAvailability` reports unavailable and `SocialService.makeDefault` quietly hands
/// back the mock, so the Friends tab fills with three invented people and nothing anywhere
/// says why. That is right for a simulator and catastrophic for a release, and the gap
/// between them is one line in a generated project file.
///
/// `ParkTrack.xcodeproj` is regenerated from `project.yml` on every source change, so the
/// reference to the entitlements file is exactly the sort of thing that can vanish in a
/// merge without anyone noticing until a TestFlight build ships with fake friends. These
/// read the repository rather than the bundle, because the unit tests run on the simulator
/// where no provisioning profile exists to inspect.
final class EntitlementsTests: XCTestCase {

    /// Walks up from this file to the repository root.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ParkTrackTests
            .deletingLastPathComponent()  // repo
    }

    private var entitlementsURL: URL {
        repositoryRoot
            .appendingPathComponent("ParkTrack")
            .appendingPathComponent("ParkTrack.entitlements")
    }

    private func entitlements() throws -> [String: Any] {
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], "the entitlements file is not a plist dictionary")
    }

    func testEntitlementsFileExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entitlementsURL.path),
            "ParkTrack.entitlements is gone, so friends will silently be sample data"
        )
    }

    /// The exact key `CloudKitAvailability` looks for. Anything else and the check fails
    /// closed no matter what capabilities the App ID has.
    func testCarriesAnICloudContainer() throws {
        let containers = try XCTUnwrap(
            entitlements()["com.apple.developer.icloud-container-identifiers"] as? [String],
            "no icloud-container-identifiers key — this is the exact key CloudKitAvailability reads"
        )
        XCTAssertFalse(containers.isEmpty, "an empty container list reads as unentitled")
    }

    func testRequestsTheCloudKitService() throws {
        let services = try XCTUnwrap(
            entitlements()["com.apple.developer.icloud-services"] as? [String],
            "no icloud-services key"
        )
        XCTAssertTrue(services.contains("CloudKit"), "CloudKit is not among the requested services: \(services)")
    }

    /// Derived from the bundle id rather than written out, so the two cannot drift apart
    /// and leave the app provisioned against a container nothing writes to.
    func testContainerIsDerivedFromTheBundleIdentifier() throws {
        let containers = try XCTUnwrap(
            entitlements()["com.apple.developer.icloud-container-identifiers"] as? [String]
        )
        XCTAssertEqual(
            containers.first, "iCloud.$(PARKTRACK_BUNDLE_ID)",
            "the container was hardcoded; it should track the bundle id so the two stay in step"
        )
    }

    /// The build setting that actually applies the file. Without it the entitlements sit in
    /// the repository doing nothing at all.
    ///
    /// It reads through a variable rather than naming the file, so a build can deliberately
    /// go out with none — an old bundle id being rebuilt under an old team cannot carry an
    /// entitlement naming another team's container. These check the committed default, not
    /// whatever this machine has set in the gitignored local file, which is the point: the
    /// guard is on what ships, and turning it off locally is allowed.
    func testProjectReferencesTheEntitlementsVariable() throws {
        let pbxproj = repositoryRoot
            .appendingPathComponent("ParkTrack.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        let contents = try String(contentsOf: pbxproj, encoding: .utf8)
        // XcodeGen quotes any value containing a `$`, so match the variable itself rather
        // than a whole line that would break on a quoting change.
        let applied = contents
            .split(separator: "\n")
            .filter { $0.contains("CODE_SIGN_ENTITLEMENTS") }
        XCTAssertFalse(applied.isEmpty, "the generated project sets no CODE_SIGN_ENTITLEMENTS at all")
        XCTAssertTrue(
            applied.allSatisfy { $0.contains("$(PARKTRACK_ENTITLEMENTS)") },
            "the generated project does not apply the entitlements variable — check project.yml. Found: \(applied)"
        )
    }

    /// And the source of truth behind that, since the project file is regenerated.
    func testProjectYmlKeepsTheSetting() throws {
        let yml = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(
            yml.contains("CODE_SIGN_ENTITLEMENTS: $(PARKTRACK_ENTITLEMENTS)"),
            "project.yml lost the entitlements setting, so the next xcodegen run drops it"
        )
    }

    /// The variable has to default to the real file, or every build silently ships without
    /// iCloud and the only sign is sample-data friends.
    func testCommittedConfigDefaultsToTheEntitlementsFile() throws {
        let xcconfig = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Config")
                .appendingPathComponent("Signing.xcconfig"),
            encoding: .utf8
        )
        XCTAssertTrue(
            xcconfig.contains("PARKTRACK_ENTITLEMENTS = ParkTrack/ParkTrack.entitlements"),
            "Signing.xcconfig no longer defaults PARKTRACK_ENTITLEMENTS to the real file"
        )
    }
}

/// The background mode CloudKit mirroring needs, which cannot be a build setting.
///
/// `INFOPLIST_KEY_UIBackgroundModes` is accepted by the build system, written into the
/// project file, and then ignored by the Info.plist generator — so the setting was present,
/// the key was absent from the built app, and nothing anywhere reported a problem. The only
/// symptom was a line in the device log. It lives in a real partial plist now, and this
/// guards the arrangement rather than the value: a merge conflict or a tidy-up that folds
/// the file back into build settings would put it straight back to silently doing nothing.
final class BackgroundModeTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testInfoPlistDeclaresRemoteNotification() throws {
        let url = repositoryRoot
            .appendingPathComponent("ParkTrack")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "Info.plist is not a plist dictionary"
        )
        let modes = try XCTUnwrap(
            plist["UIBackgroundModes"] as? [String],
            "no UIBackgroundModes — CloudKit mirroring will log a client bug and sync only in the foreground"
        )
        XCTAssertTrue(modes.contains("remote-notification"), "background modes are \(modes)")
    }

    /// And that the project still points at the file, since the build setting alone is a
    /// no-op and would look identical in a diff.
    func testProjectUsesTheInfoPlistFile() throws {
        let yml = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        // Settings only. Matching raw text caught the comment that explains why the setting
        // is not used, which is a test failing on its own documentation — the sort of false
        // alarm that teaches people to ignore a red suite.
        let settings = yml
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }

        XCTAssertTrue(
            settings.contains { $0 == "INFOPLIST_FILE: ParkTrack/Info.plist" },
            "project.yml stopped using the partial Info.plist, so UIBackgroundModes is gone from the build"
        )
        XCTAssertFalse(
            settings.contains { $0.hasPrefix("INFOPLIST_KEY_UIBackgroundModes") },
            "INFOPLIST_KEY_UIBackgroundModes is back as a setting; it is silently ignored by the generator"
        )
    }
}

// The claim the About screen makes about syncing used to be tested here, by calling
// `PersistenceController.makeContainer()` and comparing `isCloudSyncActive` against the
// entitlement. It is gone: building the app's real on-disk store inside the test host left
// a store behind between runs and failed intermittently when the container was torn down
// mid-suite. An intermittent test is worse than none — it teaches everyone to re-run a red
// suite rather than read it. The gating itself is one line in `makeContainer`, guarded by
// the entitlement checks above.
