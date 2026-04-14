import Foundation
import GRDB

/// Result of an import operation.
public struct ImportResult: Sendable, Equatable {
    public let imported: Int
    public let skipped: Int
    public let errors: [String]

    public init(imported: Int, skipped: Int, errors: [String]) {
        self.imported = imported
        self.skipped = skipped
        self.errors = errors
    }
}

/// Handles data import/export for MemoryTool.
///
/// Supports JSON (round-trippable) and Markdown (human-readable) formats.
public struct DataExporter: Sendable {

    // MARK: - JSON Export

    /// Exports all memories (including tags) as JSON `Data`.
    public static func exportToJSON(service: MemoryService) throws -> Data {
        let memories = try service.listMemories(category: nil, limit: 100, offset: 0)
        var allMemories = memories

        // Fetch all if more than initial page
        if memories.count == 100 {
            var offset = 100
            while true {
                let batch = try service.listMemories(category: nil, limit: 100, offset: offset)
                if batch.isEmpty { break }
                allMemories.append(contentsOf: batch)
                offset += batch.count
                if batch.count < 100 { break }
            }
        }

        // Build export entries with tags
        var entries: [[String: Any]] = []
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        for memory in allMemories {
            let tags = try service.getTagsForMemory(id: memory.id)
            let tagNames = tags.map(\.name)

            var entry: [String: Any] = [
                "id": memory.id,
                "content": memory.content,
                "category": memory.category,
                "tags": tagNames,
                "created_at": dateFormatter.string(from: memory.createdAt),
                "updated_at": dateFormatter.string(from: memory.updatedAt),
            ]

            if let source = memory.source {
                entry["source"] = source
            }
            if let metadata = memory.metadata {
                entry["metadata"] = metadata
            }

            entries.append(entry)
        }

        let exportDoc: [String: Any] = [
            "version": "1.0",
            "exported_at": dateFormatter.string(from: Date()),
            "memories": entries,
        ]

        return try JSONSerialization.data(
            withJSONObject: exportDoc,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: - JSON Import

    /// Imports memories from JSON data. Skips memories whose IDs already exist.
    public static func importFromJSON(data: Data, service: MemoryService) throws -> ImportResult {
        let json = try JSONSerialization.jsonObject(with: data)

        guard let root = json as? [String: Any],
              let memoriesArray = root["memories"] as? [[String: Any]]
        else {
            throw ExporterError.invalidFormat
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        var imported = 0
        var skipped = 0
        var errors: [String] = []

        for (index, entry) in memoriesArray.enumerated() {
            guard let id = entry["id"] as? String,
                  let content = entry["content"] as? String
            else {
                errors.append("Entry \(index): missing required fields (id, content)")
                continue
            }

            // Skip if already exists
            if let existing = try service.getMemory(id: id), !existing.id.isEmpty {
                skipped += 1
                continue
            }

            let category = entry["category"] as? String ?? "general"
            let source = entry["source"] as? String
            let metadata = entry["metadata"] as? String
            let tags = entry["tags"] as? [String]

            // Parse dates
            let createdAt: Date
            if let createdStr = entry["created_at"] as? String,
               let parsed = dateFormatter.date(from: createdStr) {
                createdAt = parsed
            } else {
                createdAt = Date()
            }

            let updatedAt: Date
            if let updatedStr = entry["updated_at"] as? String,
               let parsed = dateFormatter.date(from: updatedStr) {
                updatedAt = parsed
            } else {
                updatedAt = Date()
            }

            do {
                // Create memory with the original ID and timestamps
                let memory = Memory(
                    id: id,
                    content: content,
                    category: category,
                    source: source,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    metadata: metadata,
                    contentHash: MemoryService.generateContentHash(content)
                )

                try insertMemoryDirectly(memory, tags: tags, service: service)
                imported += 1
            } catch {
                errors.append("Entry \(index) (id=\(id)): \(error.localizedDescription)")
            }
        }

        return ImportResult(imported: imported, skipped: skipped, errors: errors)
    }

    // MARK: - Markdown Export

    /// Exports all memories as a human-readable Markdown string.
    public static func exportToMarkdown(service: MemoryService) throws -> String {
        let memories = try fetchAllMemories(service: service)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            "# MemoryTool Export",
            "",
            "Exported: \(dateFormatter.string(from: Date()))",
            "Total memories: \(memories.count)",
            "",
            "---",
            "",
        ]

        for memory in memories {
            let tags = try service.getTagsForMemory(id: memory.id)
            let tagNames = tags.map(\.name)

            lines.append("## \(memory.id)")
            lines.append("")
            lines.append("- **Category:** \(memory.category)")
            if let source = memory.source {
                lines.append("- **Source:** \(source)")
            }
            lines.append("- **Created:** \(dateFormatter.string(from: memory.createdAt))")
            lines.append("- **Updated:** \(dateFormatter.string(from: memory.updatedAt))")
            if !tagNames.isEmpty {
                lines.append("- **Tags:** \(tagNames.joined(separator: ", "))")
            }
            if let metadata = memory.metadata {
                lines.append("- **Metadata:** \(metadata)")
            }
            lines.append("")
            lines.append(memory.content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    /// Fetches all memories with pagination.
    private static func fetchAllMemories(service: MemoryService) throws -> [Memory] {
        var all: [Memory] = []
        var offset = 0
        let pageSize = 100

        while true {
            let batch = try service.listMemories(category: nil, limit: pageSize, offset: offset)
            all.append(contentsOf: batch)
            if batch.count < pageSize { break }
            offset += batch.count
        }
        return all
    }

    /// Inserts a memory (with a specific ID) using the service's underlying create.
    ///
    /// We call createMemory which generates a new ID, but we need to preserve
    /// the original ID. So we use a lower-level approach: create then skip
    /// (the service's createMemory always creates a new ID).
    /// Instead, we directly insert via service — we create with the exact Memory struct.
    private static func insertMemoryDirectly(
        _ memory: Memory,
        tags: [String]?,
        service: MemoryService
    ) throws {
        // Use createMemory, but note it generates a new UUID.
        // To preserve the original ID, we need to work around this.
        // We'll use the service's addTags separately.
        //
        // Actually, we'll use a two-step approach:
        // 1. Create with the service (new UUID) — WRONG, we need original ID.
        //
        // The clean approach: since MemoryService's createMemory always makes a new UUID,
        // and we need to import with the original ID, we create the Memory struct ourselves
        // and rely on GRDB's insert. But MemoryService doesn't expose raw DB access.
        //
        // Best approach for now: create via service, accept the new ID. This is the safest
        // way since we don't have direct DB access from outside MemoryService.
        //
        // BUT: the requirement says "skip already existing IDs", so we need the original ID.
        // Let's use a pragmatic workaround: create with service, which gives a new UUID,
        // but since we've already checked the original ID doesn't exist, duplicates won't happen.
        // The imported memory will have a NEW id though.
        //
        // Actually — re-reading MemoryService.createMemory: it creates a Memory(content:...)
        // which calls Memory.init with a new UUID. We can't override the ID.
        //
        // The correct fix: add a method to MemoryService that accepts a full Memory struct.
        // But the requirement says don't modify MemoryMCP. MemoryService is in MemoryCore
        // which we CAN modify, so let's add a small helper.

        // This is handled by the extension below.
        try service.importMemory(memory, tags: tags)
    }
}

// MARK: - MemoryService Import Extension

extension MemoryService {
    /// Imports a fully-formed Memory (preserving its original ID and timestamps).
    ///
    /// Used by `DataExporter.importFromJSON` to restore memories from a backup.
    public func importMemory(_ memory: Memory, tags: [String]?) throws {
        try db.writer().write { dbConn in
            try memory.insert(dbConn)

            if let tags, !tags.isEmpty {
                for tagName in tags {
                    let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    let tag: Tag
                    if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(dbConn) {
                        tag = existing
                    } else {
                        var newTag = Tag(name: trimmed)
                        try newTag.insert(dbConn)
                        tag = newTag
                    }

                    guard let tagId = tag.id else { continue }

                    let exists = try MemoryTag
                        .filter(Column("memory_id") == memory.id && Column("tag_id") == tagId)
                        .fetchOne(dbConn)

                    if exists == nil {
                        let join = MemoryTag(memoryId: memory.id, tagId: tagId)
                        try join.insert(dbConn)
                    }
                }
            }
        }
    }
}

// MARK: - Errors

public enum ExporterError: Error, LocalizedError {
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "Invalid export file format: expected a JSON object with a 'memories' array."
        }
    }
}
