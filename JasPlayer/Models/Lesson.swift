import Foundation
import SwiftData

@Model
final class Lesson {
    @Attribute(.unique) var id: UUID
    var title: String
    var relativeAudioPath: String
    var audioType: String
    var duration: Double
    var createdAt: Date
    var lastPlayedAt: Date?
    var lastPosition: Double

    init(
        id: UUID = UUID(),
        title: String,
        relativeAudioPath: String,
        audioType: String,
        duration: Double,
        createdAt: Date = .now,
        lastPlayedAt: Date? = nil,
        lastPosition: Double = 0
    ) {
        self.id = id
        self.title = title
        self.relativeAudioPath = relativeAudioPath
        self.audioType = audioType
        self.duration = duration
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
        self.lastPosition = lastPosition
    }
}
