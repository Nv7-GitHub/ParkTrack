import Foundation
import SwiftData

/// A photo or short video attached to a visit.
///
/// Stored with `.externalStorage` so large blobs live on disk rather than bloating
/// the store file, and so they stay cheap to sync.
@Model
final class MediaItem {
    var identifier: UUID = UUID()
    @Attribute(.externalStorage) var data: Data?
    var isVideo: Bool = false
    var createdAt: Date = Date()
    /// Poster frame for videos, so lists don't have to decode video to draw a thumbnail.
    @Attribute(.externalStorage) var thumbnailData: Data?

    var visit: Visit?

    init(data: Data?, isVideo: Bool, thumbnailData: Data? = nil) {
        self.identifier = UUID()
        self.data = data
        self.isVideo = isVideo
        self.thumbnailData = thumbnailData
        self.createdAt = Date()
    }
}
