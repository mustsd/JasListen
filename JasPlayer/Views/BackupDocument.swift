import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Wraps a staged `.stillbackup` archive for `fileExporter`, and can also be
/// built outside the app for a backup opened from Finder or Files.
struct BackupDocument: FileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.stillBackup] }

    private let backupURL: URL
    private let openedContents: Data?

    /// Temporary archive staged for export, removed by the caller afterwards.
    var stagedURL: URL { backupURL }

    init(backupURL: URL) {
        self.backupURL = backupURL
        openedContents = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        openedContents = contents
        backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JasPlayerOpened-\(UUID().uuidString).stillbackup")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let openedContents { return FileWrapper(regularFileWithContents: openedContents) }
        let data = try Data(contentsOf: backupURL, options: .mappedIfSafe)
        return FileWrapper(regularFileWithContents: data)
    }
}
