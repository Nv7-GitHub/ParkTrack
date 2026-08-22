import Foundation
import UniformTypeIdentifiers

/// The container a full backup is written into.
///
/// A backup that carries photos and video is a fundamentally different object from the
/// JSON one that came before it: a library with a few hundred attachments runs to
/// gigabytes, and base64 inside JSON would inflate that by a further third and force both
/// ends to hold the whole thing in memory to encode or parse it. So media travels beside
/// the manifest as raw bytes rather than inside it.
///
/// The format is deliberately hand-rolled rather than a zip or an `AppleArchive`. Photos
/// and video are already compressed, so an archiver buys close to nothing on the only part
/// that is large, and both alternatives trade that for an API whose failure modes are
/// harder to test offline. What is here is a length-prefixed sequence that can be written
/// and read a blob at a time:
///
///     "PTBK"                          magic
///     UInt32                          format version
///     UInt64 + bytes                  manifest (the JSON payload)
///     UInt32 + bytes                  entry name
///     UInt64 + bytes                  entry data
///     ...repeating to end of file
///
/// Neither side ever holds more than one attachment at once: the writer appends each blob
/// as it is fetched from the store, and the reader indexes the file by seeking over the
/// data rather than reading it, then seeks back for each blob when it is actually wanted.
enum BackupArchive {
    static let magic = Data("PTBK".utf8)
    static let formatVersion: UInt32 = 1
    static let fileExtension = "parkmaxbackup"

    /// What backups were called before the app was renamed.
    ///
    /// Still opened, because a rename is no reason to stop reading somebody's backup — and
    /// the file itself did not change at all. Only the extension differs; the magic number,
    /// the layout and the manifest are identical, so a file written under either name is
    /// read by the same code.
    static let legacyFileExtension = "parktrackbackup"

    /// A dynamic type derived from the extension rather than one declared in the Info.plist.
    /// Declaring an exported UTI would mean an array of dictionaries in the generated
    /// Info.plist, which `INFOPLIST_KEY_*` build settings cannot express — and the file
    /// picker only needs something to filter on. Falls back to `.data` on the off chance the
    /// system declines to mint one, in which case the magic-number check still rejects
    /// anything that is not a backup.
    static let contentType: UTType = UTType(filenameExtension: fileExtension) ?? .data

    /// Everything the file picker should offer, newest name first.
    static let contentTypes: [UTType] = [
        UTType(filenameExtension: fileExtension),
        UTType(filenameExtension: legacyFileExtension)
    ].compactMap { $0 }.isEmpty ? [.data] : [
        UTType(filenameExtension: fileExtension),
        UTType(filenameExtension: legacyFileExtension)
    ].compactMap { $0 }

    /// Guards against a corrupt or hostile length prefix being taken at face value and
    /// turned into an allocation. Nothing ParkTrack writes comes close to this.
    static let maximumEntryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumNameBytes: UInt32 = 4 * 1_024
}

enum BackupArchiveError: LocalizedError {
    case notAnArchive
    case unsupportedVersion(UInt32)
    case truncated
    case corruptEntry

    var errorDescription: String? {
        switch self {
        case .notAnArchive: "That doesn't look like a ParkMax backup."
        case .unsupportedVersion(let version): "That backup was made by a newer version of ParkMax (format \(version))."
        case .truncated: "That backup file is incomplete."
        case .corruptEntry: "That backup file is damaged."
        }
    }
}

// MARK: - Writing

/// Streams a backup to disk one entry at a time.
final class BackupArchiveWriter {
    private let handle: FileHandle
    private var isFinished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: BackupArchive.magic)
        try handle.write(contentsOf: UInt32(BackupArchive.formatVersion).littleEndianBytes)
    }

    /// Must be called exactly once, before any entry.
    func writeManifest(_ data: Data) throws {
        try handle.write(contentsOf: UInt64(data.count).littleEndianBytes)
        try handle.write(contentsOf: data)
    }

    /// Appends one blob. The caller is expected to fetch it immediately before calling and
    /// let it go immediately after, so peak memory stays at one attachment.
    func append(name: String, data: Data) throws {
        let nameData = Data(name.utf8)
        try handle.write(contentsOf: UInt32(nameData.count).littleEndianBytes)
        try handle.write(contentsOf: nameData)
        try handle.write(contentsOf: UInt64(data.count).littleEndianBytes)
        try handle.write(contentsOf: data)
    }

    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        try handle.close()
    }

    deinit { try? handle.close() }
}

// MARK: - Reading

