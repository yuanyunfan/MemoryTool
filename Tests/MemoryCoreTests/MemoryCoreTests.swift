import Testing
import Foundation
@testable import MemoryCore

// MARK: - Memory CRUD Tests

@Test func createMemory() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(
        content: "Remember to buy milk",
        category: "shopping",
        source: "test-session"
    )

    #expect(memory.content == "Remember to buy milk")
    #expect(memory.category == "shopping")
    #expect(memory.source == "test-session")
    #expect(!memory.id.isEmpty)
}

@Test func getMemory() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let created = try service.createMemory(content: "Test content", category: "test")
    let fetched = try service.getMemory(id: created.id)

    #expect(fetched != nil)
    #expect(fetched?.content == "Test content")
    #expect(fetched?.category == "test")
}

@Test func getMemoryNotFound() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let result = try service.getMemory(id: "non-existent-id")
    #expect(result == nil)
}

@Test func updateMemory() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let created = try service.createMemory(content: "Original", category: "test")
    let updated = try service.updateMemory(id: created.id, content: "Updated", category: "modified")

    #expect(updated != nil)
    #expect(updated?.content == "Updated")
    #expect(updated?.category == "modified")
    #expect(updated!.updatedAt >= created.updatedAt)
}

@Test func updateMemoryNotFound() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let result = try service.updateMemory(id: "non-existent", content: "test")
    #expect(result == nil)
}

@Test func deleteMemory() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let created = try service.createMemory(content: "To delete", category: "test")
    let deleted = try service.deleteMemory(id: created.id)
    #expect(deleted == true)

    let fetched = try service.getMemory(id: created.id)
    #expect(fetched == nil)
}

@Test func deleteMemoryNotFound() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let result = try service.deleteMemory(id: "non-existent")
    #expect(result == false)
}

// MARK: - FTS5 Search Tests

@Test func searchByKeyword() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "Swift programming is fun", category: "tech")
    try service.createMemory(content: "Python scripting basics", category: "tech")
    try service.createMemory(content: "Buy groceries today", category: "personal")

    let results = try service.searchMemories(query: "Swift", limit: 10)
    #expect(results.count == 1)
    #expect(results.first?.content.contains("Swift") == true)
}

@Test func searchWithCategoryFilter() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "Swift for iOS", category: "tech")
    try service.createMemory(content: "Swift the bird", category: "nature")

    let results = try service.searchMemories(query: "Swift", category: "tech", limit: 10)
    #expect(results.count == 1)
    #expect(results.first?.category == "tech")
}

@Test func searchEmptyQuery() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "Memory one", category: "test")
    try service.createMemory(content: "Memory two", category: "test")

    // Empty query should fall back to listing all
    let results = try service.searchMemories(query: "", limit: 10)
    #expect(results.count == 2)
}

@Test func searchWithTagFilter() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let m1 = try service.createMemory(content: "Learn Swift concurrency", category: "tech", tags: ["swift", "async"])
    try service.createMemory(content: "Learn Swift basics", category: "tech", tags: ["swift"])

    // Search with tag filter requiring "async"
    let results = try service.searchMemories(query: "Swift", tags: ["async"], limit: 10)
    #expect(results.count == 1)
    #expect(results.first?.id == m1.id)
}

// MARK: - List & Pagination Tests

@Test func listMemoriesWithPagination() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    for i in 1...5 {
        try service.createMemory(content: "Memory \(i)", category: "test")
    }

    let page1 = try service.listMemories(limit: 2, offset: 0)
    #expect(page1.count == 2)

    let page2 = try service.listMemories(limit: 2, offset: 2)
    #expect(page2.count == 2)

    let page3 = try service.listMemories(limit: 2, offset: 4)
    #expect(page3.count == 1)
}

@Test func listMemoriesByCategoryFilter() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "Tech memory", category: "tech")
    try service.createMemory(content: "Personal memory", category: "personal")

    let techOnly = try service.listMemories(category: "tech", limit: 10, offset: 0)
    #expect(techOnly.count == 1)
    #expect(techOnly.first?.category == "tech")
}

