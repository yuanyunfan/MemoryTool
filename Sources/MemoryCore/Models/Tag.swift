import Foundation
import GRDB

/// A tag that can be attached to one or more memories.
public struct Tag: Codable, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - GRDB Protocols

extension Tag: FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "tag"

    /// Update auto-incremented id after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
