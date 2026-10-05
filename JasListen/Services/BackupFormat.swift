import AVFoundation
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

/// Manifest record for one lesson inside a native `.stillbackup` archive.
struct BackupLessonRecord: Codable, Sendable {
    var id: UUID
    var title: String
    var audioPath: String
    var audioType: String
    var duration: Double
    var createdAt: Date
    var lastPlayedAt: Date?
    var lastPosition: Double
}

/// `manifest.json` inside a native `.stillbackup` archive.
struct BackupManifest: Codable, Sendable {
    var format: String
    var version: Int
    var exportedAt: Date
    var lessons: [BackupLessonRecord]

    static let currentFormat = "still-native-backup"
    static let currentVersion = 1
}

/// Web export produced by the legacy player (`still-listening-backup` v1 JSON).
struct LegacyWebBackup: Decodable, Sendable {
    var format: String
    var version: Int
    var lessons: [LegacyWebLesson]
}

struct LegacyWebLesson: Decodable, Sendable {
    var id: String
    var title: String
    var audioType: String?
    var fileName: String?
    var duration: Double
    var createdAt: Date?
    var lastPlayedAt: Date?
    var lastPosition: Double?
    var audioBase64: String
}

/// A decoded and validated backup lesson pointing at a staged audio file.
struct StagedLesson: Sendable {
    var id: UUID
    var title: String
    var source: URL
    /// File name the lesson used inside the backup. Restore keeps it so an
    /// exported archive can be restored byte-for-byte.
    var relativeAudioPath: String
    var audioType: String
    var duration: Double
    var createdAt: Date
    var lastPlayedAt: Date?
    var lastPosition: Double
}

/// A backup that has been decoded and validated but not applied yet.
enum ParsedBackup: Sendable {
    case native(lessons: [StagedLesson])
    case legacyWeb(lessons: [StagedLesson])

    var lessonCount: Int {
        switch self {
        case .native(let lessons), .legacyWeb(let lessons): lessons.count
        }
    }

    var lessons: [StagedLesson] {
        switch self {
        case .native(let lessons), .legacyWeb(let lessons): lessons
        }
    }
}

/// Cheap identification of a backup file, used to confirm a restore before
/// any audio is copied into the library.
struct BackupPreview: Sendable {
    let lessonCount: Int
    let isLegacyWebBackup: Bool
}

enum BackupError: LocalizedError {
    case unsupportedFormat
    case unsafeArchivePath
    case missingAudio(String)
    case invalidManifest
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This backup format is not supported."
        case .unsafeArchivePath: "The backup contains an unsafe file path."
        case .missingAudio(let title): "The backup is missing audio for \(title)."
        case .invalidManifest: "The backup manifest is incomplete or invalid."
        case .invalidAudio(let title): "The audio for \(title) could not be read."
        }
    }
}

/// Pure decoding and validation for both backup formats.
///
/// This layer never touches SwiftData, and it stages audio in a caller-supplied
/// temporary directory, so a rejected backup cannot damage the live library.
enum BackupParser {
    /// Largest audio entry the parser will accept from an archive or a web
    /// backup, to bound memory use on a malformed file.
    static let maximumAudioBytes = 512 * 1024 * 1024