/// Reads a backup without loading it.
///
/// Construction walks the file once to learn where each entry is, seeking over the payload
/// bytes rather than reading them, so opening a multi-gigabyte backup costs a few hundred
/// small reads. `data(for:)` then seeks back for exactly one blob.
final class BackupArchiveReader {
    private let handle: FileHandle
    private var offsets: [String: (offset: UInt64, length: UInt64)] = [:]

    let manifest: Data
    private(set) var entryNames: [String] = []

    init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw BackupArchiveError.notAnArchive
        }
        self.handle = handle

        guard let header = try handle.read(upToCount: BackupArchive.magic.count),
              header == BackupArchive.magic else {
            try? handle.close()
            throw BackupArchiveError.notAnArchive
        }

        let version = try Self.readUInt32(handle)
        guard version <= BackupArchive.formatVersion else {
            try? handle.close()
            throw BackupArchiveError.unsupportedVersion(version)
        }

        let manifestLength = try Self.readUInt64(handle)
        guard manifestLength <= BackupArchive.maximumEntryBytes else {
            try? handle.close()
            throw BackupArchiveError.corruptEntry
        }
        guard let manifest = try handle.read(upToCount: Int(manifestLength)),
              manifest.count == Int(manifestLength) else {
            try? handle.close()
            throw BackupArchiveError.truncated
        }
        self.manifest = manifest

        try indexEntries()
    }

    /// Walks the entry list, recording where each blob starts and skipping over its bytes.
    private func indexEntries() throws {
        while true {
            guard let nameLengthBytes = try handle.read(upToCount: 4), !nameLengthBytes.isEmpty else {
                return // clean end of file
            }
            guard nameLengthBytes.count == 4 else { throw BackupArchiveError.truncated }
            let nameLength = UInt32(littleEndianBytes: nameLengthBytes)
            guard nameLength > 0, nameLength <= BackupArchive.maximumNameBytes else {
                throw BackupArchiveError.corruptEntry
            }

            guard let nameData = try handle.read(upToCount: Int(nameLength)),
                  nameData.count == Int(nameLength),
                  let name = String(data: nameData, encoding: .utf8) else {
                throw BackupArchiveError.truncated
            }

            let dataLength = try Self.readUInt64(handle)
            guard dataLength <= BackupArchive.maximumEntryBytes else {
                throw BackupArchiveError.corruptEntry
            }

            let start = try handle.offset()
            offsets[name] = (start, dataLength)
            entryNames.append(name)

            // Seek past the payload rather than reading it.
            try handle.seek(toOffset: start + dataLength)
        }
    }

    /// Nil when the manifest referenced an attachment the file doesn't actually carry,
    /// which is recoverable: the visit still restores, just without its photo.
    func data(for name: String) throws -> Data? {
        guard let entry = offsets[name] else { return nil }
        try handle.seek(toOffset: entry.offset)
        guard let data = try handle.read(upToCount: Int(entry.length)),
              data.count == Int(entry.length) else {
            throw BackupArchiveError.truncated
        }
        return data
    }

    func close() {
        try? handle.close()
    }

    deinit { try? handle.close() }

    // MARK: - Primitives

    private static func readUInt32(_ handle: FileHandle) throws -> UInt32 {
        guard let bytes = try handle.read(upToCount: 4), bytes.count == 4 else {
            throw BackupArchiveError.truncated
        }
        return UInt32(littleEndianBytes: bytes)
    }

    private static func readUInt64(_ handle: FileHandle) throws -> UInt64 {
        guard let bytes = try handle.read(upToCount: 8), bytes.count == 8 else {
            throw BackupArchiveError.truncated
        }
        return UInt64(littleEndianBytes: bytes)
    }
}

// MARK: - Byte helpers

/// Written out by hand rather than via `withUnsafeBytes` so the encoding is fixed by this
/// file and not by the architecture that happens to be running.
private extension UInt32 {
    var littleEndianBytes: Data {
        var value = littleEndian
        return Data(bytes: &value, count: 4)
    }

    init(littleEndianBytes data: Data) {
        var value: UInt32 = 0
        for (index, byte) in data.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        self = value
    }
}

private extension UInt64 {
    var littleEndianBytes: Data {
        var value = littleEndian
        return Data(bytes: &value, count: 8)
    }

    init(littleEndianBytes data: Data) {
        var value: UInt64 = 0
        for (index, byte) in data.prefix(8).enumerated() {
            value |= UInt64(byte) << (8 * index)
        }
        self = value
    }
}
