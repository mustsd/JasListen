import Foundation
import SwiftData

/// A named, ordered collection of lessons.
///
/// Membership is stored in `PlaylistItem` rather than as a plain `[Lesson]`
/// relationship, because a playlist is a running order: every item carries the
/// position the sidebar count, the detail view, and backups all read from.
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    var items: [PlaylistItem]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        items: [PlaylistItem] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
    }

    /// The items in playlist order.
    ///
    /// SwiftData hands a to-many relationship back in no guaranteed order, so
    /// the stored position is what counts. `addedAt` and `id` only settle a tie
    /// if a position ever ends up duplicated.
    var orderedItems: [PlaylistItem] {
        items.sorted { first, second in
            if first.position != second.position { return first.position < second.position }
            if first.addedAt != second.addedAt { return first.addedAt < second.addedAt }
            return first.id.uuidString < second.id.uuidString
        }
    }

    /// The lessons in running order, skipping an item whose lesson was removed.
    var orderedLessons: [Lesson] {
        orderedItems.compactMap(\.lesson)
    }
}

/// One lesson placed in a `Playlist`, with its position in the running order.
@Model
final class PlaylistItem {
    @Attribute(.unique) var id: UUID
    var position: Int
    var addedAt: Date
    var playlist: Playlist?
    var lesson: Lesson?

    init(
        id: UUID = UUID(),
        position: Int,
        addedAt: Date = .now,
        lesson: Lesson? = nil
    ) {
        self.id = id
        self.position = position
        self.addedAt = addedAt
        self.lesson = lesson
    }
}
