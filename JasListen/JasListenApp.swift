import SwiftData
import SwiftUI

@main
struct JasListenApp: App {
    private let container: ModelContainer?
    private let startupError: String?

    init() {
        do {
            container = try ModelContainer(for: Lesson.self, Playlist.self, PlaylistItem.self)
            startupError = nil
        } catch {
            container = nil
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                LibraryView().modelContainer(container)
            } else {
                ContentUnavailableView("Library unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text("JasListen could not open local lesson storage. Your audio files have not been deleted. \(startupError ?? "")"))
            }
        }
    }
}
