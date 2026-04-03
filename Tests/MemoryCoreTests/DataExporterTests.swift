import Testing
import Foundation
@testable import MemoryCore

// MARK: - JSON Export

@Test func exportEmptyDatabase() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let data = try DataExporter.exportToJSON(service: service)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["version"] as? String == "1.0")
    #expect(json["exported_at"] != nil)

    let memories = json["memories"] as! [[String: Any]]
    #expect(memories.isEmpty)
}

@Test func exportSingleMemory() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(
        content: "Test content",
        category: "tech",
        source: "unit-test",
        tags: ["swift", "grdb"]
    )

    let data = try DataExporter.exportToJSON(service: service)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let memories = json["memories"] as! [[String: Any]]

    #expect(memories.count == 1)

    let entry = memories[0]
    #expect(entry["content"] as? String == "Test content")
    #expect(entry["category"] as? String == "tech")
    #expect(entry["source"] as? String == "unit-test")

    let tags = entry["tags"] as? [String] ?? []
    #expect(Set(tags) == Set(["swift", "grdb"]))
}

@Test func exportMultipleMemories() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    for i in 1...3 {
        try service.createMemory(content: "Memory \(i)", category: "test")
    }

    let data = try DataExporter.exportToJSON(service: service)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let memories = json["memories"] as! [[String: Any]]

    #expect(memories.count == 3)
}

// MARK: - JSON Import

@Test func importIntoEmptyDatabase() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let importJSON: [String: Any] = [
        "version": "1.0",
        "exported_at": "2026-04-03T12:00:00Z",
        "memories": [
            [
                "id": "test-id-1",
                "content": "Imported memory",
                "category": "imported",
                "tags": ["tag1", "tag2"],
                "created_at": "2026-04-01T10:00:00Z",
                "updated_at": "2026-04-01T10:00:00Z",
            ],
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: importJSON)
    let result = try DataExporter.importFromJSON(data: data, service: service)

    #expect(result.imported == 1)
    #expect(result.skipped == 0)
    #expect(result.errors.isEmpty)

    // Verify memory was created with original ID
    let memory = try service.getMemory(id: "test-id-1")
    #expect(memory != nil)
    #expect(memory?.content == "Imported memory")
    #expect(memory?.category == "imported")

    // Verify tags
    let tags = try service.getTagsForMemory(id: "test-id-1")
    #expect(tags.count == 2)
}

@Test func importSkipsDuplicateIDs() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    // Create an existing memory
    let existing = try service.createMemory(content: "Existing", category: "test")

    let importJSON: [String: Any] = [
        "version": "1.0",
        "memories": [
            [
                "id": existing.id,  // same ID → should be skipped
                "content": "Duplicate",
                "category": "test",
            ],
            [
                "id": "new-id",
                "content": "New memory",
                "category": "test",
            ],
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: importJSON)
    let result = try DataExporter.importFromJSON(data: data, service: service)

    #expect(result.imported == 1)
    #expect(result.skipped == 1)

    // Original content should be unchanged
    let fetched = try service.getMemory(id: existing.id)
    #expect(fetched?.content == "Existing")
}

@Test func importHandlesMissingFields() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let importJSON: [String: Any] = [
        "version": "1.0",
        "memories": [
            [
                // Missing "id" and "content" → should report error
                "category": "test",
            ],
            [
                "id": "valid-id",
                "content": "Valid",
            ],
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: importJSON)
    let result = try DataExporter.importFromJSON(data: data, service: service)

    #expect(result.imported == 1)
    #expect(result.errors.count == 1)
    #expect(result.errors[0].contains("missing required fields"))
}

@Test func importInvalidFormatThrows() throws {
    let data = "not json".data(using: .utf8)!
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    #expect(throws: (any Error).self) {
        try DataExporter.importFromJSON(data: data, service: service)
    }
}

@Test func importMissingMemoriesKeyThrows() throws {
    let json: [String: Any] = ["version": "1.0"]
    let data = try JSONSerialization.data(withJSONObject: json)

    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    #expect(throws: ExporterError.self) {
        try DataExporter.importFromJSON(data: data, service: service)
    }
}

// MARK: - Round-Trip

@Test func exportImportRoundTrip() throws {
    // Create source database with data
    let sourceDB = try AppDatabase.createInMemory()
    let sourceService = MemoryService(database: sourceDB)

    let m1 = try sourceService.createMemory(
        content: "First memory",
        category: "tech",
        source: "test",
        tags: ["swift", "ios"],
        metadata: "{\"key\": \"value\"}"
    )
    let m2 = try sourceService.createMemory(
        content: "Second memory",
        category: "personal",
        tags: ["note"]
    )

    // Export
    let exportData = try DataExporter.exportToJSON(service: sourceService)

    // Import into a fresh database
    let targetDB = try AppDatabase.createInMemory()
    let targetService = MemoryService(database: targetDB)

    let result = try DataExporter.importFromJSON(data: exportData, service: targetService)

    #expect(result.imported == 2)
    #expect(result.skipped == 0)
    #expect(result.errors.isEmpty)

    // Verify content was preserved
    let fetched1 = try targetService.getMemory(id: m1.id)
    #expect(fetched1?.content == "First memory")
    #expect(fetched1?.category == "tech")
    #expect(fetched1?.source == "test")
    #expect(fetched1?.metadata == "{\"key\": \"value\"}")

    let tags1 = try targetService.getTagsForMemory(id: m1.id)
    #expect(Set(tags1.map(\.name)) == Set(["swift", "ios"]))

    let fetched2 = try targetService.getMemory(id: m2.id)
    #expect(fetched2?.content == "Second memory")
}

// MARK: - Markdown Export

@Test func exportMarkdownEmpty() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let md = try DataExporter.exportToMarkdown(service: service)
    #expect(md.contains("# MemoryTool Export"))
    #expect(md.contains("Total memories: 0"))
}

@Test func exportMarkdownWithContent() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(
        content: "Learn Swift concurrency",
        category: "tech",
        source: "session-1",
        tags: ["swift", "async"]
    )

    let md = try DataExporter.exportToMarkdown(service: service)
    #expect(md.contains("# MemoryTool Export"))
    #expect(md.contains("Total memories: 1"))
    #expect(md.contains("Learn Swift concurrency"))
    #expect(md.contains("**Category:** tech"))
    #expect(md.contains("**Source:** session-1"))
    #expect(md.contains("swift, async") || md.contains("async, swift"))
}

// MARK: - ImportResult

@Test func importResultEquality() {
    let a = ImportResult(imported: 1, skipped: 2, errors: ["err"])
    let b = ImportResult(imported: 1, skipped: 2, errors: ["err"])
    #expect(a == b)
}

// MARK: - Import with Default Values

@Test func importUsesDefaultCategoryWhenMissing() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let importJSON: [String: Any] = [
        "version": "1.0",
        "memories": [
            [
                "id": "no-cat-id",
                "content": "No category",
                // no "category" key
            ],
        ],
    ]

    let data = try JSONSerialization.data(withJSONObject: importJSON)
    let result = try DataExporter.importFromJSON(data: data, service: service)

    #expect(result.imported == 1)

    let memory = try service.getMemory(id: "no-cat-id")
    #expect(memory?.category == "general")
}
