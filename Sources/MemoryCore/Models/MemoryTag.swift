import Foundation
import GRDB

/// Join table for the many-to-many relationship between Memory and Tag.
public struct MemoryTag: Codable, Sendable, Equatable {
    public var memoryId: String
    public var tagId: Int64

    public init(memoryId: String, tagId: Int64) {
        self.memoryId = memoryId
        self.tagId = tagId
    }

    // MARK: - CodingKeys (snake_case column mapping)

    enum CodingKeys: String, CodingKey {
        case memoryId = "memory_id"
        case tagId = "tag_id"
    }
}

// MARK: - GRDB Protocols

extension MemoryTag: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "memory_tag"
}
