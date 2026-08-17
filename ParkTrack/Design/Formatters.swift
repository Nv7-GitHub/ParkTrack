import Foundation
import CoreLocation

/// Shared formatting so distances, dates and counts read the same everywhere.
enum Format {
    static let metersPerMile: Double = 1609.344

    /// Distance in the user's preferred units, short form (e.g. "1.4 mi", "320 ft").
    static func distance(_ meters: CLLocationDistance) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = meters < metersPerMile ? 0 : 1
        return formatter.string(from: measurement)
    }

    /// "2.5 mi" style label for a radius the user picked.
    static func miles(_ miles: Double) -> String {
        let measurement = Measurement(value: miles, unit: UnitLength.miles)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = miles < 10 ? 1 : 0
        return formatter.string(from: measurement)
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
