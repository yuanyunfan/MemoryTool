import Foundation
import GRDB

/// A single memory entry stored by the user or AI assistant.
public struct Memory: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var content: String
    public var category: String
    public var source: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: String?

    /// Full initializer with all fields.
    public init(
        id: String = UUID().uuidString,
        content: String,
        category: String = "general",
        source: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: String? = nil
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    // MARK: - CodingKeys (snake_case column mapping)

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case category
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case metadata
    }
}

// MARK: - GRDB Protocols

extension Memory: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "memory"
}