    static func preview(of url: URL) -> BackupPreview? {
        if url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let backup = try? decodeLegacyWebBackup(data),
                  isSupportedLegacy(backup) else { return nil }
            return BackupPreview(lessonCount: backup.lessons.count, isLegacyWebBackup: true)
        }
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            return nil
        }
        guard let data = manifestData(in: archive),
              let manifest = try? decodeManifest(data),
              manifest.format == BackupManifest.currentFormat,
              manifest.version == BackupManifest.currentVersion,
              !manifest.lessons.isEmpty else { return nil }
        return BackupPreview(lessonCount: manifest.lessons.count, isLegacyWebBackup: false)
    }

    static func parseLegacyWebBackup(from url: URL, destination: URL) async throws -> ParsedBackup {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let backup = try decodeLegacyWebBackup(data)
        guard isSupportedLegacy(backup) else { throw BackupError.unsupportedFormat }

        var usedIDs = Set<String>()
        var lessons: [StagedLesson] = []
        for item in backup.lessons {
            let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty,
                  !item.id.isEmpty,
                  usedIDs.insert(item.id).inserted,
                  item.duration.isFinite, item.duration > 0 else { throw BackupError.invalidManifest }
            guard let audioData = Data(base64Encoded: item.audioBase64),
                  !audioData.isEmpty,
                  audioData.count <= maximumAudioBytes else { throw BackupError.invalidManifest }

            let id = UUID(uuidString: item.id) ?? UUID()
            let ext = sanitizedExtension(URL(fileURLWithPath: item.fileName ?? "audio.mp3").pathExtension)
            let file = destination.appendingPathComponent("\(id.uuidString).\(ext.isEmpty ? "mp3" : ext)")
            try audioData.write(to: file, options: Data.WritingOptions.atomic)
            let lesson = StagedLesson(
                id: id,
                title: trimmedTitle,
                source: file,
                relativeAudioPath: file.lastPathComponent,
                audioType: item.audioType ?? audioType(forExtension: ext),
                duration: item.duration,
                createdAt: item.createdAt ?? .now,
                lastPlayedAt: item.lastPlayedAt,
                lastPosition: clampedPosition(item.lastPosition ?? 0, duration: item.duration)
            )
            try await validateAudio(lesson)
            lessons.append(lesson)
        }
        guard !lessons.isEmpty else { throw BackupError.invalidManifest }
        return .legacyWeb(lessons: lessons)
    }

    static func parseNativeBackup(from url: URL, destination: URL) async throws -> ParsedBackup {

        let archive = try Archive(url: url, accessMode: .read)
        guard let manifestData = manifestData(in: archive),
              let manifest = try? decodeManifest(manifestData),
              manifest.format == BackupManifest.currentFormat,
              manifest.version == BackupManifest.currentVersion,
              !manifest.lessons.isEmpty else { throw BackupError.unsupportedFormat }
        guard Set(manifest.lessons.map(\.id)).count == manifest.lessons.count else {
            throw BackupError.invalidManifest
        }

        let entries = Set(archive.map(\.path))
        var lessons: [StagedLesson] = []
        for record in manifest.lessons {
            let trimmedTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeAudioPath(record.audioPath), entries.contains(record.audioPath),
                  let entry = archive[record.audioPath], entry.type == .file,
                  record.duration.isFinite, record.duration > 0, !trimmedTitle.isEmpty,
                  let audioData = try? audioData(in: archive, entry: entry, size: entry.uncompressedSize),
                  !audioData.isEmpty, audioData.count <= maximumAudioBytes else {
                throw BackupError.invalidManifest
            }
            let ext = sanitizedExtension(URL(fileURLWithPath: record.audioPath).pathExtension)
            let file = destination.appendingPathComponent("\(record.id.uuidString).\(ext.isEmpty ? "audio" : ext)")
            try audioData.write(to: file, options: Data.WritingOptions.atomic)
            let lesson = StagedLesson(
                id: record.id,
                title: trimmedTitle,
                source: file,
                relativeAudioPath: file.lastPathComponent,
                audioType: record.audioType.isEmpty ? audioType(forExtension: ext) : record.audioType,
                duration: record.duration,
                createdAt: record.createdAt,
                lastPlayedAt: record.lastPlayedAt,
                lastPosition: clampedPosition(record.lastPosition, duration: record.duration)
            )
            try await validateAudio(lesson)
            lessons.append(lesson)
        }
        return .native(lessons: lessons)
    }

    /// Validates every parsed lesson once more before it is applied.
    static func validate(_ backup: ParsedBackup) async throws -> [StagedLesson] {
        for lesson in backup.lessons { try await validateAudio(lesson) }
        return backup.lessons
    }

    /// Reassigns any lesson ID that collides with the existing library or with
    /// another imported lesson. Restore merges instead of overwriting, so a
    /// collision must never replace an existing lesson.
    static func assignIDs(_ lessons: [StagedLesson], existingIDs: Set<UUID>) -> [StagedLesson] {
        var used = existingIDs
        return lessons.map { lesson in
            var updated = lesson
            while used.contains(updated.id) { updated.id = UUID() }
            used.insert(updated.id)
            return updated
        }
    }

    static func decodeManifest(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }

    static func decodeLegacyWebBackup(_ data: Data) throws -> LegacyWebBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LegacyWebBackup.self, from: data)
    }

    static func manifestData(in archive: Archive) -> Data? {
        guard let entry = archive["manifest.json"], entry.type == .file else { return nil }
        return try? audioData(in: archive, entry: entry, size: entry.uncompressedSize)
    }

    /// Only `Audio/<file>` entries are accepted, so a manifest can never direct
    /// an extraction outside the archive's own audio directory.
    static func isSafeAudioPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("..") else { return false }
        let components = path.split(separator: "/")
        return components.count == 2 && components.first == "Audio" && !components[1].isEmpty
    }

    private static func validateAudio(_ lesson: StagedLesson) async throws {
        do {
            let asset = AVURLAsset(url: lesson.source)
            let playable = try await asset.load(.isPlayable)
            let loaded = try await asset.load(.duration)
            let audioDuration = loaded.seconds
            guard playable, audioDuration.isFinite, audioDuration > 0,
                  abs(audioDuration - lesson.duration) < max(2, lesson.duration * 0.05) else {
                throw BackupError.invalidAudio(lesson.title)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalidAudio(lesson.title)
        }
    }

    private static func isSupportedLegacy(_ backup: LegacyWebBackup) -> Bool {
        backup.format == "still-listening-backup" && backup.version == 1 && !backup.lessons.isEmpty
    }

    private static func audioData(in archive: Archive, entry: Entry, size: UInt64) throws -> Data {
        if size > 0, UInt64(size) > UInt64(maximumAudioBytes) { throw BackupError.invalidManifest }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            guard data.count + chunk.count <= maximumAudioBytes else {
                throw BackupError.invalidManifest
            }
            data.append(chunk)
        })
        return data
    }

    private static func sanitizedExtension(_ value: String) -> String {
        let lowered = value.lowercased()
        guard (1...8).contains(lowered.count),
              lowered.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return lowered
    }

    private static func audioType(forExtension ext: String) -> String {
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType { return mime }
        return "audio/mpeg"
    }

    private static func clampedPosition(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), duration)
    }
}
