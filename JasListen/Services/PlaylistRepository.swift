import Foundation
import SwiftData

enum PlaylistError: LocalizedError, Equatable {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give the playlist a name."
        }
    }
}

/// Playlist sorting and reordering rules. These operations return ordered
/// values; the repository remains responsible for persisting mutations.
enum PlaylistSortOrder: String, CaseIterable, Identifiable {
    case manual
    case name
    case recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .recentlyAdded: "Recently Added"
        }
    }
}

enum PlaylistOrdering {
    static func sorted(_ items: [PlaylistItem], by order: PlaylistSortOrder) -> [PlaylistItem] {
        switch order {
        case .manual:
            items
        case .name:
            items.sorted { first, second in
                guard let firstTitle = first.lesson?.title else { return second.lesson != nil }
                guard let secondTitle = second.lesson?.title else { return true }
                let comparison = firstTitle.localizedStandardCompare(secondTitle)
                return comparison == .orderedSame
                    ? first.position < second.position
                    : comparison == .orderedAscending
            }
        case .recentlyAdded:
            items.sorted { first, second in
                first.addedAt == second.addedAt
                    ? first.position < second.position
                    : first.addedAt > second.addedAt
            }
        }
    }

    /// Applies a list-style move to an ordered array: the items at `offsets` are
    /// lifted out and re-inserted so the first of them lands at `destination`.
    ///
    /// This matches the semantics of `List`'s `onMove`, which is what the
    /// playlist view hands over.
    static func move<T>(_ items: [T], from offsets: IndexSet, to destination: Int) -> [T] {
        let valid = offsets.filter { items.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return items }

        let lifted = valid.map { items[$0] }
        var remaining = items
        for index in valid.reversed() { remaining.remove(at: index) }
        // `destination` counts positions in the original array, so every lifted
        // item that sat before it shifts the insertion point down by one.
        let insertion = min(max(0, destination - valid.filter { $0 < destination }.count), remaining.count)
        remaining.insert(contentsOf: lifted, at: insertion)
        return remaining
    }
}

@MainActor
protocol PlaylistRepository {
    func allPlaylists() throws -> [Playlist]
    func playlist(id: UUID) throws -> Playlist?
    func playlist(named name: String) throws -> Playlist?
    @discardableResult func create(named name: String) throws -> Playlist
    /// Returns the playlist with this name, creating it when it does not exist.
    @discardableResult func ensurePlaylist(named name: String) throws -> Playlist
    /// Places every lesson that is in no playlist into the named playlist,
    /// oldest first, creating the playlist when needed. Returns how many
    /// lessons were newly filed.
    @discardableResult func fileUnfiledLessons(in name: String) throws -> Int
    func rename(_ playlist: Playlist, to name: String) throws
    func remove(_ playlist: Playlist) throws
    @discardableResult func add(_ lessons: [Lesson], to playlist: Playlist) throws -> Int
    func remove(_ items: [PlaylistItem], from playlist: Playlist) throws
    func remove(_ lesson: Lesson, from playlists: [Playlist]) throws
    func move(from offsets: IndexSet, to destination: Int, in playlist: Playlist) throws
    func save() throws
}

/// The playlist that holds lessons no playlist has claimed yet. It is the
/// replacement for the old flat lesson list: nothing may become unreachable, so
/// an unfiled lesson is always placed here instead of disappearing.
enum PlaylistInbox {
    static let name = "Imported"
}

/// SwiftData-backed playlist management.
///
/// Every change goes through here so membership stays deduplicated and the
/// stored positions stay a gap-free running order, whatever the caller did.
@MainActor
struct SwiftDataPlaylistRepository: PlaylistRepository {
    let context: ModelContext

