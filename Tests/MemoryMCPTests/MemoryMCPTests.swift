import Foundation
import MCP
import MemoryCore
import Testing

// MARK: - Integration Tests for MemoryMCP

/// These tests validate the MCP server integration by creating a server
/// and client connected via InMemoryTransport, registering tool handlers,
/// and calling tools through the MCP protocol.

// MARK: - Tool Definitions (mirror of MemoryMCP/Tools/ToolDefinitions.swift)
// We duplicate the tool list here because MemoryMCP is an executable target
// and cannot be imported into tests.

private func registerHandlers(server: Server, service: MemoryService) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: allTestTools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        try handleToolCall(params, service: service)
    }
}

/// Handle a tool call by routing to the appropriate handler.
private func handleToolCall(
    _ params: CallTool.Parameters,
    service: MemoryService
) throws -> CallTool.Result {
    switch params.name {
    case "remember":
        guard let content = params.arguments?["content"]?.stringValue, !content.isEmpty else {
            return .init(
                content: [.text(text: "{\"error\": \"content is required\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let category = params.arguments?["category"]?.stringValue ?? "general"
        let source = params.arguments?["source"]?.stringValue
        let metadata = params.arguments?["metadata"]?.stringValue
        let tags = params.arguments?["tags"]?.arrayValue?.compactMap { $0.stringValue }

        let memory = try service.createMemory(
            content: content,
            category: category,
            source: source,
            tags: tags,
            metadata: metadata
        )
        let json = "{\"id\": \"\(memory.id)\", \"message\": \"Memory stored successfully.\"}"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)

    case "recall":
        guard let query = params.arguments?["query"]?.stringValue else {
            return .init(
                content: [.text(text: "{\"error\": \"query is required\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let category = params.arguments?["category"]?.stringValue
        let tags = params.arguments?["tags"]?.arrayValue?.compactMap { $0.stringValue }
        let limit = params.arguments?["limit"]?.intValue ?? 10

        let memories = try service.searchMemories(
            query: query, category: category, tags: tags, limit: limit
        )
        let items = memories.map { "{\"id\": \"\($0.id)\", \"content\": \"\($0.content)\"}" }
        let json = "[\(items.joined(separator: ", "))]"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)

    case "forget":
        guard let memoryId = params.arguments?["memory_id"]?.stringValue else {
            return .init(
                content: [.text(text: "{\"error\": \"memory_id is required\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let deleted = try service.deleteMemory(id: memoryId)
        if deleted {
            return .init(
                content: [.text(text: "{\"message\": \"Memory deleted.\"}", annotations: nil, _meta: nil)],
                isError: false
            )
        } else {
            return .init(
                content: [.text(text: "{\"error\": \"not found\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }

    case "get_memory":
        guard let memoryId = params.arguments?["memory_id"]?.stringValue else {
            return .init(
                content: [.text(text: "{\"error\": \"memory_id is required\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        guard let memory = try service.getMemory(id: memoryId) else {
            return .init(
                content: [.text(text: "{\"error\": \"not found\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let json = "{\"id\": \"\(memory.id)\", \"content\": \"\(memory.content)\", \"category\": \"\(memory.category)\"}"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)

    case "list_categories":
        let categories = try service.listCategories()
        let json = "[\(categories.map { "\"\($0)\"" }.joined(separator: ", "))]"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)

    case "update_memory":
        guard let memoryId = params.arguments?["memory_id"]?.stringValue else {
            return .init(
                content: [.text(text: "{\"error\": \"memory_id is required\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let content = params.arguments?["content"]?.stringValue
        let category = params.arguments?["category"]?.stringValue
        let metadata = params.arguments?["metadata"]?.stringValue

        guard let updated = try service.updateMemory(
            id: memoryId, content: content, category: category, metadata: metadata
        ) else {
            return .init(
                content: [.text(text: "{\"error\": \"not found\"}", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let json = "{\"id\": \"\(updated.id)\", \"content\": \"\(updated.content)\"}"
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)

    default:
        return .init(
            content: [.text(text: "{\"error\": \"unknown tool\"}", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

/// Minimal tool definitions for testing.
private let allTestTools: [Tool] = [
    Tool(
        name: "remember",
        description: "Store a new memory.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "content": .object(["type": "string"]),
            ]),
            "required": .array([.string("content")]),
        ])
    ),
    Tool(
        name: "recall",
        description: "Search memories.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "query": .object(["type": "string"]),
            ]),
            "required": .array([.string("query")]),
        ])
    ),
    Tool(
        name: "forget",
        description: "Delete a memory.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object(["type": "string"]),
            ]),
            "required": .array([.string("memory_id")]),
        ])
    ),
    Tool(
        name: "get_memory",
        description: "Get a memory by ID.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object(["type": "string"]),
            ]),
            "required": .array([.string("memory_id")]),
        ])
    ),
    Tool(
        name: "list_categories",
        description: "List categories.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
        ])
    ),
    Tool(
        name: "update_memory",
        description: "Update a memory.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object(["type": "string"]),
            ]),
            "required": .array([.string("memory_id")]),
        ])
    ),
]

// MARK: - Helper

/// Create server + client pair connected via InMemoryTransport.
private func createTestPair(service: MemoryService) async throws -> (server: Server, client: Client) {
    let server = Server(
        name: "TestMemoryMCP",
        version: "0.1.0-test",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await registerHandlers(server: server, service: service)

    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)

    let client = Client(name: "TestClient", version: "1.0.0")
    try await client.connect(transport: clientTransport)

    return (server, client)
}

// MARK: - Tests

@Test func serverInitialization() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, _) = try await createTestPair(service: service)
    // If we get here, initialization succeeded
    await server.stop()
}

@Test func listToolsReturns6Tools() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    let (tools, _) = try await client.listTools()
    #expect(tools.count == 6)

    let toolNames = Set(tools.map(\.name))
    #expect(toolNames.contains("remember"))
    #expect(toolNames.contains("recall"))
    #expect(toolNames.contains("forget"))
    #expect(toolNames.contains("update_memory"))
    #expect(toolNames.contains("list_categories"))
    #expect(toolNames.contains("get_memory"))

    await server.stop()
}

@Test func rememberAndGetMemory() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Store a memory
    let (rememberContent, rememberError) = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("Swift is great for MCP servers"),
            "category": .string("fact"),
        ]
    )

    #expect(rememberError != true)
    #expect(!rememberContent.isEmpty)

    // Extract the ID from the response
    if case .text(let text, _, _) = rememberContent.first {
        #expect(text.contains("Memory stored successfully"))

        // Parse the ID
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let memoryId = json["id"] as? String
        {
            // Get the memory back
            let (getContent, getError) = try await client.callTool(
                name: "get_memory",
                arguments: ["memory_id": .string(memoryId)]
            )
            #expect(getError != true)
            if case .text(let getText, _, _) = getContent.first {
                #expect(getText.contains("Swift is great for MCP servers"))
                #expect(getText.contains("fact"))
            }
        }
    }

    await server.stop()
}

@Test func recallMemories() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Store some memories
    _ = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("The user prefers dark mode"),
            "category": .string("user-preference"),
        ]
    )
    _ = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("Project uses Swift 6"),
            "category": .string("project-insight"),
        ]
    )

    // Search for memories
    let (searchContent, searchError) = try await client.callTool(
        name: "recall",
        arguments: ["query": .string("dark mode")]
    )
    #expect(searchError != true)
    if case .text(let text, _, _) = searchContent.first {
        #expect(text.contains("dark mode"))
    }

    await server.stop()
}

