import XCTest
import CoreLocation
@testable import ParkTrack

/// Home, school and work are all just places to measure from, and any of them can be
/// absent. These pin down that adding and removing one has the effects the pickers rely on.
@MainActor
final class SavedPlaceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SavedPlaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func settings() -> AppSettings { AppSettings(defaults: defaults) }

    private let redmond = CLLocationCoordinate2D(latitude: 47.674, longitude: -122.121)
    private let seattle = CLLocationCoordinate2D(latitude: 47.606, longitude: -122.332)

    // MARK: - Setting and removing

    func testAPlaceIsAbsentUntilItIsSet() {
        let settings = settings()
        for kind in SavedPlaceKind.allCases {
            XCTAssertNil(settings.coordinate(for: kind))
        }
        XCTAssertTrue(settings.savedPlaces.isEmpty)
    }

    func testSettingAPlaceMakesItAvailable() throws {
        let settings = settings()
        settings.setCoordinate(redmond, for: .school)

        XCTAssertEqual(try XCTUnwrap(settings.coordinate(for: .school)).latitude, redmond.latitude, accuracy: 1e-9)
        XCTAssertEqual(settings.savedPlaces, [.school])
    }

    /// Removing is what makes a segment disappear, so it has to leave nothing behind.
    func testRemovingAPlaceTakesItsLabelWithIt() {
        let settings = settings()
        settings.setCoordinate(redmond, for: .work)
        settings.setLabel("The office", for: .work)
        XCTAssertEqual(settings.label(for: .work), "The office")

        settings.setCoordinate(nil, for: .work)

        XCTAssertNil(settings.coordinate(for: .work))
        XCTAssertFalse(settings.savedPlaces.contains(.work))
        XCTAssertEqual(settings.label(for: .work), "Work", "A removed place falls back to its own name")
    }

    /// A picker that reshuffled itself as places were added would be unusable.
    func testSavedPlacesKeepAFixedOrder() {
        let settings = settings()
        settings.setCoordinate(redmond, for: .work)
        settings.setCoordinate(seattle, for: .home)
        settings.setCoordinate(redmond, for: .school)

        XCTAssertEqual(settings.savedPlaces, [.home, .school, .work])
    }

    func testAPlaceSurvivesARelaunch() throws {
        let first = settings()
        first.setCoordinate(redmond, for: .school)
        first.setLabel("Campus", for: .school)

        let second = settings()
        XCTAssertEqual(try XCTUnwrap(second.coordinate(for: .school)).longitude, redmond.longitude, accuracy: 1e-9)
        XCTAssertEqual(second.label(for: .school), "Campus")
    }

    func testAnInvalidCoordinateIsTreatedAsUnset() {
        let settings = settings()
        settings.setCoordinate(CLLocationCoordinate2D(latitude: 200, longitude: 400), for: .home)
        XCTAssertNil(settings.coordinate(for: .home))
    }

    // MARK: - Home keeps working

    func testHomeIsJustAPlace() throws {
        let settings = settings()
        settings.homeCoordinate = seattle

        XCTAssertEqual(try XCTUnwrap(settings.coordinate(for: .home)).latitude, seattle.latitude, accuracy: 1e-9)
        XCTAssertEqual(settings.savedPlaces, [.home])

        settings.homeCoordinate = nil
        XCTAssertTrue(settings.savedPlaces.isEmpty)
    }

    /// A home saved before places existed lives under its own two keys. Dropping it would
    /// silently recentre every ring in the app.
    func testAHomeSavedByAnEarlierVersionIsCarriedOver() throws {
        defaults.set(seattle.latitude, forKey: "settings.home.latitude")
        defaults.set(seattle.longitude, forKey: "settings.home.longitude")
        defaults.set("My flat", forKey: "settings.home.label")

        let settings = settings()
        XCTAssertEqual(try XCTUnwrap(settings.homeCoordinate).latitude, seattle.latitude, accuracy: 1e-9)
        XCTAssertEqual(settings.homeLabel, "My flat")
        XCTAssertEqual(settings.savedPlaces, [.home])
    }

    /// …but only when there is nothing newer, or removing home would undo itself on the
    /// next launch.
    func testRemovingHomeIsNotUndoneByTheLegacyKeys() {
        defaults.set(seattle.latitude, forKey: "settings.home.latitude")
        defaults.set(seattle.longitude, forKey: "settings.home.longitude")

        let first = settings()
        XCTAssertNotNil(first.homeCoordinate)
        first.setCoordinate(redmond, for: .school)
        first.homeCoordinate = nil

        let second = settings()
        XCTAssertNil(second.homeCoordinate, "Home stayed removed")
        XCTAssertEqual(second.savedPlaces, [.school])
    }

    // MARK: - What the picker offers

    func testTheAnchorPickerOffersOnlyPlacesThatExist() {
        let settings = settings()
        XCTAssertEqual(StatsAnchor.available(in: settings), [.currentLocation, .pin])

        settings.setCoordinate(redmond, for: .school)
        XCTAssertEqual(StatsAnchor.available(in: settings), [.currentLocation, .place(.school), .pin])

        settings.setCoordinate(seattle, for: .home)
        XCTAssertEqual(
            StatsAnchor.available(in: settings),
            [.currentLocation, .place(.home), .place(.school), .pin]
        )

        settings.setCoordinate(nil, for: .school)
        XCTAssertEqual(StatsAnchor.available(in: settings), [.currentLocation, .place(.home), .pin])
    }

    func testAnAnchorIsNamedByItsPlacesLabel() {
        let settings = settings()
        settings.setCoordinate(redmond, for: .work)
        settings.setLabel("The office", for: .work)

        XCTAssertEqual(StatsAnchor.place(.work).title(in: settings), "The office")
        XCTAssertEqual(StatsAnchor.place(.work).sheetLabel(in: settings), "the office")
    }

    /// Anchors are compared and used as a `task` id, so two of them must never collide.
    func testEveryAnchorHasItsOwnIdentity() {
        let all: [StatsAnchor] = [.currentLocation, .pin] + SavedPlaceKind.allCases.map(StatsAnchor.place)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertNotEqual(StatsAnchor.place(.home), StatsAnchor.place(.work))
    }
}