    func allPlaylists() throws -> [Playlist] {
        try context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)]))
    }

    func playlist(id: UUID) throws -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Matches a trimmed, case-insensitive name so `imported` and `Imported`
    /// are the same bucket.
    func playlist(named name: String) throws -> Playlist? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return try allPlaylists().first { $0.name.localizedStandardCompare(wanted) == .orderedSame }
    }

    @discardableResult
    func ensurePlaylist(named name: String) throws -> Playlist {
        if let existing = try playlist(named: name) { return existing }
        return try create(named: name)
    }

    @discardableResult
    func fileUnfiledLessons(in name: String = PlaylistInbox.name) throws -> Int {
        let lessons = try context.fetch(
            FetchDescriptor<Lesson>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )
        guard !lessons.isEmpty else { return 0 }
        let placed = Set(try context.fetch(FetchDescriptor<PlaylistItem>()).compactMap { $0.lesson?.id })
        let unfiled = lessons.filter { !placed.contains($0.id) }
        guard !unfiled.isEmpty else { return 0 }
        let inbox = try ensurePlaylist(named: name)
        return try add(unfiled, to: inbox)
    }

    @discardableResult
    func create(named name: String) throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistError.emptyName }
        let playlist = Playlist(name: trimmed)
        context.insert(playlist)
        try context.save()
        return playlist
    }

    func rename(_ playlist: Playlist, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistError.emptyName }
        guard playlist.name != trimmed else { return }
        playlist.name = trimmed
        playlist.updatedAt = .now
        try context.save()
    }

    func remove(_ playlist: Playlist) throws {
        context.delete(playlist)
        try context.save()
    }

    @discardableResult
    func add(_ lessons: [Lesson], to playlist: Playlist) throws -> Int {
        var known = Set(playlist.items.compactMap { $0.lesson?.id })
        var position = (playlist.orderedItems.last?.position ?? -1) + 1
        var added = 0
        for lesson in lessons where known.insert(lesson.id).inserted {
            let item = PlaylistItem(position: position, lesson: lesson)
            context.insert(item)
            item.playlist = playlist
            // Setting the child side maintains the inverse, but appending is
            // done explicitly so the running order is visible to this context
            // right away. The identity check keeps it from being added twice.
            if !playlist.items.contains(where: { $0 === item }) {
                playlist.items.append(item)
            }
            position += 1
            added += 1
        }
        if added > 0 {
            playlist.updatedAt = .now
            try context.save()
        }
        return added
    }

    func remove(_ items: [PlaylistItem], from playlist: Playlist) throws {
        guard !items.isEmpty else { return }
        let removing = Set(items.map(\.id))
        for item in items {
            playlist.items.removeAll { $0 === item || removing.contains($0.id) }
            context.delete(item)
        }
        renumber(playlist)
        try context.save()
    }

    /// Drops a lesson from every playlist. Called before the lesson itself is
    /// deleted, so a playlist can never be left with a dangling entry.
    func remove(_ lesson: Lesson, from playlists: [Playlist]) throws {
        var changed = false
        for playlist in playlists {
            let items = playlist.items.filter { $0.lesson?.id == lesson.id }
            guard !items.isEmpty else { continue }
            for item in items {
                playlist.items.removeAll { $0 === item }
                context.delete(item)
            }
            renumber(playlist)
            changed = true
        }
        if changed { try context.save() }
    }

    func move(from offsets: IndexSet, to destination: Int, in playlist: Playlist) throws {
        let ordered = playlist.orderedItems
        let reordered = PlaylistOrdering.move(ordered, from: offsets, to: destination)
        guard reordered.map(\.id) != ordered.map(\.id) else { return }
        for (index, item) in reordered.enumerated() { item.position = index }
        playlist.updatedAt = .now
        try context.save()
    }

    func save() throws {
        try context.save()
    }

    /// Rewrites positions as 0..<count so the next insert has a clean tail and
    /// a restored backup reads back in the same order it was written.
    private func renumber(_ playlist: Playlist) {
        for (index, item) in playlist.orderedItems.enumerated() { item.position = index }
        playlist.updatedAt = .now
    }
}
