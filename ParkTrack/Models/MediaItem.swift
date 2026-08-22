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

    /// How many bytes this item's blobs occupy, recorded when they are set.
    ///
    /// Kept so storage can be attributed without reading it. Asking a `MediaItem` how large
    /// its data is loads that data, and totalling a library to draw one figure would mean
    /// pulling a hundred megabytes of photographs through memory. Zero on rows written
    /// before this existed, which the footprint fills in as it goes.
    var byteCount: Int = 0

    var visit: Visit?

    init(data: Data?, isVideo: Bool, thumbnailData: Data? = nil) {
        self.identifier = UUID()
        self.data = data
        self.isVideo = isVideo
        self.thumbnailData = thumbnailData
        self.byteCount = (data?.count ?? 0) + (thumbnailData?.count ?? 0)
        self.createdAt = Date()
    }
}