@Test func forgetMemory() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Store a memory
    let (rememberContent, _) = try await client.callTool(
        name: "remember",
        arguments: ["content": .string("Temporary memory")]
    )

    // Extract ID
    var memoryId: String?
    if case .text(let text, _, _) = rememberContent.first,
       let data = text.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        memoryId = json["id"] as? String
    }

    guard let id = memoryId else {
        Issue.record("Failed to extract memory ID")
        await server.stop()
        return
    }

    // Delete it
    let (deleteContent, deleteError) = try await client.callTool(
        name: "forget",
        arguments: ["memory_id": .string(id)]
    )
    #expect(deleteError != true)
    if case .text(let text, _, _) = deleteContent.first {
        #expect(text.contains("deleted"))
    }

    // Verify it's gone
    let (getContent, getError) = try await client.callTool(
        name: "get_memory",
        arguments: ["memory_id": .string(id)]
    )
    #expect(getError == true)
    if case .text(let text, _, _) = getContent.first {
        #expect(text.contains("not found"))
    }

    await server.stop()
}

@Test func updateMemory() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Store a memory
    let (rememberContent, _) = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("Original content"),
            "category": .string("test"),
        ]
    )

    var memoryId: String?
    if case .text(let text, _, _) = rememberContent.first,
       let data = text.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        memoryId = json["id"] as? String
    }

    guard let id = memoryId else {
        Issue.record("Failed to extract memory ID")
        await server.stop()
        return
    }

    // Update content
    let (updateContent, updateError) = try await client.callTool(
        name: "update_memory",
        arguments: [
            "memory_id": .string(id),
            "content": .string("Updated content"),
        ]
    )
    #expect(updateError != true)
    if case .text(let text, _, _) = updateContent.first {
        #expect(text.contains("Updated content"))
    }

    await server.stop()
}

@Test func listCategories() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Store memories in different categories
    _ = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("A fact"),
            "category": .string("fact"),
        ]
    )
    _ = try await client.callTool(
        name: "remember",
        arguments: [
            "content": .string("A preference"),
            "category": .string("user-preference"),
        ]
    )

    let (catContent, catError) = try await client.callTool(
        name: "list_categories",
        arguments: [:]
    )
    #expect(catError != true)
    if case .text(let text, _, _) = catContent.first {
        #expect(text.contains("fact"))
        #expect(text.contains("user-preference"))
    }

    await server.stop()
}

@Test func rememberRequiresContent() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    // Call remember without content
    let (content, isError) = try await client.callTool(
        name: "remember",
        arguments: [:]
    )
    #expect(isError == true)
    if case .text(let text, _, _) = content.first {
        #expect(text.contains("error"))
    }

    await server.stop()
}

@Test func forgetNonExistentMemory() async throws {
    let db = try AppDatabase.createInMemory()
    let service = MemoryService(database: db)
    let (server, client) = try await createTestPair(service: service)

    let (content, isError) = try await client.callTool(
        name: "forget",
        arguments: ["memory_id": .string("non-existent-id")]
    )
    #expect(isError == true)
    if case .text(let text, _, _) = content.first {
        #expect(text.contains("not found"))
    }

    await server.stop()
}
