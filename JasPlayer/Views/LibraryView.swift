import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Lesson.createdAt, order: .reverse) private var lessons: [Lesson]
    @StateObject private var playback = AudioPlaybackController()
    @State private var selectedLessonID: UUID?
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

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    private var selectedLesson: Lesson? {
        lessons.first(where: { $0.id == selectedLessonID })
    }

    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            if let lesson = selectedLesson {
                PlayerDetailView(lesson: lesson, playback: playback)
                    .id(lesson.id)
            } else {
                emptyDetail
            }
        }
        .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
        // A single importer drives both flows: two `.fileImporter` modifiers on
        // one view make macOS drop the presentation entirely, so the picker
        // never appears.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio, .stillBackup, .json, .zip]) { result in
            let url: URL
            switch result {
            case .success(let selected): url = selected
            case .failure(let error):
                alertMessage = "Could not open the selected file: \(error.localizedDescription)"
                return
            }
            let ext = url.pathExtension.lowercased()
            let audioTypes = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "m4b"]
            if audioTypes.contains(ext) || (UTType(filenameExtension: ext)?.conforms(to: .audio) ?? false) {
                handleAudioImport(.success([url]))
            } else {
                openBackup(at: url)
            }
        }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument, contentType: .stillBackup, defaultFilename: "JasPlayer-Backup", onCompletion: handleBackupExporter)
        .alert("JasPlayer", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
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
        .task {
            if selectedLessonID == nil, let first = lessons.first { select(first) }
        }
        .onChange(of: lessons.map(\.id)) { _, ids in
            if selectedLessonID == nil, let id = ids.first { selectedLessonID = id }
        }
        .onChange(of: showingTitlePrompt) { _, isShowing in
            if isShowing { return }
            pendingAudioURL = nil
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
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color(red: 0.84, green: 0.9, blue: 0.48), Color(red: 0.12, green: 0.33, blue: 0.28))
                Text("JasPlayer")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-1.4)
                Spacer()
                Button { showingImporter = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
                .accessibilityLabel("Add audio lesson")
            }
            .padding(.horizontal, 18)
            .padding(.top, 19)
            .padding(.bottom, 22)

            HStack(alignment: .firstTextBaseline) {
                Text("YOUR LIBRARY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(lessons.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            List(selection: $selectedLessonID) {
                ForEach(lessons) { lesson in
                    LessonRow(lesson: lesson)
                        .tag(lesson.id)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { rename(lesson) }
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
            }
            .listStyle(.sidebar)
            .onChange(of: selectedLessonID) { _, id in
                guard let id, let lesson = lessons.first(where: { $0.id == id }) else { return }
                load(lesson)
            }

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
        .background(Color(red: 0.985, green: 0.982, blue: 0.96))
    }

    private var emptyDetail: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color(red: 0.47, green: 0.59, blue: 0.47))
            Text("Make room for every word.")
                .font(.system(size: 25, weight: .medium, design: .serif))
            Text("Add an MP3 or another audio file to begin.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Add audio lesson", systemImage: "plus") { showingImporter = true }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.97, green: 0.97, blue: 0.94))
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

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingAudioURL = url
            newLessonTitle = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            showingTitlePrompt = true
        case .failure(let error):
            alertMessage = "Could not open the selected audio: \(error.localizedDescription)"
        }
    }

    private func importPendingAudio() {
        guard let url = pendingAudioURL else { return }
        let title = newLessonTitle
        Task {
            do {
                let lesson = try await AudioImportService.importAudio(from: url, title: title, context: context)
                selectedLessonID = lesson.id
                load(lesson)
                showingTitlePrompt = false
            } catch {
                alertMessage = "Could not import this audio. Your existing lessons were left unchanged. \(error.localizedDescription)"
                showingTitlePrompt = false
            }
        }
    }

    private func select(_ lesson: Lesson) {
        selectedLessonID = lesson.id
    }

    private func load(_ lesson: Lesson) {
        do {
            if let activeID = playback.activeLessonID,
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
        if selectedLessonID == lesson.id { playback.setTitle(title) }
        do { try context.save() }
        catch { alertMessage = "Could not save this title: \(error.localizedDescription)" }
        renamingLessonID = nil
    }

    private func deleteLesson() {
        guard let lesson = lessonToDelete else { return }
        do {
            if selectedLessonID == lesson.id {
                try playback.updateSavedPosition(lesson, context: context)
                playback.stop()
                selectedLessonID = nil
            }
            try SwiftDataLessonRepository(context: context).remove(lesson)
            let file = try AudioImportService.audioURL(for: lesson)
            try? FileManager.default.removeItem(at: file)
            lessonToDelete = nil
        } catch {
            alertMessage = "Could not remove the lesson: \(error.localizedDescription)"
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
        if let preview = BackupService.preview(of: url) {
            pendingBackupURL = url
            let count = preview.lessonCount
            let description = preview.isLegacyWebBackup ? "web backup from the original player" : "JasPlayer backup"
            backupAlert = BackupAlert(
                message: "This \(description) contains \(count) lesson\(count == 1 ? "" : "s"). Existing lessons are kept and conflicting IDs are reassigned."
            )
            return
        }
        if pendingBackupURL != nil {
            cancelPendingBackup()
        }
        alertMessage = "This file is not a JasPlayer backup, or it is damaged. Your library was not changed."
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
            .appendingPathComponent("JasPlayerPending-\(UUID().uuidString).\(url.pathExtension)")
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