// MARK: - Tag Tests

@Test func addAndGetTags() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(content: "Tagged memory", category: "test")
    try service.addTags(to: memory.id, tags: ["swift", "grdb"])

    let tags = try service.getTagsForMemory(id: memory.id)
    #expect(tags.count == 2)

    let tagNames = tags.map(\.name).sorted()
    #expect(tagNames == ["grdb", "swift"])
}

@Test func createMemoryWithTags() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(
        content: "Memory with tags",
        category: "test",
        tags: ["alpha", "beta"]
    )

    let tags = try service.getTagsForMemory(id: memory.id)
    #expect(tags.count == 2)
}

@Test func removeTags() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(content: "Tagged", category: "test", tags: ["a", "b", "c"])
    try service.removeTags(from: memory.id, tags: ["b"])

    let remaining = try service.getTagsForMemory(id: memory.id)
    #expect(remaining.count == 2)
    let names = remaining.map(\.name).sorted()
    #expect(names == ["a", "c"])
}

@Test func duplicateTagsIgnored() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(content: "Test", category: "test", tags: ["dup"])
    // Adding the same tag again should not create duplicates
    try service.addTags(to: memory.id, tags: ["dup"])

    let tags = try service.getTagsForMemory(id: memory.id)
    #expect(tags.count == 1)
}

@Test func listAllTags() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "M1", category: "test", tags: ["swift", "ios"])
    try service.createMemory(content: "M2", category: "test", tags: ["swift", "macos"])

    let allTags = try service.listAllTags()
    #expect(allTags.count == 3) // swift, ios, macos
    let names = allTags.map(\.name)
    #expect(names == ["ios", "macos", "swift"]) // sorted alphabetically
}

// MARK: - Category Tests

@Test func listCategories() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    try service.createMemory(content: "A", category: "tech")
    try service.createMemory(content: "B", category: "personal")
    try service.createMemory(content: "C", category: "tech")

    let categories = try service.listCategories()
    #expect(categories.count == 2)
    #expect(categories.contains("tech"))
    #expect(categories.contains("personal"))
}

// MARK: - Stats Tests

@Test func totalMemoryCount() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    #expect(try service.totalMemoryCount() == 0)

    try service.createMemory(content: "One", category: "test")
    try service.createMemory(content: "Two", category: "test")

    #expect(try service.totalMemoryCount() == 2)
}

// MARK: - Edge Cases

@Test func memoryModelEquality() {
    let now = Date()
    let m1 = Memory(id: "abc", content: "test", category: "cat", createdAt: now, updatedAt: now)
    let m2 = Memory(id: "abc", content: "test", category: "cat", createdAt: now, updatedAt: now)
    #expect(m1 == m2)
}

@Test func memoryDefaultCategory() {
    let memory = Memory(content: "No category specified")
    #expect(memory.category == "general")
}

@Test func inMemoryDatabaseCompat() throws {
    // Test legacy inMemory() factory
    let db = try AppDatabase.inMemory()
    let service = MemoryService(database: db)
    let memory = try service.createMemory(content: "Legacy test", category: "test")
    let fetched = try service.getMemory(id: memory.id)
    #expect(fetched != nil)
}

@Test func limitCapping() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    for i in 1...5 {
        try service.createMemory(content: "Memory \(i)", category: "test")
    }

    // Requesting more than 100 should be capped to 100
    let results = try service.listMemories(limit: 200, offset: 0)
    #expect(results.count == 5) // only 5 exist, but limit was capped to 100
}

@Test func deleteMemoryAlsoRemovesTags() throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)

    let memory = try service.createMemory(content: "Will be deleted", category: "test", tags: ["temp"])
    let deleted = try service.deleteMemory(id: memory.id)
    #expect(deleted)

    // Tags on this memory should be gone (via CASCADE)
    let tags = try service.getTagsForMemory(id: memory.id)
    #expect(tags.isEmpty)
}
