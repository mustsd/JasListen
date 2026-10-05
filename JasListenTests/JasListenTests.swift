import AVFoundation
import Foundation
import SwiftData
import Testing
import ZIPFoundation
@testable import JasListen

/// Acceptance coverage for PLANS.md: A–B range validation, legacy web backup
/// decoding, native import/export round trips, ID collisions, malformed or
/// unsafe archives, unsupported audio, and failure rollback.
@Suite(.serialized)
struct BackupAcceptanceTests {
    // MARK: - Fixtures

    /// Writes a valid mono 16-bit PCM WAV file so audio validation can be
    /// exercised without shipping binary fixtures.
    static func writeWAV(to url: URL, duration: Double = 1.0, sampleRate: Int = 8000) throws -> URL {
        var samples = Data()
        let frameCount = Int(duration * Double(sampleRate))
        for index in 0..<frameCount {
            let value = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            var sample = Int16(value * 12000)
            withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
        }

        func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndian(UInt32(36 + samples.count)))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(sampleRate * 2)))
        data.append(littleEndian(UInt16(2)))
        data.append(littleEndian(UInt16(16)))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndian(UInt32(samples.count)))
        data.append(samples)
        try data.write(to: url)
        return url
    }

    static func makeWorkingDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JasListenTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeLibrary(in working: URL) throws -> URL {
        let library = working.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return library
    }

    /// Creates an in-memory SwiftData context so tests never touch the real
    /// lesson library.
    @MainActor
    static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Lesson.self, Playlist.self, PlaylistItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    static func stagedLesson(
        id: UUID = UUID(),
        title: String = "Staged",
        source: URL,
        duration: Double = 1.0,
        lastPosition: Double = 0,
        relativeAudioPath: String? = nil
    ) -> StagedLesson {
        StagedLesson(
            id: id,
            title: title,
            source: source,
            relativeAudioPath: relativeAudioPath ?? source.lastPathComponent,
            audioType: "audio/wav",
            duration: duration,
            createdAt: .now,
            lastPlayedAt: nil,
            lastPosition: lastPosition
        )
    }

    static let legacyID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    static func legacyJSON(
        audioBase64: String,
        id: String = legacyID.uuidString,
        title: String = "Lesson",
        duration: Double = 1.0,
        lastPosition: Double = 0.5,
        format: String = "still-listening-backup",
        version: Int = 1
    ) -> Data {
        """
        {"format":"\(format)","version":\(version),"exportedAt":"2025-01-01T00:00:00Z","lessons":[{"id":"\(id)","title":"\(title)","audioType":"audio/wav","fileName":"lesson.wav","duration":\(duration),"createdAt":"2025-01-01T00:00:00Z","lastPlayedAt":null,"lastPosition":\(lastPosition),"audioBase64":"\(audioBase64)"}]}
        """.data(using: .utf8)!
    }

    static func writeLegacyBackup(_ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("still-listening-backup-\(UUID().uuidString).json")
        try data.write(to: url)
        return url
    }

    /// Builds a `.stillbackup` archive from manifest and audio payloads.
    static func makeArchive(entries: [(path: String, data: Data)], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("backup-\(UUID().uuidString).stillbackup")
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = Int(position)
                    return entry.data.subdata(in: start..<min(start + size, entry.data.count))
                }
            )
        }
        return url
    }

    static func manifestData(
        lessons: [(id: UUID, title: String, audioPath: String, duration: Double, lastPosition: Double)],
        format: String = BackupManifest.currentFormat,
        version: Int = BackupManifest.currentVersion
    ) throws -> Data {
        let records = lessons.map { lesson in
            BackupLessonRecord(
                id: lesson.id,
                title: lesson.title,
                audioPath: lesson.audioPath,
                audioType: "audio/wav",
                duration: lesson.duration,
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                lastPlayedAt: nil,
                lastPosition: lesson.lastPosition
            )
        }
        let manifest = BackupManifest(
            format: format,
            version: version,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lessons: records
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    // MARK: - A–B range validation (PLANS.md line 59)

    @Test func acceptsValidABLoop() throws {
        let loop = try ABLoop(start: 2, end: 4, duration: 10)
        #expect(loop.start == 2)
        #expect(loop.end == 4)
    }

    @Test func acceptsLoopSpanningExactlyTheMinimumDuration() throws {
        let loop = try ABLoop(start: 0, end: ABLoop.minimumDuration, duration: 10)
        #expect(loop.end - loop.start == ABLoop.minimumDuration)
    }

    @Test func acceptsLoopEndingAtTheAudioEnd() throws {
        let loop = try ABLoop(start: 9, end: 10, duration: 10)
        #expect(loop.end == 10)
    }

    @Test func rejectsShortOrOutOfBoundsLoop() {
        #expect(throws: LoopError.self) { try ABLoop(start: 1, end: 1.1, duration: 10) }
        #expect(throws: LoopError.self) { try ABLoop(start: -1, end: 2, duration: 10) }
        #expect(throws: LoopError.self) { try ABLoop(start: 2, end: 11, duration: 10) }
        #expect(throws: LoopError.self) { try ABLoop(start: 1.5, end: 1.74, duration: 10) }
    }

    @Test func rejectsNonFiniteLoopBounds() {
        #expect(throws: LoopError.self) { try ABLoop(start: .nan, end: 2, duration: 10) }
        #expect(throws: LoopError.self) { try ABLoop(start: 1, end: .infinity, duration: 10) }
        #expect(throws: LoopError.self) { try ABLoop(start: 1, end: 2, duration: .nan) }
    }

    @MainActor
    @Test func loopStateFollowsRangeValidation() throws {
        let working = try Self.makeWorkingDirectory("loop-state")
        let (controller, lesson) = try loadFixture(in: working, duration: 10)
        #expect(controller.duration == lesson.duration)

        #expect(throws: LoopError.self) { try controller.setLoop(start: 1, end: 1.05) }
        try controller.setLoop(start: 1, end: 3)
        #expect(controller.loop?.start == 1)
        #expect(controller.loop?.end == 3)
        #expect(!controller.loopEnabled, "a new range starts disabled")

        controller.toggleLoop()
        #expect(controller.loopEnabled)
        controller.toggleLoop()
        #expect(!controller.loopEnabled)

        controller.clearLoop()
        #expect(controller.loop == nil)
        #expect(!controller.loopEnabled)
    }

    // MARK: - Playback rate and seeking (PLANS.md lines 28, 62)

    @MainActor
    @Test func playbackRateSnapsToSupportedChoices() throws {
        let controller = AudioPlaybackController()
        controller.setPlaybackRate(1.24)
        #expect(controller.playbackRate == 1.25)
        controller.setPlaybackRate(0.1)
        #expect(controller.playbackRate == 0.75)
        controller.setPlaybackRate(9)
        #expect(controller.playbackRate == 1.5)
        controller.setPlaybackRate(1)
        #expect(controller.playbackRate == 1)
    }

    @Test func playbackQueueAdvancesAndWrapsToItsFirstLesson() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let queue = [firstID, secondID, thirdID]

        #expect(PlaybackQueue.nextID(after: firstID, in: queue) == secondID)
        #expect(PlaybackQueue.nextID(after: secondID, in: queue) == thirdID)
        #expect(PlaybackQueue.nextID(after: thirdID, in: queue) == firstID)
        #expect(PlaybackQueue.nextID(after: UUID(), in: queue) == nil)
        #expect(PlaybackQueue.nextID(after: firstID, in: []) == nil)
    }

    @MainActor
    @Test func playlistSortModesUseManualNameAndAddedDateOrder() throws {
        let context = try Self.makeContext()
        let alpha = Lesson(title: "Alpha", relativeAudioPath: "alpha.wav", audioType: "audio/wav", duration: 1)
        let zulu = Lesson(title: "Zulu", relativeAudioPath: "zulu.wav", audioType: "audio/wav", duration: 1)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let zuluItem = PlaylistItem(position: 0, addedAt: newer, lesson: zulu)
        let alphaItem = PlaylistItem(position: 1, addedAt: older, lesson: alpha)
        context.insert(alpha)
        context.insert(zulu)
        context.insert(zuluItem)
        context.insert(alphaItem)
        let items = [zuluItem, alphaItem]

        #expect(PlaylistOrdering.sorted(items, by: .manual).map { $0.lesson?.title } == ["Zulu", "Alpha"])
        #expect(PlaylistOrdering.sorted(items, by: .name).map { $0.lesson?.title } == ["Alpha", "Zulu"])
        #expect(PlaylistOrdering.sorted(items, by: .recentlyAdded).map { $0.lesson?.title } == ["Zulu", "Alpha"])
    }

    @MainActor
    @Test func playbackVolumeStaysWithinItsSupportedRange() {
        let controller = AudioPlaybackController()
        controller.setVolume(-0.5)
        #expect(controller.volume == 0)
        controller.setVolume(0.4)
        #expect(controller.volume == 0.4)
        controller.setVolume(1.5)
        #expect(controller.volume == 1)
    }

    @MainActor
    @Test func playlistRepositoryCreatesRenamesAndAddsLessonsOnce() throws {
        let context = try Self.makeContext()
        let first = Lesson(title: "First", relativeAudioPath: "first.wav", audioType: "audio/wav", duration: 1)
        let second = Lesson(title: "Second", relativeAudioPath: "second.wav", audioType: "audio/wav", duration: 2)
        context.insert(first)
        context.insert(second)

        let repository = SwiftDataPlaylistRepository(context: context)
        let playlist = try repository.create(named: "  Course  ")
        let insertedCount = try repository.add([first, second, first], to: playlist)

        #expect(playlist.name == "Course")
        #expect(insertedCount == 2)
        #expect(playlist.orderedLessons.map(\.title) == ["First", "Second"])

        try repository.rename(playlist, to: "  Finnish  ")
        #expect(playlist.name == "Finnish")
    }

    @MainActor
    @Test func seekClampsToTheLoadedDuration() throws {
        let working = try Self.makeWorkingDirectory("seek")
        let (controller, _) = try loadFixture(in: working, duration: 12)
        controller.seek(to: -5)
        #expect(controller.currentTime == 0)
        controller.seek(to: 40)
        #expect(controller.currentTime == 12)
        controller.seek(to: 6)
        #expect(controller.currentTime == 6)
    }

    @MainActor
    @Test func seekOutsideAnEnabledLoopDisablesIt() throws {
        let working = try Self.makeWorkingDirectory("seek-loop")
        let (controller, _) = try loadFixture(in: working, duration: 10)
        try controller.setLoop(start: 2, end: 4)
        controller.toggleLoop()
        #expect(controller.loopEnabled)
        controller.seek(to: 8)
        #expect(!controller.loopEnabled, "seeking outside the range pauses the loop")
    }

    // MARK: - Missing and unsupported audio (PLANS.md line 31)

    @MainActor
    @Test func loadingAMissingFileThrowsBeforePlayback() throws {
        let controller = AudioPlaybackController()
        let lesson = Lesson(
            title: "Gone",
            relativeAudioPath: "\(UUID().uuidString).wav",
            audioType: "audio/wav",
            duration: 3
        )
        #expect(throws: (any Error).self) { try controller.load(lesson) }
        #expect(controller.activeLessonID == nil)
    }

    @Test func audioURLRejectsTraversalPaths() throws {
        let lesson = Lesson(title: "Unsafe", relativeAudioPath: "../escape.mp3", audioType: "audio/mpeg", duration: 1)
        #expect(throws: (any Error).self) { try AudioImportService.audioURL(for: lesson) }
    }

    @MainActor
    @Test func importRejectsANonAudioFile() async throws {
        let working = try Self.makeWorkingDirectory("unsupported")
        let library = try Self.makeLibrary(in: working)
        let text = working.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: text)
        let context = try Self.makeContext()
        await #expect(throws: AudioImportError.self) {
            _ = try await AudioImportService.importAudio(
                from: text,
                title: "Notes",
                context: context,
                audioDirectory: library
            )
        }
    }

    // MARK: - Import staging (PLANS.md line 23)

    @MainActor
    @Test func importCopiesAudioAndLeavesNoStagingFiles() async throws {
        let working = try Self.makeWorkingDirectory("import")
        let library = try Self.makeLibrary(in: working)
        let fixture = try Self.writeWAV(to: working.appendingPathComponent("source.wav"))
        let context = try Self.makeContext()

        let lesson = try await AudioImportService.importAudio(
            from: fixture,
            title: "  Imported lesson  ",
            context: context,
            audioDirectory: library
        )

        #expect(lesson.title == "Imported lesson")
        #expect(abs(lesson.duration - 1.0) < 0.1)
        #expect(lesson.lastPosition == 0)
        let contents = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(contents.count == 1, "only the final audio file remains")
        #expect(contents.first == lesson.relativeAudioPath, "the stored path is relative")
        let url = try AudioImportService.audioURL(for: lesson, audioDirectory: library)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration).seconds > 0)
    }

    @MainActor
    @Test func importKeepsTheExistingLibraryWhenTheSourceIsUnreadable() async throws {
        let working = try Self.makeWorkingDirectory("import-fail")
        let library = try Self.makeLibrary(in: working)
        let broken = working.appendingPathComponent("broken.wav")
        try Data(repeating: 0x00, count: 128).write(to: broken)
        let context = try Self.makeContext()

        await #expect(throws: (any Error).self) {
            _ = try await AudioImportService.importAudio(
                from: broken,
                title: "Broken",
                context: context,
                audioDirectory: library
            )
        }
        #expect(try context.fetch(FetchDescriptor<Lesson>()).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    // MARK: - Adding a folder or several files (PLANS.md line 63)

    @Test func selectingAFolderCollectsItsAudioRecursively() throws {
        let working = try Self.makeWorkingDirectory("folder")
        let folder = working.appendingPathComponent("course", isDirectory: true)
        let nested = folder.appendingPathComponent("unit 2", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try Self.writeWAV(to: folder.appendingPathComponent("01-intro.wav"))
        _ = try Self.writeWAV(to: nested.appendingPathComponent("02-story.wav"))
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.wav"))

        let selection = AudioImportService.collectAudioFiles(from: [folder, notes])
        #expect(selection.audioFiles.map(\.lastPathComponent) == ["01-intro.wav", "02-story.wav"])
        #expect(selection.folderCount == 1)
        #expect(
            selection.skippedCount == 1,
            "a picked non-audio file is reported; notes and hidden files inside the folder are simply not offered"
        )
    }

    @Test func selectingSeveralFilesKeepsAudioAndSkipsTheRest() throws {
        let working = try Self.makeWorkingDirectory("multi")
        let first = try Self.writeWAV(to: working.appendingPathComponent("first.wav"))
        let second = try Self.writeWAV(to: working.appendingPathComponent("second.wav"))
        let notes = working.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)

        let selection = AudioImportService.collectAudioFiles(from: [first, notes, second, first])
        #expect(selection.audioFiles == [first, second], "duplicates are dropped")
        #expect(selection.folderCount == 0)
        #expect(selection.skippedCount == 1)
    }

    @Test func selectingAFolderWithoutAudioReportsNothingToAdd() throws {
        let working = try Self.makeWorkingDirectory("empty-folder")
        let folder = working.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let selection = AudioImportService.collectAudioFiles(from: [folder])
        #expect(selection.isEmpty)
        #expect(selection.folderCount == 1)
        #expect(selection.skippedCount == 1)
    }

    @Test func suggestedTitleAndAudioValidationFollowTheFile() {
        #expect(AudioImportService.suggestedTitle(for: URL(fileURLWithPath: "/tmp/Lesson_01.mp3")) == "Lesson 01")
        #expect(AudioImportService.suggestedTitle(for: URL(fileURLWithPath: "/tmp/  spaced  .m4a")) == "spaced")
        #expect(AudioImportService.suggestedTitle(for: URL(fileURLWithPath: "/tmp/Plain.wav")) == "Plain")
        #expect(AudioImportService.isAudioFile(URL(fileURLWithPath: "/tmp/Plain.MP3")))
        #expect(!AudioImportService.isAudioFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!AudioImportService.isAudioFile(URL(fileURLWithPath: "/tmp/no-extension")))
    }

    /// The whole folder flow: collect what the picker returned, then import it.
    @MainActor
    @Test func everyFileCollectedFromAFolderImports() async throws {
        let working = try Self.makeWorkingDirectory("folder-import")
        let library = try Self.makeLibrary(in: working)
        let folder = working.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try Self.writeWAV(to: folder.appendingPathComponent("Lesson_01.wav"))
        _ = try Self.writeWAV(to: folder.appendingPathComponent("Lesson_02.wav"))
        let context = try Self.makeContext()

        let selection = AudioImportService.collectAudioFiles(from: [folder])
        #expect(selection.audioFiles.count == 2)
        for url in selection.audioFiles {
            _ = try await AudioImportService.importAudio(
                from: url,
                title: AudioImportService.suggestedTitle(for: url),
                context: context,
                audioDirectory: library
            )
        }

        let lessons = try context.fetch(FetchDescriptor<Lesson>(sortBy: [SortDescriptor(\.title)]))
        #expect(lessons.map(\.title) == ["Lesson 01", "Lesson 02"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).count == 2)
    }

    // MARK: - Legacy web backup decoding (PLANS.md lines 38, 59)

    @Test func decodesLegacyWebBackup() throws {
        let json = """
        {"format":"still-listening-backup","version":1,"lessons":[{"id":"10000000-0000-0000-0000-000000000001","title":"Lesson","audioType":"audio/mpeg","fileName":"lesson.mp3","duration":12.5,"createdAt":"2025-01-01T00:00:00Z","lastPlayedAt":null,"lastPosition":4.25,"audioBase64":"AQID"}]}
        """.data(using: .utf8)!
        let backup = try BackupParser.decodeLegacyWebBackup(json)
        #expect(backup.format == "still-listening-backup")
        #expect(backup.version == 1)
        #expect(backup.lessons.first?.title == "Lesson")
        #expect(backup.lessons.first?.fileName == "lesson.mp3")
        #expect(backup.lessons.first?.duration == 12.5)
        #expect(backup.lessons.first?.lastPosition == 4.25)
        #expect(Data(base64Encoded: backup.lessons.first!.audioBase64) == Data([1, 2, 3]))
    }

    @MainActor
    @Test func importsALegacyWebBackupIntoTheLibrary() async throws {
        let working = try Self.makeWorkingDirectory("legacy")
        let library = try Self.makeLibrary(in: working)
        let fixture = try Self.writeWAV(to: working.appendingPathComponent("fixture.wav"))
        let base64 = try Data(contentsOf: fixture).base64EncodedString()
        let backup = try Self.writeLegacyBackup(Self.legacyJSON(audioBase64: base64, lastPosition: 0.5), in: working)
        let context = try Self.makeContext()

        let count = try await BackupService.restore(from: backup, context: context, audioDirectory: library)
        #expect(count == 1)
        let lessons = try context.fetch(FetchDescriptor<Lesson>())
        #expect(lessons.count == 1)
        #expect(lessons.first?.title == "Lesson")
        #expect(lessons.first?.id == Self.legacyID)
        #expect(abs((lessons.first?.lastPosition ?? -1) - 0.5) < 0.0001)
        #expect(lessons.first?.lastPlayedAt == nil)
        let audio = try AudioImportService.audioURL(for: lessons.first!, audioDirectory: library)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @MainActor
    @Test func legacyImportClampsAnOutOfRangePosition() async throws {
        let working = try Self.makeWorkingDirectory("legacy-clamp")
        let library = try Self.makeLibrary(in: working)
        let fixture = try Self.writeWAV(to: working.appendingPathComponent("fixture.wav"))
        let base64 = try Data(contentsOf: fixture).base64EncodedString()
        let backup = try Self.writeLegacyBackup(Self.legacyJSON(audioBase64: base64, lastPosition: 900), in: working)
        let context = try Self.makeContext()

        _ = try await BackupService.restore(from: backup, context: context, audioDirectory: library)
        let lesson = try #require(try context.fetch(FetchDescriptor<Lesson>()).first)
        #expect(lesson.lastPosition == lesson.duration)
    }

    @MainActor
    @Test func legacyImportLeavesTheLibraryIntactWhenRejected() async throws {
        let working = try Self.makeWorkingDirectory("legacy-reject")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()
        _ = try await AudioImportService.importAudio(
            from: try Self.writeWAV(to: working.appendingPathComponent("existing.wav")),
            title: "Existing",
            context: context,
            audioDirectory: library
        )
        let before = try context.fetch(FetchDescriptor<Lesson>()).count

        let badBackups: [(String, Data)] = [
            ("wrong format", Self.legacyJSON(audioBase64: "AQID", format: "other")),
            ("wrong version", Self.legacyJSON(audioBase64: "AQID", version: 2)),
            ("invalid base64", Self.legacyJSON(audioBase64: "!!!!")),
            ("empty audio", Self.legacyJSON(audioBase64: "")),
            ("blank title", Self.legacyJSON(audioBase64: "AQID", title: "   ")),
            ("zero duration", Self.legacyJSON(audioBase64: "AQID", duration: 0))
        ]
        for (label, data) in badBackups {
            let url = try Self.writeLegacyBackup(data, in: working)
            await #expect(throws: (any Error).self, "\(label) must be rejected") {
                _ = try await BackupService.restore(from: url, context: context, audioDirectory: library)
            }
            #expect(try context.fetch(FetchDescriptor<Lesson>()).count == before, "\(label) changed the library")
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).count == 1, "\(label) left audio behind")
        }
    }

    // MARK: - Native backup round trip (PLANS.md lines 36, 60)

    @MainActor
    @Test func nativeBackupRoundTripPreservesLessonAndAudio() async throws {
        let working = try Self.makeWorkingDirectory("round-trip")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()

        let original = try await AudioImportService.importAudio(
            from: try Self.writeWAV(to: working.appendingPathComponent("source.wav")),
            title: "Round trip",
            context: context,
            audioDirectory: library
        )
        original.lastPosition = 0.4
        try context.save()

        let archive = try await BackupService.makeBackup(lessons: [original], audioDirectory: library)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(BackupService.preview(of: archive)?.lessonCount == 1)
        #expect(BackupService.preview(of: archive)?.isLegacyWebBackup == false)

        // Empty the library so the exported archive is what is read back.
        for lesson in try context.fetch(FetchDescriptor<Lesson>()) { context.delete(lesson) }
        try context.save()
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let count = try await BackupService.restore(from: archive, context: context, audioDirectory: library)
        #expect(count == 1)
        let restored = try #require(try context.fetch(FetchDescriptor<Lesson>()).first)
        #expect(restored.id == original.id)
        #expect(restored.title == "Round trip")
        #expect(abs(restored.lastPosition - 0.4) < 0.01)
        #expect(restored.relativeAudioPath == original.relativeAudioPath)
        let audio = try AudioImportService.audioURL(for: restored, audioDirectory: library)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: - ID collisions (PLANS.md lines 37, 60)

    @MainActor
    @Test func restoreReassignsCollidingIDsWithoutOverwriting() async throws {
        let working = try Self.makeWorkingDirectory("collision")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()

        let existing = try await AudioImportService.importAudio(
            from: try Self.writeWAV(to: working.appendingPathComponent("existing.wav")),
            title: "Existing",
            context: context,
            audioDirectory: library
        )

        let staging = working.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let duplicate = try Self.writeWAV(to: staging.appendingPathComponent("duplicate.wav"))
        let staged = Self.stagedLesson(
            id: existing.id,
            title: "Duplicate",
            source: duplicate,
            relativeAudioPath: "\(existing.id.uuidString).wav"
        )

        let count = try BackupService.commit([staged], context: context, audioDirectory: library)
        #expect(count == 1)
        let lessons = try context.fetch(FetchDescriptor<Lesson>())
        #expect(lessons.count == 2, "the existing lesson is kept")
        #expect(lessons.contains { $0.id == existing.id && $0.title == "Existing" })
        let imported = try #require(lessons.first { $0.title == "Duplicate" })
        #expect(imported.id != existing.id, "the imported lesson got a new ID")
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(imported.relativeAudioPath).path))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent(existing.relativeAudioPath).path))
    }

    @Test func assignIDsKeepsImportedLessonsDistinct() throws {
        let working = try Self.makeWorkingDirectory("assign")
        let audio = try Self.writeWAV(to: working.appendingPathComponent("a.wav"))
        let shared = UUID()
        let staged = [
            Self.stagedLesson(id: shared, title: "One", source: audio),
            Self.stagedLesson(id: shared, title: "Two", source: audio)
        ]
        let assigned = BackupParser.assignIDs(staged, existingIDs: [])
        #expect(assigned.count == 2)
        #expect(assigned[0].id != assigned[1].id)
        #expect(assigned.map(\.title) == ["One", "Two"])

        let kept = BackupParser.assignIDs([Self.stagedLesson(id: staged[0].id, source: audio)], existingIDs: [])
        #expect(kept.first?.id == staged[0].id, "a non-colliding ID is kept")
    }

    // MARK: - Failure rollback (PLANS.md line 60)

    @MainActor
    @Test func commitRollsBackWhenAMoveFails() throws {
        let working = try Self.makeWorkingDirectory("rollback")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()

        let id = UUID()
        let source = try Self.writeWAV(to: working.appendingPathComponent("staged.wav"))
        let staged = Self.stagedLesson(id: id, source: source, relativeAudioPath: "\(id.uuidString).wav")

        // A read-only library directory makes the move fail, which must leave
        // no lesson behind and must not consume the staged file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.path) }

        #expect(throws: (any Error).self) { try BackupService.commit([staged], context: context, audioDirectory: library) }
        #expect(try context.fetch(FetchDescriptor<Lesson>()).isEmpty, "no lesson is inserted")
        #expect(FileManager.default.fileExists(atPath: source.path), "the staged file is untouched")
    }

    @MainActor
    @Test func commitRejectsAnEmptyRestore() throws {
        let context = try Self.makeContext()
        #expect(throws: BackupError.self) { try BackupService.commit([], context: context) }
    }

    // MARK: - Malformed and unsafe archives (PLANS.md line 60)

    @Test func audioPathSafetyRejectsTraversalAndSiblingPaths() {
        #expect(BackupParser.isSafeAudioPath("Audio/lesson.wav"))
        #expect(!BackupParser.isSafeAudioPath("../etc/passwd"))
        #expect(!BackupParser.isSafeAudioPath("/tmp/escape.wav"))
        #expect(!BackupParser.isSafeAudioPath("Audio/../escape.wav"))
        #expect(!BackupParser.isSafeAudioPath("Audio/a/b.wav"))
        #expect(!BackupParser.isSafeAudioPath("Other/lesson.wav"))
        #expect(!BackupParser.isSafeAudioPath("Audio/.."))
        #expect(!BackupParser.isSafeAudioPath(""))
        #expect(!BackupParser.isSafeAudioPath("Audio\\lesson.wav"))
    }

    @MainActor
    @Test func nativeRestoreRejectsUnsafeAndMalformedArchives() async throws {
        let working = try Self.makeWorkingDirectory("unsafe")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()
        let wav = try Data(contentsOf: try Self.writeWAV(to: working.appendingPathComponent("source.wav")))
        let id = UUID()
        let audioPath = "Audio/\(id.uuidString).wav"

        func expectRejected(_ label: String, _ entries: [(path: String, data: Data)]) async throws {
            let archive = try Self.makeArchive(entries: entries, in: working)
            await #expect(throws: (any Error).self, "\(label) must be rejected") {
                _ = try await BackupService.restore(from: archive, context: context, audioDirectory: library)
            }
            #expect(try context.fetch(FetchDescriptor<Lesson>()).isEmpty, "\(label) changed the library")
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty, "\(label) left audio behind")
        }

        try await expectRejected("missing manifest", [(audioPath, wav)])
        try await expectRejected("wrong format", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 1, 0)], format: "other")),
            (audioPath, wav)
        ])
        try await expectRejected("wrong version", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 1, 0)], version: 2)),
            (audioPath, wav)
        ])
        try await expectRejected("empty lessons", [
            ("manifest.json", Self.manifestData(lessons: [])),
            (audioPath, wav)
        ])
        try await expectRejected("traversal path", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", "../escape.wav", 1, 0)])),
            (audioPath, wav)
        ])
        try await expectRejected("absolute path", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", "/tmp/escape.wav", 1, 0)])),
            (audioPath, wav)
        ])
        try await expectRejected("missing audio entry", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", "Audio/missing.wav", 1, 0)]))
        ])
        try await expectRejected("duplicate IDs in one manifest", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 1, 0), (id, "y", audioPath, 1, 0)])),
            (audioPath, wav)
        ])
        try await expectRejected("blank title", [
            ("manifest.json", Self.manifestData(lessons: [(id, "   ", audioPath, 1, 0)])),
            (audioPath, wav)
        ])
        try await expectRejected("duration mismatch", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 30, 0)])),
            (audioPath, wav)
        ])
        try await expectRejected("non-audio payload", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 1, 0)])),
            (audioPath, Data("definitely not audio".utf8))
        ])
        try await expectRejected("garbage audio body", [
            ("manifest.json", Self.manifestData(lessons: [(id, "x", audioPath, 1, 0)])),
            (audioPath, Data(repeating: 0x00, count: 64))
        ])
    }

    @MainActor
    @Test func restoreRejectsAFileThatIsNotABackup() async throws {
        let working = try Self.makeWorkingDirectory("not-a-backup")
        let library = try Self.makeLibrary(in: working)
        let context = try Self.makeContext()
        let wav = try Self.writeWAV(to: working.appendingPathComponent("plain.wav"))

        #expect(BackupService.preview(of: wav) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await BackupService.restore(from: wav, context: context, audioDirectory: library)
        }
        #expect(try context.fetch(FetchDescriptor<Lesson>()).isEmpty)
    }

    @Test func manifestRoundTripsAllFields() throws {
        let id = UUID()
        let manifest = BackupManifest(
            format: BackupManifest.currentFormat,
            version: BackupManifest.currentVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lessons: [
                BackupLessonRecord(
                    id: id,
                    title: "Fields",
                    audioPath: "Audio/\(id.uuidString).wav",
                    audioType: "audio/wav",
                    duration: 1.5,
                    createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                    lastPlayedAt: nil,
                    lastPosition: 0.25
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try BackupParser.decodeManifest(try encoder.encode(manifest))
        #expect(decoded.format == BackupManifest.currentFormat)
        #expect(decoded.version == BackupManifest.currentVersion)
        #expect(decoded.lessons.count == 1)
        #expect(decoded.lessons[0].id == id)
        #expect(decoded.lessons[0].lastPlayedAt == nil)
        #expect(abs(decoded.lessons[0].lastPosition - 0.25) < 0.0001)
    }

    // MARK: - Saved position (PLANS.md lines 21, 62)

    @MainActor
    @Test func savedPositionFollowsTheActiveLesson() throws {
        let working = try Self.makeWorkingDirectory("position")
        let context = try Self.makeContext()
        let inactive = Lesson(
            title: "Inactive",
            relativeAudioPath: "\(UUID().uuidString).wav",
            audioType: "audio/wav",
            duration: 10
        )
        context.insert(inactive)
        try context.save()

        let (controller, lesson) = try loadFixture(in: working, duration: 10)
        try controller.updateSavedPosition(inactive, context: context)
        #expect(inactive.lastPosition == 0, "a lesson that is not loaded is not updated")
        #expect(controller.activeLessonID == lesson.id)

        controller.play()
        controller.seek(to: 6)
        try controller.updateSavedPosition(lesson, context: context)
        controller.pause()
        #expect(lesson.lastPosition == 6)
        #expect(lesson.lastPlayedAt != nil, "played time is recorded once playback happens")
    }

    // MARK: - Helpers

    /// Loads a generated audio fixture into a playback controller.
    @MainActor
    private func loadFixture(in working: URL, duration: Double) throws -> (AudioPlaybackController, Lesson) {
        let fixture = try Self.writeWAV(to: working.appendingPathComponent("fixture.wav"), duration: duration)
        let data = try Data(contentsOf: fixture)
        let root = working.appendingPathComponent("Application Support/Still/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).wav"
        try data.write(to: root.appendingPathComponent(name))
        let lesson = Lesson(
            title: "Fixture",
            relativeAudioPath: name,
            audioType: "audio/wav",
            duration: duration
        )
        let controller = AudioPlaybackController()
        try controller.load(lesson, audioDirectory: root)
        return (controller, lesson)
    }
}
