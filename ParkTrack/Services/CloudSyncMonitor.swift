import Foundation
import CoreData
import Observation

/// What iCloud sync is actually doing, as opposed to whether it is switched on.
///
/// "iCloud sync: On" is a statement about entitlements. It says nothing about whether a
/// hundred megabytes of photographs have left the phone, and there is no honest way to guess
/// — the first upload of a full library takes many minutes, and the app looks identical
/// throughout. Somebody who deletes and reinstalls in that window loses whatever had not
/// gone up yet, which is exactly the kind of thing an app should not let happen quietly.
///
/// SwiftData is `NSPersistentCloudKitContainer` underneath, and that posts an event whenever
/// a setup, import or export begins and ends. Listening to those is the only way to know.
@Observable
@MainActor
final class CloudSyncMonitor {
    enum Activity: Equatable {
        case idle
        case settingUp
        /// Sending this device's changes to iCloud.
        case sending
        /// Receiving changes from iCloud.
        case receiving

        var label: String {
            switch self {
            case .idle: "Up to date"
            case .settingUp: "Connecting…"
            case .sending: "Uploading…"
            case .receiving: "Downloading…"
            }
        }
    }

    private(set) var activity: Activity = .idle
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    /// True once anything at all has been heard from CloudKit, so the UI can tell "nothing
    /// has happened yet" apart from "nothing is happening now".
    private(set) var hasHeardFromCloudKit = false

    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.apply(event) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// An event arrives twice: once when the work starts, with no `endDate`, and once when
    /// it finishes. Only the second carries a verdict.
    private func apply(_ event: NSPersistentCloudKitContainer.Event) {
        hasHeardFromCloudKit = true

        guard event.endDate != nil else {
            activity = switch event.type {
            case .setup: .settingUp
            case .import: .receiving
            case .export: .sending
            @unknown default: .settingUp
            }
            return
        }

        activity = .idle
        if let error = event.error {
            lastError = Self.message(for: error)
        } else {
            lastError = nil
            // Setup finishing means a connection, not a transfer, so it is not the thing to
            // date a sync from — otherwise the screen claims everything is safely in iCloud
            // the moment the app launches.
            if event.type != .setup {
                lastSuccess = event.endDate
            }
        }
    }

    /// CloudKit's errors are written for developers. Only a handful can reach a person here,
    /// and the two that matter are worth saying plainly, because both are fixable by them.
    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case 134400: return "Sign in to iCloud in Settings to sync."
        case 134405: return "iCloud storage is full, so nothing is syncing."
        default: return nsError.localizedDescription
        }
    }

    /// A short line for the About screen.
    var summary: String {
        if let lastError { return lastError }
        if activity != .idle { return activity.label }
        guard let lastSuccess else {
            return hasHeardFromCloudKit
                ? "Connected, nothing sent yet"
                : "Waiting for iCloud…"
        }
        return "Last synced \(Format.relative(lastSuccess))"
    }

    var isWorking: Bool { activity != .idle }
}
