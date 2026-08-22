import XCTest
import SwiftUI
import SwiftData
import CoreLocation
@testable import ParkTrack

/// Does the adoption screen actually show the warning it promises?
///
/// Checked by rendering and measuring the picture, because the property that matters is a
/// visual one. "The model says `wouldDeleteVisits`" is a different claim from "a person
/// looking at this screen can see that pressing the button destroys their photos", and only
/// the second one protects anybody. A row whose warning is laid out off-screen, clipped to
/// zero height, or drawn in the body colour would pass every logic test in
/// `ExclusionSharingTests` and still be the bug.
///
/// The assertion is differential rather than absolute: the same screen is rendered with and
/// without a visited park, and the warning colour must appear in one and not the other. That
/// survives theme tweaks and layout changes in a way a fixed pixel count would not.
@MainActor
final class AdoptExclusionsRenderTests: XCTestCase {

    // MARK: - Fixtures

    @discardableResult
    private func makePark(_ name: String, lat: Double, lon: Double, visited: Bool, in context: ModelContext) -> Park {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let park = Park(
            identifier: Park.identity(name: name, coordinate: coordinate),
            name: name,
            latitude: lat,
            longitude: lon
        )
        context.insert(park)
        if visited {
            let visit = Visit(date: Date(), park: park)
            context.insert(visit)
            let photo = MediaItem(data: Data(repeating: 9, count: 64), isVideo: false)
            photo.visit = visit
            context.insert(photo)
        }
        return park
    }

    private func makeFriend(excluding parks: [Park], in context: ModelContext) -> Friend {
        let friend = Friend(friendCode: "ABC234", displayName: "Sam")
        context.insert(friend)
        for park in parks {
            let exclusion = FriendExclusion(
                identifier: park.identifier,
                name: park.name,
                latitude: park.latitude,
                longitude: park.longitude
            )
            exclusion.friend = friend
            context.insert(exclusion)
        }
        return friend
    }

    // MARK: - Rendering

    /// Builds the row the sheet would build, then photographs it.
    ///
    /// The row rather than the whole sheet: `ImageRenderer` cannot draw a `NavigationStack`
    /// with toolbars and silently substitutes a yellow-and-red placeholder, which would make
    /// any measurement of the full screen meaningless rather than merely wrong.
    private func renderRow(visited: Bool, selected: Bool = false) throws -> WarningPicture {
        // A store per render. Two renders sharing one would stack a second identical park
        // and a second friend on top of the first, and the pictures would stop differing
        // for reasons that have nothing to do with the row.
        let container = PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)

        let park = makePark("Riverside Parcel", lat: 47.6, lon: -122.3, visited: visited, in: context)
        let friend = makeFriend(excluding: [park], in: context)
        try context.save()

        let rows = AdoptableExclusion.list(
            from: friend.exclusions ?? [],
            parks: try context.fetch(FetchDescriptor<Park>()),
            alreadyExcluded: []
        )
        let row = try XCTUnwrap(rows.first, "no adoptable row was produced")

        let view = Card {
            AdoptExclusionRow(row: row, isSelected: selected, onToggle: {}, onOpen: {})
        }
        .frame(width: 358)
        .padding(16)
        .background(Theme.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "the row drew nothing at all")
        return try WarningPicture(image)
    }

    // MARK: - Tests

    /// A row that would destroy visits and photos must be visibly marked as such.
    func testWarningIsVisibleForAVisitedPark() throws {
        let picture = try renderRow(visited: true)
        XCTAssertGreaterThan(
            picture.warningPixels, 200,
            "a row that would delete a visit and a photo drew no visible warning"
        )
    }

    /// And a row with nothing to lose must not cry wolf.
    func testNoWarningWhenNothingWouldBeLost() throws {
        let picture = try renderRow(visited: false)
        XCTAssertLessThan(
            picture.warningPixels, 200,
            "a harmless row drew a warning, which trains people to ignore the real ones"
        )
    }

    /// The warning has to be a meaningful part of the row, not a stray anti-aliased pixel.
    func testWarningIsSubstantial() throws {
        let harmless = try renderRow(visited: false)
        let dangerous = try renderRow(visited: true)
        XCTAssertGreaterThan(
            dangerous.warningPixels, harmless.warningPixels + 400,
            "the destructive row barely differs from the harmless one"
        )
        XCTAssertGreaterThan(dangerous.inkedPixels, harmless.inkedPixels,
                             "the warning line added no visible height to the row")
    }

    /// The row must draw its content rather than collapsing to nothing.
    func testRowIsActuallyDrawn() throws {
        let picture = try renderRow(visited: false)
        XCTAssertGreaterThan(picture.inkedPixels, 2_000, "the row rendered essentially blank")
        XCTAssertLessThan(
            picture.warningPixels, picture.inkedPixels,
            "the renderer produced its unsupported-view placeholder rather than the row"
        )
    }
}

/// Counts pixels of the warning colour, and of ink generally.
private struct WarningPicture {
    let warningPixels: Int
    let inkedPixels: Int

    init(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage, "the render had no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var warning = 0
        var inked = 0
        for offset in stride(from: 0, to: buffer.count, by: 4) {
            let red = Int(buffer[offset])
            let green = Int(buffer[offset + 1])
            let blue = Int(buffer[offset + 2])
            let alpha = Int(buffer[offset + 3])
            guard alpha > 40 else { continue }

            // Theme.sunset is a warm orange in both appearances; nothing else on this screen
            // is, so a red-dominant pixel is the warning label or its triangle.
            if red > 140, red > blue + 55, green < red - 30 { warning += 1 }
            // Anything appreciably darker or more saturated than the page background.
            if red < 200 || green < 200 || blue < 200 { inked += 1 }
        }
        warningPixels = warning
        inkedPixels = inked
    }
}
