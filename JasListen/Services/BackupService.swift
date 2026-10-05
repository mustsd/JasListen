import Foundation
import SwiftData
import UniformTypeIdentifiers
import ZIPFoundation

/// Applies decoded backups to the SwiftData library and builds native
/// `.stillbackup` archives. Decoding and validation live in `BackupParser`.
///
/// Main-actor bound like `AudioImportService.importAudio`, because it touches
/// the SwiftData context. The archive assembly itself runs detached.
@MainActor
enum BackupService {
    /// Builds a native backup archive and returns the temporary file URL.
    ///
    /// The archive is assembled on a background task so a large library keeps
    /// the interface responsive. Lesson values are snapshotted on the main
    /// actor so SwiftData models are never touched off the main actor.
    static func makeBackup(
        lessons: [Lesson],
        audioDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let directory = try audioDirectory ?? AudioImportService.audioDirectory(fileManager: fileManager)
        let records = lessons.map(SourceLesson.init)
        return try await Task.detached(priority: .userInitiated) {
            let staging = fileManager.temporaryDirectory
                .appendingPathComponent("JasListenBackup-\(UUID().uuidString)", isDirectory: true)
            let audio = staging.appendingPathComponent("Audio", isDirectory: true)
            try fileManager.createDirectory(at: audio, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }

            var entries: [BackupLessonRecord] = []
            for lesson in records {
                let source = directory.appendingPathComponent(lesson.relativeAudioPath)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw BackupError.missingAudio(lesson.title)
                }
                let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
                let entryName = "\(lesson.id.uuidString).\(ext)"
                try fileManager.copyItem(at: source, to: audio.appendingPathComponent(entryName))
                entries.append(BackupLessonRecord(
                    id: lesson.id,
                    title: lesson.title,
                    audioPath: "Audio/\(entryName)",
                    audioType: lesson.audioType,
                    duration: lesson.duration,
                    createdAt: lesson.createdAt,
                    lastPlayedAt: lesson.lastPlayedAt,
                    lastPosition: lesson.lastPosition
                ))
            }

            let manifest = BackupManifest(
                format: BackupManifest.currentFormat,
                version: BackupManifest.currentVersion,
                exportedAt: .now,
                lessons: entries
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

            let output = fileManager.temporaryDirectory
                .appendingPathComponent("JasListen-\(dateStamp()).stillbackup")
            try? fileManager.removeItem(at: output)
            try fileManager.zipItem(at: staging, to: output, shouldKeepParent: false)
            return output
        }.value
    }

    /// Cheap identification of a selected backup file so the interface can ask
    /// for confirmation before anything is copied.
    static func preview(of url: URL) -> BackupPreview? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return BackupParser.preview(of: url)
    }

    /// Restores a native `.stillbackup` or a legacy web v1 JSON backup.
    ///
    /// Audio is parsed into a staging directory first, then validated, then
    /// moved into the library. A backup that fails anywhere leaves the existing
    /// library and its audio untouched.
    static func restore(
        from url: URL,
        context: ModelContext,
        audioDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) async throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let library = try audioDirectory ?? AudioImportService.audioDirectory(fileManager: fileManager)
        return try await withStagingDirectory(fileManager: fileManager) { staging in
            let parsed = url.pathExtension.lowercased() == "json"
                ? try await BackupParser.parseLegacyWebBackup(from: url, destination: staging)
                : try await BackupParser.parseNativeBackup(from: url, destination: staging)
            let lessons = try await BackupParser.validate(parsed)

            var moved: [URL] = []
            do {
                let staged = try move(lessons, into: library, fileManager: fileManager, moved: &moved)
                return try commit(staged, context: context, audioDirectory: library, fileManager: fileManager)
            } catch {
                moved.forEach { try? fileManager.removeItem(at: $0) }
                throw error
            }
        }
    }

    /// Merges staged lessons into the library, rewrites colliding IDs, and
    /// rolls inserted models back if the save fails.
    static func commit(
        _ staged: [StagedLesson],
        context: ModelContext,
        audioDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard !staged.isEmpty else { throw BackupError.invalidManifest }
        let existing = try context.fetch(FetchDescriptor<Lesson>())
        let assigned = BackupParser.assignIDs(staged, existingIDs: Set(existing.map(\.id)))
        let audioDirectory = try audioDirectory ?? AudioImportService.audioDirectory(fileManager: fileManager)
        var createdFiles: [URL] = []
        var newLessons: [Lesson] = []
        do {
            for item in assigned {
                let id = item.id
                let ext = item.source.pathExtension.isEmpty ? "mp3" : item.source.pathExtension
                let filename = "\(id.uuidString).\(ext)"
                let finalURL = audioDirectory.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: item.source.path) {
                    try fileManager.moveItem(at: item.source, to: finalURL)
                    createdFiles.append(finalURL)
                }
                let lesson = Lesson(
                    id: id,
                    title: item.title,
                    relativeAudioPath: filename,
                    audioType: item.audioType,
                    duration: item.duration,
                    createdAt: item.createdAt,
                    lastPlayedAt: item.lastPlayedAt,
                    lastPosition: min(max(0, item.lastPosition), item.duration)
                )
                context.insert(lesson)
                newLessons.append(lesson)
            }
            try context.save()
            return newLessons.count
        } catch {
            for lesson in newLessons { context.delete(lesson) }
            context.rollback()
            createdFiles.forEach { try? fileManager.removeItem(at: $0) }
            throw error
        }
    }

    /// Destination file name for a lesson whose ID may have been reassigned to
    /// resolve a collision, so the stored path always matches the ID and can
    /// never escape the library directory.
    private static func fileName(for lesson: StagedLesson) -> String {
        let ext = URL(fileURLWithPath: lesson.relativeAudioPath).pathExtension.lowercased()
        let resolvedExt = ext.isEmpty
            ? (lesson.source.pathExtension.isEmpty ? "mp3" : lesson.source.pathExtension.lowercased())
            : ext
        return "\(lesson.id.uuidString).\(resolvedExt)"
    }

    /// Moves validated files into the library, tracking each move so the
    /// caller can undo them if the merge then fails.
    private static func move(
        _ lessons: [StagedLesson],
        into library: URL,
        fileManager: FileManager,
        moved: inout [URL]
    ) throws -> [StagedLesson] {
        try lessons.map { lesson in
            let destination = library.appendingPathComponent(fileName(for: lesson))
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: lesson.source, to: destination)
            moved.append(destination)
            var updated = lesson
            updated.source = destination
            return updated
        }
    }

    private static func withStagingDirectory<T>(
        fileManager: FileManager,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("JasListenRestore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        return try await body(staging)
    }

    nonisolated private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

/// Sendable snapshot of a lesson so archive building can run off the main actor.
private struct SourceLesson: Sendable {
    let id: UUID
    let title: String
    let relativeAudioPath: String
    let audioType: String
    let duration: Double
    let createdAt: Date
    let lastPlayedAt: Date?
    let lastPosition: Double

    init(_ lesson: Lesson) {
        id = lesson.id
        title = lesson.title
        relativeAudioPath = lesson.relativeAudioPath
        audioType = lesson.audioType
        duration = lesson.duration
        createdAt = lesson.createdAt
        lastPlayedAt = lesson.lastPlayedAt
        lastPosition = lesson.lastPosition
    }
}

extension UTType {
    static let stillBackup = UTType(exportedAs: "com.jaslistening.stillbackup", conformingTo: .zip)
}
