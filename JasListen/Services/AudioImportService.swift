import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum AudioImportError: LocalizedError {
    case unsupportedFormat
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Choose an audio file, such as an MP3."
        case .invalidAudio:
            return "This file could not be decoded as audio."
        }
    }
}

/// What one picker selection or drop contributes to the library.
struct AudioImportSelection: Equatable {
    /// Audio files to import, in the order they should be added.
    var audioFiles: [URL] = []
    /// Folders that were searched for audio.
    var folderCount = 0
    /// Picked files that were not audio, plus picked folders that held no audio.
    var skippedCount = 0

    var isEmpty: Bool { audioFiles.isEmpty }
}

/// Audio import and library file layout.
///
/// The file-layout helpers stay non-isolated so backup creation can read them
/// from a background task; the lesson operations are main-actor bound because
/// they use the SwiftData model context.
enum AudioImportService {
    static func audioDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Keep the original on-disk path so existing lesson records still resolve after the rename.
        let directory = support.appendingPathComponent("Still/Audio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Choosing audio

    /// The type that validates a file as audio. The picker, folder scans, and
    /// import all use it so they agree on what can be added.
    static func audioType(for url: URL) -> UTType? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .audio) else {
            return nil
        }
        return type
    }

    static func isAudioFile(_ url: URL) -> Bool {
        audioType(for: url) != nil
    }

    /// A lesson title taken from the file name: `Lesson_01.mp3` becomes
    /// `Lesson 01`.
    static func suggestedTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Expands picked files and folders into the audio files to import.
    ///
    /// Folders are searched recursively so a whole course folder can be added in
    /// one step; notes, artwork, and other non-audio files inside a folder are
    /// passed over. A picked file that is not audio, and a folder that holds no
    /// audio at all, are counted in `skippedCount` so the caller can report them
    /// instead of failing the whole selection. Duplicates are dropped so nothing
    /// is added twice.
    static func collectAudioFiles(
        from selection: [URL],
        fileManager: FileManager = .default
    ) -> AudioImportSelection {
        var result = AudioImportSelection()
        var seen = Set<String>()

        func append(_ url: URL) {
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            result.audioFiles.append(url)
        }

        for url in selection {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.skippedCount += 1
                continue
            }

            if isDirectory.boolValue {
                result.folderCount += 1
                let found = audioFiles(in: url, fileManager: fileManager)
                if found.isEmpty { result.skippedCount += 1 }
                found.forEach(append)
            } else if isAudioFile(url) {
                append(url)
            } else {
                result.skippedCount += 1
            }
        }
        return result
    }

    /// Recursively lists the audio files inside a folder in a stable, readable
    /// order. Hidden files and file packages are skipped, so a selected folder
    /// only contributes real audio.
    static func audioFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  isAudioFile(url) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Importing

    @MainActor
    static func importAudio(
        from sourceURL: URL,
        title: String,
        context: ModelContext,
        id: UUID = UUID(),
        createdAt: Date = .now,
        lastPlayedAt: Date? = nil,
        lastPosition: Double = 0,
        audioDirectory: URL? = nil
    ) async throws -> Lesson {
        let ext = sourceURL.pathExtension.lowercased()
        guard let type = audioType(for: sourceURL) else {
            throw AudioImportError.unsupportedFormat
        }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let directory = try audioDirectory ?? Self.audioDirectory()
        let filename = "\(id.uuidString).\(ext.isEmpty ? "audio" : ext)"
        let destination = directory.appendingPathComponent(filename)
        // Keep the real extension while staging: AVFoundation refuses to open a
        // file whose extension it does not recognise, which would make every
        // import fail validation.
        let staging = directory.appendingPathComponent(".\(id.uuidString).importing.\(ext.isEmpty ? "audio" : ext)")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: staging)
            let asset = AVURLAsset(url: staging)
            let playable = try await asset.load(.isPlayable)
            let loadedDuration = try await asset.load(.duration)
            let duration = loadedDuration.seconds
            guard playable, duration.isFinite, duration > 0 else {
                throw AudioImportError.invalidAudio
            }
            try FileManager.default.moveItem(at: staging, to: destination)

            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lesson = Lesson(
                id: id,
                title: trimmedTitle.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : trimmedTitle,
                relativeAudioPath: filename,
                audioType: type.preferredMIMEType ?? "audio/mpeg",
                duration: duration,
                createdAt: createdAt,
                lastPlayedAt: lastPlayedAt,
                lastPosition: min(max(0, lastPosition), duration)
            )
            context.insert(lesson)
            do {
                try context.save()
            } catch {
                context.delete(lesson)
                try? context.save()
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return lesson
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    static func audioURL(for lesson: Lesson, audioDirectory: URL? = nil) throws -> URL {
        let safeName = URL(fileURLWithPath: lesson.relativeAudioPath).lastPathComponent
        guard safeName == lesson.relativeAudioPath else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = try audioDirectory ?? Self.audioDirectory()
        return directory.appendingPathComponent(safeName)
    }
}
