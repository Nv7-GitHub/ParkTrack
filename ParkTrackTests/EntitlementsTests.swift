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

/// The claim the About screen makes about syncing has to match what the build can do.
final class CloudSyncClaimTests: XCTestCase {

    /// `ModelConfiguration(cloudKitDatabase: .automatic)` reports success whether or not the
    /// app is entitled — the mirroring delegate finds out later, on another queue. So the
    /// flag has to be gated on the entitlement, or every simulator and every unsigned build
    /// tells the user their photos are backed up when they are not.
    ///
    /// Runs on the simulator, where there is no provisioning profile and the entitlement
    /// therefore reads false, so it exercises exactly the case that used to lie.
    func testSyncIsOnlyClaimedWhenTheBuildIsEntitled() {
        _ = PersistenceController.makeContainer()

        XCTAssertEqual(
            PersistenceController.isCloudSyncActive,
            CloudKitAvailability.hasICloudEntitlement,
            "the store claimed CloudKit mirroring that the build's entitlements cannot support"
        )
    }
}
