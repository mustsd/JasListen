import SwiftData
import SwiftUI

/// One playlist in the sidebar.
///
/// Renaming, deleting, adding audio, and dropping back to the library all stay
/// with `LibraryView`, so there is one place that owns those alerts; this view
/// only presents the running order and reorders it.
struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var context

    let playlist: Playlist
    let libraryLessons: [Lesson]
    let activeLessonID: UUID?
    let onPlay: (Lesson, [Lesson]) -> Void
    let onAddAudio: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var showingAddExisting = false
    @State private var pendingLessonIDs: Set<UUID> = []
    @State private var alertMessage: String?
    @State private var sortOrder: PlaylistSortOrder = .name

    private var repository: SwiftDataPlaylistRepository {
        SwiftDataPlaylistRepository(context: context)
    }

    private var items: [PlaylistItem] {
        PlaylistOrdering.sorted(playlist.orderedItems, by: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentPadding)
                .padding(.top, contentPadding)
                .padding(.bottom, contentPadding - 8)

            Divider()

            if items.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .sheet(isPresented: $showingAddExisting, onDismiss: { pendingLessonIDs = [] }) {
            addExistingSheet
        }
        .alert("Playlist", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var contentPadding: CGFloat {
        #if os(iOS)
        18
        #else
        28
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("PLAYLIST")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(Color(red: 0.52, green: 0.59, blue: 0.53))
                Spacer()
                Picker("Sort playlist", selection: $sortOrder) {
                    ForEach(PlaylistSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
                #if os(iOS)
                EditButton()
                    .font(.system(size: 12, weight: .medium))
                    .disabled(sortOrder != .manual)
                #endif
            }

            Text(playlist.name)
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .tracking(-1.0)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)

            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            actions
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleSize: CGFloat {
        #if os(iOS)
        26
        #else
        31
        #endif
    }

    private var summary: String {
        let count = items.count
        let lessons = "\(count) lesson\(count == 1 ? "" : "s")"
        let total = items.reduce(0.0) { $0 + ($1.lesson?.duration ?? 0) }
        guard total > 0 else { return "\(lessons) · Empty playlist" }
        return "\(lessons) · \(formatDuration(total)) total"
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Add Audio Files…", systemImage: "plus") { onAddAudio() }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.15, green: 0.39, blue: 0.32))

            Button("Add from Library…", systemImage: "text.badge.plus") { showingAddExisting = true }
                .buttonStyle(.bordered)

            Spacer(minLength: 0)

            Menu {
                Button("Rename Playlist…", systemImage: "pencil") { onRename() }
                Button("Add Audio Files…", systemImage: "music.note.list") { onAddAudio() }
                Button("Add from Library…", systemImage: "text.badge.plus") { showingAddExisting = true }
                Divider()
                Button("Delete Playlist", systemImage: "trash", role: .destructive) { onDelete() }
            } label: {
                Label("Playlist actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rename, add lessons, or delete this playlist")
        }
    }

    // MARK: - Running order

    private var itemList: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let lesson = item.lesson {
                    PlaylistItemRow(
                        position: index + 1,
                        lesson: lesson,
                        isPlaying: activeLessonID == lesson.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onPlay(lesson, items.compactMap(\.lesson)) }
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") { onPlay(lesson, items.compactMap(\.lesson)) }
                        Divider()
                        Button("Move to Top", systemImage: "arrow.up.to.line") { move(item, to: 0) }
                            .disabled(sortOrder != .manual || index == 0)
                        Button("Move Up", systemImage: "arrow.up") { move(item, to: index - 1) }
                            .disabled(sortOrder != .manual || index == 0)
                        Button("Move Down", systemImage: "arrow.down") { move(item, to: index + 2) }
                            .disabled(sortOrder != .manual || index >= items.count - 1)
                        Button("Move to Bottom", systemImage: "arrow.down.to.line") { move(item, to: items.count) }
                            .disabled(sortOrder != .manual || index >= items.count - 1)
                        Divider()
                        Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                            remove([item])
                        }
                    }
                }
            }
            .onMove { offsets, destination in
                guard sortOrder == .manual else { return }
                do {
                    try repository.move(from: offsets, to: destination, in: playlist)
                } catch {
                    alertMessage = "Could not reorder the playlist: \(error.localizedDescription)"
                }
            }
            .onDelete { offsets in
                remove(offsets.compactMap { items.indices.contains($0) ? items[$0] : nil })
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(red: 0.47, green: 0.59, blue: 0.47))
            Text("This playlist is empty.")
                .font(.system(size: 19, weight: .medium, design: .serif))
            Text("Add audio files from this device, or bring in lessons you already imported.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Add Audio Files…", systemImage: "plus") { onAddAudio() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
                Button("Add from Library…", systemImage: "text.badge.plus") { showingAddExisting = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Add existing lessons

    private var addExistingSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add from library")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Choose lessons to place at the end of \(playlist.name).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            if libraryLessons.isEmpty {
                ContentUnavailableView(
                    "No lessons yet",
                    systemImage: "waveform",
                    description: Text("Import audio first, then add it to a playlist.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(libraryLessons) { lesson in
                    let alreadyAdded = items.contains { $0.lesson?.id == lesson.id }
                    Button {
                        toggle(lesson)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: pendingLessonIDs.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(
                                    pendingLessonIDs.contains(lesson.id)
                                        ? Color(red: 0.15, green: 0.39, blue: 0.32)
                                        : Color.secondary
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(alreadyAdded ? "Already in this playlist" : formatDuration(lesson.duration))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyAdded)
                    .opacity(alreadyAdded ? 0.5 : 1)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { showingAddExisting = false }
                Spacer()
                Button(addButtonTitle) { addSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.15, green: 0.39, blue: 0.32))
                    .disabled(pendingLessonIDs.isEmpty)
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(.background)
    }

    private var addButtonTitle: String {
        let count = pendingLessonIDs.count
        return count == 0 ? "Add lessons" : "Add \(count) lesson\(count == 1 ? "" : "s")"
    }

    private func toggle(_ lesson: Lesson) {
        if pendingLessonIDs.contains(lesson.id) {
            pendingLessonIDs.remove(lesson.id)
        } else {
            pendingLessonIDs.insert(lesson.id)
        }
    }

    private func addSelected() {
        let selected = libraryLessons.filter { pendingLessonIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        do {
            try repository.add(selected, to: playlist)
        } catch {
            alertMessage = "Could not add those lessons: \(error.localizedDescription)"
        }
        pendingLessonIDs = []
        showingAddExisting = false
    }

    // MARK: - Mutations

    private func move(_ item: PlaylistItem, to destination: Int) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        do {
            try repository.move(from: IndexSet(integer: index), to: destination, in: playlist)
        } catch {
            alertMessage = "Could not reorder the playlist: \(error.localizedDescription)"
        }
    }

    private func remove(_ selected: [PlaylistItem]) {
        guard !selected.isEmpty else { return }
        do {
            try repository.remove(selected, from: playlist)
        } catch {
            alertMessage = "Could not remove that lesson from the playlist: \(error.localizedDescription)"
        }
    }

    private func formatDuration(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        let hours = seconds / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// One row of the running order.
private struct PlaylistItemRow: View {
    let position: Int
    let lesson: Lesson
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(lesson.lastPlayedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Not played yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.39, blue: 0.32))
                    .accessibilityLabel("Now playing")
            }

            Text(formatDuration(lesson.duration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position). \(lesson.title), \(formatDuration(lesson.duration))")
    }

    private func formatDuration(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
