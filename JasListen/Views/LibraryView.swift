import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    /// What the detail pane is showing. A lesson opens the player; a playlist
    /// opens its running order.
    private enum SidebarSelection: Hashable {
        case lesson(UUID)
        case playlist(UUID)
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Lesson.createdAt, order: .reverse) private var lessons: [Lesson]
    @Query(sort: \Playlist.name) private var playlists: [Playlist]
    @StateObject private var playback = AudioPlaybackController()
    @State private var selection: SidebarSelection?
    @State private var playbackQueue: [Lesson] = []
    @State private var playbackQueuePlaylistID: UUID?
    @State private var showingImporter = false
    @State private var showingBackupExporter = false
    @State private var backupDocument: BackupDocument?
    @State private var showingTitlePrompt = false
    @State private var showingRenamePrompt = false
    @State private var renamingLessonID: UUID?
    @State private var renameTitle = ""
    @State private var pendingAudioURL: URL?
    @State private var newLessonTitle = ""
    @State private var showingDeleteConfirmation = false
    @State private var lessonToDelete: Lesson?
    @State private var alertMessage: String?
    @State private var backupAlert: BackupAlert?
    @State private var pendingBackupURL: URL?
    @State private var isExportingBackup = false
    @State private var isImportingAudio = false
    @State private var importProgress: String?
    @State private var isDropTargeted = false
    @State private var showingNewPlaylistPrompt = false
    @State private var newPlaylistName = ""
    @State private var showingPlaylistRename = false
    @State private var renamingPlaylistID: UUID?
    @State private var playlistRenameName = ""
    @State private var showingPlaylistDeleteConfirmation = false
    @State private var playlistToDelete: Playlist?
    /// Set while the audio picker was opened from a playlist, so whatever is
    /// imported is placed in that playlist instead of only in the library.
    @State private var importTargetPlaylistID: UUID?

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    private var selectedLesson: Lesson? {
        guard case .lesson(let id) = selection else { return nil }
        return lessons.first(where: { $0.id == id })
    }

    private var selectedPlaylist: Playlist? {
        guard case .playlist(let id) = selection else { return nil }
        return playlists.first(where: { $0.id == id })
    }

    private var playbackQueueTitle: String {
        guard let id = playbackQueuePlaylistID,
              let playlist = playlists.first(where: { $0.id == id }) else { return "Library" }
        return playlist.name
    }

    private var playlistRepository: SwiftDataPlaylistRepository {
        SwiftDataPlaylistRepository(context: context)
    }

    /// macOS adds audio through `NSOpenPanel`, which can offer files, folders,
    /// and multiple selection in one panel; its importer is left to backups.
    /// iOS has no equivalent panel, so one importer covers every source.
    private var importerContentTypes: [UTType] {
        #if os(macOS)
        [.stillBackup, .json, .zip]
        #else
        [.audio, .folder, .stillBackup, .json, .zip]
        #endif
    }

    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            if let lesson = selectedLesson {
                PlayerDetailView(
                    lesson: lesson,
                    playback: playback,
                    queue: playbackQueue,
                    queueTitle: playbackQueueTitle,
                    onSelectQueueLesson: playFromQueue
                )
                    .id(lesson.id)
            } else if let playlist = selectedPlaylist {
                PlaylistDetailView(
                    playlist: playlist,
                    libraryLessons: lessons,
                    activeLessonID: playback.activeLessonID,
                    onPlay: { play($0, in: playlist, orderedLessons: $1) },
                    onAddAudio: { beginAudioImport(into: playlist) },
                    onRename: { beginRename(playlist) },
                    onDelete: { confirmDelete(playlist) }
                )
                .id(playlist.id)
            } else {
                emptyDetail
            }
        }
        .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
        // A single importer drives backup restore and, on iOS, audio too: two
        // `.fileImporter` modifiers on one view make macOS drop the presentation
        // entirely, so the picker never appears.
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importerContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handlePickerResult
        )
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .stillBackup, defaultFilename: "JasListen-Backup", onCompletion: handleBackupExporter)
        .alert("JasListen", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(item: $backupAlert) { alert in
            Alert(
                title: Text("Restore backup?"),
                message: Text(alert.message),
                primaryButton: .default(Text("Restore")) { applyPendingBackup() },
                secondaryButton: .cancel { cancelPendingBackup() }
            )
        }
        .onOpenURL(perform: openBackup(at:))
        .task(id: playback.errorMessage) {
            guard let error = playback.errorMessage else { return }
            alertMessage = error
            playback.clearError()
        }
        .alert("Rename lesson", isPresented: $showingRenamePrompt) {
            TextField("Lesson title", text: $renameTitle)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renamingLessonID = nil }
        } message: {
            Text("Choose a title for this audio.")
        }
        .confirmationDialog("Remove this lesson and its audio?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove Lesson", role: .destructive) { deleteLesson() }
            Button("Cancel", role: .cancel) { lessonToDelete = nil }
        }
        .alert("New playlist", isPresented: $showingNewPlaylistPrompt) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") { createPlaylist() }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Name a playlist, then add audio files or lessons from your library.")
        }
        .alert("Rename playlist", isPresented: $showingPlaylistRename) {
            TextField("Playlist name", text: $playlistRenameName)
            Button("Save") { savePlaylistRename() }
            Button("Cancel", role: .cancel) { renamingPlaylistID = nil }
        } message: {
            Text("Choose a name for this playlist.")
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showingPlaylistDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { deletePlaylist() }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            Text("The audio stays in your library; only the playlist is removed.")
        }
        .task {
            if selection == nil, let first = lessons.first { select(first) }
        }
        .onChange(of: lessons.map(\.id)) { _, ids in
            // A lesson can disappear (removed, or restored elsewhere); fall back
            // to the first one so the detail pane never points at nothing.
            if case .lesson(let id) = selection, !ids.contains(id) {
                selection = ids.first.map(SidebarSelection.lesson)
            } else if selection == nil, let id = ids.first {
                selection = .lesson(id)
            }
        }
        .onChange(of: playlists.map(\.id)) { _, ids in
            if case .playlist(let id) = selection, !ids.contains(id) { selection = nil }
        }
        .onChange(of: playback.completionCount) { _, _ in advancePlaybackQueue() }
        .onChange(of: showingTitlePrompt) { _, isShowing in
            if isShowing { return }
            pendingAudioURL = nil
            importTargetPlaylistID = nil
        }
        .sheet(isPresented: $showingTitlePrompt) {
            titlePrompt
                .presentationDetents([.height(270)])
                .presentationDragIndicator(.visible)
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("JasListen")
                Text("JasListen")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-1.4)
                Spacer()
                addAudioButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 19)
            .padding(.bottom, 22)

            if let importProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(importProgress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
            }

            List(selection: $selection) {
                Section {
                    ForEach(lessons) { lesson in
                        LessonRow(lesson: lesson)
                            .tag(SidebarSelection.lesson(lesson.id))
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { rename(lesson) }
                                addToPlaylistMenu(for: lesson)
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    lessonToDelete = lesson
                                    showingDeleteConfirmation = true
                                }
                            }
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first, lessons.indices.contains(index) else { return }
                        lessonToDelete = lessons[index]
                        showingDeleteConfirmation = true
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("YOUR LIBRARY")
                        Spacer()
                        Text("\(lessons.count)")
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                }

                Section {
                    ForEach(playlists) { playlist in
                        PlaylistRow(playlist: playlist)
                            .tag(SidebarSelection.playlist(playlist.id))
                            .contextMenu {
                                Button("Rename Playlist…", systemImage: "pencil") { beginRename(playlist) }
                                Button("Add Audio Files…", systemImage: "music.note.list") { beginAudioImport(into: playlist) }
                                Button("Add from Library…", systemImage: "text.badge.plus") { select(playlist) }
                                Divider()
                                Button("Delete Playlist", systemImage: "trash", role: .destructive) { confirmDelete(playlist) }
                            }
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first, playlists.indices.contains(index) else { return }
                        confirmDelete(playlists[index])
                    }

                    Button { beginNewPlaylist() } label: {
                        Label("New Playlist", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(red: 0.15, green: 0.39, blue: 0.32))
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("PLAYLISTS")
                        Spacer()
                        Text("\(playlists.count)")
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, newValue in handleSidebarSelection(newValue) }

            Divider()
            HStack(spacing: 14) {
                Menu {
                    Button("Export backup…", systemImage: "square.and.arrow.up") { exportBackup() }
                        .disabled(isExportingBackup || lessons.isEmpty)
                    Button("Restore backup…", systemImage: "square.and.arrow.down") { showingImporter = true }
                } label: {
                    HStack(spacing: 6) {
                        if isExportingBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "externaldrive")
                        }
                        Text(isExportingBackup ? "Preparing backup…" : "Backups")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(isExportingBackup)
                Spacer()
                Label("On this device", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("Lessons are stored locally. Use backups to transfer them between Apple devices.")
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 13)
        }
        .background(.background)
        // Dropping files or a folder from the Finder (or Files) adds them, which
        // is the quickest way to bring in a whole course folder on the Mac.
        .dropDestination(for: URL.self) { urls, _ in
            addSources(urls)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(red: 0.15, green: 0.39, blue: 0.32), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(7)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var addAudioButton: some View {
        #if os(macOS)
        Menu {
            Button("Add Audio Files…", systemImage: "music.note.list") { presentAudioPicker(allowingFolders: false) }
            Button("Add Folder…", systemImage: "folder") { presentAudioPicker(allowingFolders: true) }
            Divider()
            Button("Restore Backup…", systemImage: "square.and.arrow.down") { showingImporter = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(red: 0.15, green: 0.39, blue: 0.32), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isImportingAudio)
        .help("Add audio files, a folder of audio, or restore a backup")
        .accessibilityLabel("Add audio files or a folder")
        #else
        Button { showingImporter = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
        .disabled(isImportingAudio)
        .accessibilityLabel("Add audio lesson")
        #endif
    }

    private var emptyDetail: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color(red: 0.47, green: 0.59, blue: 0.47))
            Text("Make room for every word.")
                .font(.system(size: 25, weight: .medium, design: .serif))
            Text("Add an MP3, several files, or a folder of audio to begin.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Add audio lesson", systemImage: "plus") { presentAudioPicker(allowingFolders: true) }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
                .disabled(isImportingAudio)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var titlePrompt: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Name this lesson")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            TextField("Lesson title", text: $newLessonTitle)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) { showingTitlePrompt = false }
                Spacer()
                Button("Add lesson") { importPendingAudio() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
                    .disabled(newLessonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): addSources(urls)
        case .failure(let error):
            importTargetPlaylistID = nil
            alertMessage = "Could not open the selected file: \(error.localizedDescription)"
        }
    }

    /// Adds whatever a picker, a drop, or the Mac panel handed over.
    ///
    /// A single file that is not audio and not a folder is treated as a backup,
    /// which keeps "open a backup" and "add audio" on the same picker. Anything
    /// else is expanded into audio files.
    private func addSources(_ urls: [URL]) {
        guard !urls.isEmpty, !isImportingAudio else { return }
        let selection = AudioImportService.collectAudioFiles(from: urls)
        if selection.isEmpty, selection.folderCount == 0, urls.count == 1 {
            openBackup(at: urls[0])
            return
        }
        addAudio(selection)
    }

    private func addAudio(_ selection: AudioImportSelection) {
        guard !selection.isEmpty else {
            importTargetPlaylistID = nil
            alertMessage = "No audio files were found in that selection. Supported audio includes MP3, M4A, WAV, and AIFF."
            return
        }
        // Naming stays available when one file was chosen; a batch is named from
        // each file name so nothing has to be typed over and over.
        if selection.audioFiles.count == 1, selection.folderCount == 0, selection.skippedCount == 0 {
            beginSingleImport(selection.audioFiles[0])
            return
        }
        importInBatch(selection)
    }

    private func beginSingleImport(_ url: URL) {
        pendingAudioURL = url
        newLessonTitle = AudioImportService.suggestedTitle(for: url)
        showingTitlePrompt = true
    }

    /// Imports many files one at a time, keeping the lessons that succeed when a
    /// single file cannot be read, and reports what happened at the end.
    private func importInBatch(_ audioSelection: AudioImportSelection) {
        guard !isImportingAudio else { return }
        isImportingAudio = true
        let urls = audioSelection.audioFiles
        let skipped = audioSelection.skippedCount
        Task {
            var imported: [Lesson] = []
            var failures = 0
            for (index, url) in urls.enumerated() {
                importProgress = "Adding \(index + 1) of \(urls.count)…"
                do {
                    let lesson = try await AudioImportService.importAudio(
                        from: url,
                        title: AudioImportService.suggestedTitle(for: url),
                        context: context
                    )
                    imported.append(lesson)
                } catch {
                    failures += 1
                }
            }
            isImportingAudio = false
            importProgress = nil
            if let last = imported.last {
                if let targetID = importTargetPlaylistID,
                   let playlist = playlists.first(where: { $0.id == targetID }) {
                    do { try playlistRepository.add(imported, to: playlist) }
                    catch { alertMessage = "Audio was imported but could not be added to the playlist: \(error.localizedDescription)" }
                    importTargetPlaylistID = nil
                    selection = .playlist(targetID)
                    playbackQueue = playlist.orderedLessons
                    playbackQueuePlaylistID = targetID
                } else {
                    selection = .lesson(last.id)
                    playbackQueue = lessons + imported.filter { lesson in !lessons.contains(where: { $0.id == lesson.id }) }
                    playbackQueuePlaylistID = nil
                    load(last)
                }
            }
            importTargetPlaylistID = nil
            alertMessage = importSummary(imported: imported.count, failures: failures, skipped: skipped)
        }
    }

    private func importSummary(imported: Int, failures: Int, skipped: Int) -> String {
        var parts = ["Added \(imported) lesson\(imported == 1 ? "" : "s")."]
        if failures > 0 {
            parts.append("\(failures) file\(failures == 1 ? "" : "s") could not be read.")
        }
        if skipped > 0 {
            parts.append("\(skipped) item\(skipped == 1 ? "" : "s") that were not audio or held no audio were skipped.")
        }
        return parts.joined(separator: " ")
    }

    /// macOS picks audio with `NSOpenPanel`, which offers files, folders, and
    /// multiple selection in one panel. iOS keeps using the shared importer.
    private func presentAudioPicker(allowingFolders: Bool) {
        #if os(macOS)
        addSources(AudioImportPicker.chooseAudioSources(allowingFolders: allowingFolders))
        #else
        _ = allowingFolders
        showingImporter = true
        #endif
    }

    private func importPendingAudio() {
        guard let url = pendingAudioURL else { return }
        let title = newLessonTitle
        Task {
            do {
                let lesson = try await AudioImportService.importAudio(from: url, title: title, context: context)
                if let targetID = importTargetPlaylistID,
                   let playlist = playlists.first(where: { $0.id == targetID }) {
                    try playlistRepository.add([lesson], to: playlist)
                    importTargetPlaylistID = nil
                    selection = .playlist(targetID)
                    playbackQueue = playlist.orderedLessons
                    playbackQueuePlaylistID = targetID
                } else {
                    selection = .lesson(lesson.id)
                    playbackQueue = lessons + [lesson]
                    playbackQueuePlaylistID = nil
                    load(lesson)
                }
                showingTitlePrompt = false
            } catch {
                alertMessage = "Could not import this audio. Your existing lessons were left unchanged. \(error.localizedDescription)"
                importTargetPlaylistID = nil
                showingTitlePrompt = false
            }
        }
    }

    private func select(_ lesson: Lesson) {
        selection = .lesson(lesson.id)
    }

    private func handleSidebarSelection(_ newValue: SidebarSelection?) {
        switch newValue {
        case .lesson(let id):
            if playbackQueuePlaylistID == nil || !playbackQueue.contains(where: { $0.id == id }) {
                playbackQueuePlaylistID = nil
                playbackQueue = lessons
            }
            guard let lesson = lessons.first(where: { $0.id == id }), playback.activeLessonID != id else { return }
            load(lesson)
        case .playlist, nil:
            if newValue == nil {
                playbackQueue = []
                playbackQueuePlaylistID = nil
            }
        }
    }

    private func select(_ playlist: Playlist) {
        selection = .playlist(playlist.id)
        playbackQueue = playlist.orderedLessons
        playbackQueuePlaylistID = playlist.id
    }

    private func play(_ lesson: Lesson, in playlist: Playlist, orderedLessons: [Lesson]) {
        playbackQueue = orderedLessons
        playbackQueuePlaylistID = playlist.id
        selection = .lesson(lesson.id)
        playback.play(lesson, context: context)
    }

    private func playFromQueue(_ lesson: Lesson) {
        selection = .lesson(lesson.id)
        playback.play(lesson, context: context)
    }

    private func advancePlaybackQueue() {
        guard let completedID = playback.activeLessonID,
              let completedLesson = lessons.first(where: { $0.id == completedID }),
              let nextID = PlaybackQueue.nextID(after: completedID, in: playbackQueue.map(\.id)),
              let nextLesson = playbackQueue.first(where: { $0.id == nextID }) else { return }
        completedLesson.lastPosition = 0
        try? context.save()
        selection = .lesson(nextLesson.id)
        playback.play(nextLesson, context: context)
    }

    private func load(_ lesson: Lesson) {
        do {
                if playback.activeLessonID != lesson.id,
                    let activeID = playback.activeLessonID,
               let previousLesson = lessons.first(where: { $0.id == activeID }) {
                try playback.updateSavedPosition(previousLesson, context: context)
            }
            try playback.load(lesson)
        } catch {
            alertMessage = "Could not open this lesson. \(error.localizedDescription)"
        }
    }

    private func rename(_ lesson: Lesson) {
        renamingLessonID = lesson.id
        renameTitle = lesson.title
        showingRenamePrompt = true
    }

    private func saveRename() {
        guard let id = renamingLessonID, let lesson = lessons.first(where: { $0.id == id }) else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        lesson.title = title
        if case .lesson(let id) = selection, id == lesson.id { playback.setTitle(title) }
        do { try context.save() }
        catch { alertMessage = "Could not save this title: \(error.localizedDescription)" }
        renamingLessonID = nil
    }

    private func deleteLesson() {
        guard let lesson = lessonToDelete else { return }
        do {
            if playback.activeLessonID == lesson.id {
                try playback.updateSavedPosition(lesson, context: context)
                playback.stop()
                selection = nil
            }
            try SwiftDataLessonRepository(context: context).remove(lesson)
            let file = try AudioImportService.audioURL(for: lesson)
            try? FileManager.default.removeItem(at: file)
            lessonToDelete = nil
        } catch {
            alertMessage = "Could not remove the lesson: \(error.localizedDescription)"
        }
    }

    private func beginNewPlaylist() {
        newPlaylistName = ""
        showingNewPlaylistPrompt = true
    }

    private func createPlaylist() {
        do {
            let playlist = try playlistRepository.create(named: newPlaylistName)
            selection = .playlist(playlist.id)
            newPlaylistName = ""
        } catch { alertMessage = error.localizedDescription }
    }

    private func beginRename(_ playlist: Playlist) {
        renamingPlaylistID = playlist.id
        playlistRenameName = playlist.name
        showingPlaylistRename = true
    }

    private func savePlaylistRename() {
        guard let id = renamingPlaylistID,
              let playlist = playlists.first(where: { $0.id == id }) else { return }
        do {
            try playlistRepository.rename(playlist, to: playlistRenameName)
            renamingPlaylistID = nil
        } catch { alertMessage = error.localizedDescription }
    }

    private func confirmDelete(_ playlist: Playlist) {
        playlistToDelete = playlist
        showingPlaylistDeleteConfirmation = true
    }

    private func deletePlaylist() {
        guard let playlist = playlistToDelete else { return }
        do {
            try playlistRepository.remove(playlist)
            if case .playlist(let id) = selection, id == playlist.id { selection = nil }
            playlistToDelete = nil
        } catch { alertMessage = "Could not delete this playlist: \(error.localizedDescription)" }
    }

    private func beginAudioImport(into playlist: Playlist) {
        importTargetPlaylistID = playlist.id
        presentAudioPicker(allowingFolders: true)
    }

    @ViewBuilder
    private func addToPlaylistMenu(for lesson: Lesson) -> some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            if playlists.isEmpty {
                Button("Create Playlist…") { beginNewPlaylist() }
            } else {
                ForEach(playlists) { playlist in
                    Button(playlist.name) {
                        do { try playlistRepository.add([lesson], to: playlist) }
                        catch { alertMessage = "Could not add the lesson: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private func exportBackup() {
        guard !isExportingBackup else { return }
        isExportingBackup = true
        Task {
            defer { isExportingBackup = false }
            do {
                let url = try await BackupService.makeBackup(lessons: lessons)
                backupDocument = BackupDocument(backupURL: url)
                showingBackupExporter = true
            } catch {
                alertMessage = "Could not create the backup: \(error.localizedDescription)"
            }
        }
    }

    private func handleBackupExporter(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            alertMessage = "Could not export the backup: \(error.localizedDescription)"
        }
        if let url = backupDocument?.stagedURL { try? FileManager.default.removeItem(at: url) }
        backupDocument = nil
    }

    /// Identifies a selected or opened backup and asks for confirmation before
    /// anything is written to the library.
    private func openBackup(at url: URL) {
        importTargetPlaylistID = nil
        if let preview = BackupService.preview(of: url) {
            pendingBackupURL = url
            let count = preview.lessonCount
            let description = preview.isLegacyWebBackup ? "web backup from the original player" : "JasListen backup"
            backupAlert = BackupAlert(
                message: "This \(description) contains \(count) lesson\(count == 1 ? "" : "s"). Existing lessons are kept and conflicting IDs are reassigned."
            )
            return
        }
        if pendingBackupURL != nil {
            cancelPendingBackup()
        }
        alertMessage = "This file is not a JasListen backup, or it is damaged. Your library was not changed."
    }

    private func applyPendingBackup() {
        guard pendingBackupURL != nil else { return }
        Task { await runPendingBackup() }
    }

    /// Copies the backup into temporary storage before restoring so the file
    /// does not have to stay reachable through its security scope.
    private func preparePendingBackup() -> URL? {
        guard let url = pendingBackupURL else { return nil }
        pendingBackupURL = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if !url.isFileURL || url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { return url }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("JasListenPending-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: staging)
            return staging
        } catch {
            alertMessage = "Could not read the backup file: \(error.localizedDescription)"
            return nil
        }
    }

    private func runPendingBackup() async {
        guard let url = preparePendingBackup() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let count = try await BackupService.restore(from: url, context: context)
            alertMessage = "Restored \(count) lesson\(count == 1 ? "" : "s"). Existing lessons were kept."
        } catch {
            alertMessage = "Backup restore failed. Your library was not changed. \(error.localizedDescription)"
        }
    }

    private func cancelPendingBackup() {
        pendingBackupURL = nil
        backupAlert = nil
    }
}

#if os(macOS)
/// The macOS audio picker.
///
/// `NSOpenPanel` is used instead of `fileImporter` because one panel can offer
/// audio files, folders, and multiple selection together, and it tells the
/// person what the Add button will accept.
private enum AudioImportPicker {
    /// Shows the panel and returns the chosen files and folders, or an empty
    /// array when it is cancelled.
    @MainActor
    static func chooseAudioSources(allowingFolders: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowingFolders
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = allowingFolders ? [.audio, .folder] : [.audio]
        panel.message = allowingFolders
            ? "Choose audio files, one or more folders of audio, or both."
            : "Choose one or more audio files. Shift-click or drag to select several."
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
#endif

private struct LessonRow: View {
    let lesson: Lesson

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.43, blue: 0.33))
                .frame(width: 35, height: 38)
                .background(Color(red: 0.91, green: 0.93, blue: 0.85), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(lesson.lastPlayedAt?.formatted(date: .abbreviated, time: .omitted) ?? "New lesson")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(formatDuration(lesson.duration))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .tag(lesson.id)
    }

    private func formatDuration(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.43, blue: 0.33))
                .frame(width: 35, height: 38)
                .background(Color(red: 0.91, green: 0.93, blue: 0.85), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(playlist.orderedItems.count) lessons")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }
}
