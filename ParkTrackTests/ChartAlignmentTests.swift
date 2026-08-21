import XCTest
import SwiftUI
@testable import ParkTrack

/// Does each bar stand under its own label?
///
/// This is checked by rendering the chart and measuring the picture, because it cannot be
/// checked any other way: where Swift Charts puts a mark and where it puts an axis label are
/// both decided inside the framework, and the two disagreed for months. An `AxisValueLabel`
/// built from a custom view hangs it off the *leading* edge of the tick rather than centring
/// it, so every month name sat about half its own width to the right of the bar it named —
/// a bug that is glaring on screen and completely invisible to a test of the data.
@MainActor
final class ChartAlignmentTests: XCTestCase {

    /// A correctly placed bar lands within a pixel or two of its label, and the misplacement
    /// this exists to catch was tens of pixels. Eight leaves room for the slop in measuring
    /// where a word "is" — a glyph's inked box is not quite centred on the box it was laid
    /// out in — without leaving room for the bug.
    private let toleranceInPixels = 8.0
    private let scale = 3.0

    // MARK: The picture

    private func render<Content: View>(_ content: Content, width: CGFloat) throws -> Image8 {
        let renderer = ImageRenderer(content: content.frame(width: width).background(Color.white))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.uiImage, "the chart drew nothing at all")
        return try Image8(image)
    }

    // MARK: Tests

    func testEveryTimelineBarStandsUnderItsOwnLabel() throws {
        let calendar = Calendar.current
        let thisMonth = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.start)
        // Two months apart and nowhere near the edges, so which bar is which is unambiguous.
        let counts = [0, 3, 0, 0, 7, 0]
        var running = 4
        let data: [TimelinePoint] = counts.indices.map { offset in
            let month = calendar.date(byAdding: .month, value: -(counts.count - 1 - offset), to: thisMonth)!
            running += counts[offset]
            return TimelinePoint(date: month, count: counts[offset], cumulative: running)
        }

        let picture = try render(
            TimelineChart(data: data, monthsBack: counts.count).frame(height: 210),
            width: 340
        )

        let bars = picture.columnRuns(matching: .bar, inRowFraction: 0.80).filter { $0.width > 8 }
        XCTAssertEqual(bars.count, 2, "expected one bar per month with visits")

        let labels = picture.columnRuns(matching: .text, inRowsBelow: 0.88, joiningWithin: 14)
        XCTAssertGreaterThanOrEqual(labels.count, 6, "expected a label for each of the six months")

        var claimed: Set<Double> = []
        for bar in bars {
            let nearest = try XCTUnwrap(
                labels.min { abs($0.centre - bar.centre) < abs($1.centre - bar.centre) },
                "no axis labels were drawn"
            )
            XCTAssertEqual(
                bar.centre,
                nearest.centre,
                accuracy: toleranceInPixels,
                "a bar is \(Int((nearest.centre - bar.centre).rounded())) pixels from the label beneath it"
            )
            claimed.insert(nearest.centre)
        }
        XCTAssertEqual(claimed.count, bars.count, "two bars pointed at the same label")
    }

    func testEveryRhythmBarStandsUnderItsOwnLabel() throws {
        let counts = [2, 0, 5, 1, 0, 9, 3, 0, 0, 6, 0, 1]
        let buckets = StatsBreakdown.byMonthOfYear(parks: []).enumerated().map { index, bucket in
            StatsBucket(
                id: bucket.id,
                shortLabel: bucket.shortLabel,
                fullLabel: bucket.fullLabel,
                count: counts[index]
            )
        }

        let picture = try render(
            StatsBucketChart(
                title: "By month of year",
                buckets: buckets,
                tint: Theme.chartColors[2],
                emptyMessage: ""
            ),
            width: 340
        )

        // Bars first, because a `.ratio` width on a continuous scale draws every one of them
        // with no width at all — which is what this chart used to do.
        let bars = picture.columnRuns(matching: .warmBar, inRowFraction: 0.86).filter { $0.width > 8 }
        XCTAssertEqual(bars.count, counts.filter { $0 > 0 }.count, "a bar is missing or has no width")

        let labels = picture.columnRuns(matching: .text, inRowsBelow: 0.92, joiningWithin: 10)
        for bar in bars {
            let nearest = try XCTUnwrap(labels.min { abs($0.centre - bar.centre) < abs($1.centre - bar.centre) })
            XCTAssertEqual(
                bar.centre,
                nearest.centre,
                accuracy: toleranceInPixels,
                "a bar is \(Int((nearest.centre - bar.centre).rounded())) pixels from the label beneath it"
            )
        }
    }
}

// MARK: - Reading a rendered chart

/// Just enough pixel reading to say where things are: runs of columns that match some
/// description, and where each run's middle is.
struct Image8 {
    struct Run {
        let first: Int
        let last: Int
        var centre: Double { Double(first + last) / 2 }
        var width: Int { last - first + 1 }
    }

    enum Ink {
        /// The timeline's bars: distinctly blue.
        case bar
        /// The rhythm charts' bars: distinctly orange.
        case warmBar
        /// Axis labels: any dark, unsaturated mark.
        case text

        func matches(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
            switch self {
            case .bar: return blue > red + 40 && blue > 100
            case .warmBar: return red > blue + 40 && red > 120
            case .text: return red < 170 && green < 170 && blue < 170
            }
        }
    }

    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage, "the render had no bitmap")
        width = cgImage.width
        height = cgImage.height
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
        pixels = buffer
    }

    private func colour(x: Int, y: Int) -> (Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    /// Runs of columns matching `ink` along a single row.
    func columnRuns(matching ink: Ink, inRowFraction fraction: Double, joiningWithin gap: Int = 2) -> [Run] {
        let y = min(height - 1, max(0, Int(Double(height) * fraction)))
        return runs(of: (0..<width).filter { x in
            let (r, g, b) = colour(x: x, y: y)
            return ink.matches(r, g, b)
        }, joiningWithin: gap)
    }

    /// Runs of columns matching `ink` anywhere in the band below `fraction` of the height.
    func columnRuns(matching ink: Ink, inRowsBelow fraction: Double, joiningWithin gap: Int) -> [Run] {
        let top = min(height - 1, max(0, Int(Double(height) * fraction)))
        return runs(of: (0..<width).filter { x in
            (top..<height).contains { y in
                let (r, g, b) = colour(x: x, y: y)
                return ink.matches(r, g, b)
            }
        }, joiningWithin: gap)
    }

    private func runs(of columns: [Int], joiningWithin gap: Int) -> [Run] {
        var runs: [Run] = []
        for x in columns {
            if let last = runs.last, x - last.last <= gap {
                runs[runs.count - 1] = Run(first: last.first, last: x)
            } else {
                runs.append(Run(first: x, last: x))
            }
        }
        return runs
    }
}
