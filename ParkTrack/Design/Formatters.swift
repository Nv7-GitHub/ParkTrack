import Foundation
import CoreLocation

/// Shared formatting so distances, dates and counts read the same everywhere.
///
/// The formatters are built once and reused. `MeasurementFormatter` and
/// `RelativeDateTimeFormatter` are among the most expensive objects in Foundation to
/// create — each one resolves the locale, builds a number formatter and consults the
/// unit tables — and these functions are called per list row, per map label, per stat
/// tile, on every SwiftUI body evaluation. Allocating one each time was costing more
/// than the entire rest of a row's layout.
///
/// Neither class is thread-safe, so the shared instances are used under a lock. A lock
/// that is almost never contended costs tens of nanoseconds; the allocation it replaces
/// costs tens of microseconds.
enum Format {
    static let metersPerMile: Double = 1609.344

    private static let lock = NSLock()

    /// Formatted strings and the formatters that made them are locale-dependent, so both are
    /// dropped if the user switches region or measurement system while the app is running.
    private nonisolated(unsafe) static let localeObserver: NSObjectProtocol = NotificationCenter.default
        .addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil) { _ in
            lock.lock()
            milesCache.removeAll(keepingCapacity: true)
            distanceCache.removeAll(keepingCapacity: true)
            lock.unlock()
        }

    /// Fraction digits are part of a formatter's configuration rather than of a call, so
    /// each distinct precision gets its own instance instead of being mutated per call.
    private static func makeMeasurementFormatter(
        unitOptions: MeasurementFormatter.UnitOptions,
        fractionDigits: Int
    ) -> MeasurementFormatter {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = unitOptions
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = fractionDigits
        return formatter
    }

    private nonisolated(unsafe) static let naturalWhole = makeMeasurementFormatter(unitOptions: .naturalScale, fractionDigits: 0)
    private nonisolated(unsafe) static let naturalTenths = makeMeasurementFormatter(unitOptions: .naturalScale, fractionDigits: 1)
    private nonisolated(unsafe) static let milesWhole = makeMeasurementFormatter(unitOptions: .providedUnit, fractionDigits: 0)
    private nonisolated(unsafe) static let milesTenths = makeMeasurementFormatter(unitOptions: .providedUnit, fractionDigits: 1)
    private nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Radii come from a short fixed set — the user's rings, the slider's steps — and the
    /// same handful of values are formatted on every frame, so the strings are kept.
    private nonisolated(unsafe) static var milesCache: [Double: String] = [:]
    private static let milesCacheLimit = 256

    private nonisolated(unsafe) static var distanceCache: [Double: String] = [:]
    private static let distanceCacheLimit = 4_096

    /// Distance in the user's preferred units, short form (e.g. "1.4 mi", "320 ft").
    ///
    /// Quantised to the precision the string actually shows before it is looked up, so the
    /// same row asked for on the next frame — or two parks a metre apart — is answered from
    /// the table. `MeasurementFormatter.string` costs on the order of eighty microseconds,
    /// which over a screenful of rows is most of a frame on its own.
    static func distance(_ meters: CLLocationDistance) -> String {
        _ = localeObserver
        guard meters.isFinite else { return "—" }
        let isShort = meters < metersPerMile
        // Under a mile the string has no fraction, so whole metres is finer than it shows;
        // over a mile it shows one decimal, i.e. steps of about 160 m.
        let key = isShort ? meters.rounded() : (meters / 16).rounded() * 16

        lock.lock()
        defer { lock.unlock() }
        if let cached = distanceCache[key] { return cached }
        let text = (isShort ? naturalWhole : naturalTenths)
            .string(from: Measurement(value: key, unit: UnitLength.meters))
        if distanceCache.count >= distanceCacheLimit { distanceCache.removeAll(keepingCapacity: true) }
        distanceCache[key] = text
        return text
    }

    /// "2.5 mi" style label for a radius the user picked.
    static func miles(_ miles: Double) -> String {
        _ = localeObserver
        lock.lock()
        defer { lock.unlock() }
        if let cached = milesCache[miles] { return cached }
        let measurement = Measurement(value: miles, unit: UnitLength.miles)
        let text = (miles < 10 ? milesTenths : milesWhole).string(from: measurement)
        // A guard against an unbounded slider feeding it every value it passes through.
        if milesCache.count >= milesCacheLimit { milesCache.removeAll(keepingCapacity: true) }
        milesCache[miles] = text
        return text
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func relative(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(minutes: Int) -> String {
        let measurement = Measurement(value: Double(minutes), unit: UnitDuration.minutes)
        if minutes >= 60 {
            return measurement.converted(to: .hours)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(0...1))))
        }
        return measurement.formatted(.measurement(width: .abbreviated))
    }

    /// "3 parks" / "1 park"
    static func parkCount(_ count: Int) -> String {
        "\(count) park\(count == 1 ? "" : "s")"
    }
}
