import Foundation
import SwiftData

@MainActor
protocol LessonRepository {
    func allLessons() throws -> [Lesson]
    func lesson(id: UUID) throws -> Lesson?
    func save() throws
    func remove(_ lesson: Lesson) throws
}

@MainActor
struct SwiftDataLessonRepository: LessonRepository {
    let context: ModelContext

    func allLessons() throws -> [Lesson] {
        try context.fetch(FetchDescriptor<Lesson>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    func lesson(id: UUID) throws -> Lesson? {
        var descriptor = FetchDescriptor<Lesson>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func save() throws {
        try context.save()
    }

    func remove(_ lesson: Lesson) throws {
        context.delete(lesson)
        try context.save()
    }
}
