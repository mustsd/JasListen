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
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .audio) else {
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
