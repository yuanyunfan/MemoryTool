import Foundation
import MCP

/// Definitions of all MCP tools exposed by MemoryMCP.
enum ToolDefinitions {

    static let allTools: [Tool] = [
        rememberTool,
        recallTool,
        forgetTool,
        updateMemoryTool,
        listCategoriesTool,
        getMemoryTool,
    ]

    // MARK: - remember

    static let rememberTool = Tool(
        name: "remember",
        description: "Store a new memory. The AI assistant calls this to persist important information across sessions.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "content": .object([
                    "type": "string",
                    "description": "The content to remember",
                ]),
                "category": .object([
                    "type": "string",
                    "description": "Category for organization (e.g., user-preference, project-insight, fact)",
                    "default": "general",
                ]),
                "tags": .object([
                    "type": "array",
                    "items": .object(["type": "string"]),
                    "description": "Tags for flexible categorization",
                ]),
                "source": .object([
                    "type": "string",
                    "description": "Source context (e.g., session ID, project name)",
                ]),
                "metadata": .object([
                    "type": "string",
                    "description": "JSON string with additional metadata",
                ]),
            ]),
            "required": .array([.string("content")]),
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    )

    // MARK: - recall

    static let recallTool = Tool(
        name: "recall",
        description: "Search memories by keyword. Uses full-text search to find relevant past memories.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Search keywords",
                ]),
                "category": .object([
                    "type": "string",
                    "description": "Filter by category",
                ]),
                "tags": .object([
                    "type": "array",
                    "items": .object(["type": "string"]),
                    "description": "Filter by tags",
                ]),
                "limit": .object([
                    "type": "integer",
                    "description": "Maximum results to return",
                    "default": .int(10),
                    "maximum": .int(50),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    // MARK: - forget

    static let forgetTool = Tool(
        name: "forget",
        description: "Delete a specific memory by ID.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object([
                    "type": "string",
                    "description": "The ID of the memory to delete",
                ]),
            ]),
            "required": .array([.string("memory_id")]),
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    // MARK: - update_memory

    static let updateMemoryTool = Tool(
        name: "update_memory",
        description: "Update an existing memory. Only provided fields will be changed.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object([
                    "type": "string",
                    "description": "The ID of the memory to update",
                ]),
                "content": .object([
                    "type": "string",
                    "description": "New content",
                ]),
                "category": .object([
                    "type": "string",
                    "description": "New category",
                ]),
                "tags": .object([
                    "type": "array",
                    "items": .object(["type": "string"]),
                    "description": "Replace all tags with these",
                ]),
                "metadata": .object([
                    "type": "string",
                    "description": "New metadata JSON",
                ]),
            ]),
            "required": .array([.string("memory_id")]),
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    // MARK: - list_categories

    static let listCategoriesTool = Tool(
        name: "list_categories",
        description: "List all memory categories with their counts.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
        ]),
        annotations: .init(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    // MARK: - get_memory

    static let getMemoryTool = Tool(
        name: "get_memory",
        description: "Retrieve a specific memory by its ID.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "memory_id": .object([
                    "type": "string",
                    "description": "The ID of the memory to retrieve",
                ]),
            ]),
            "required": .array([.string("memory_id")]),
        ]),
        annotations: .init(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )
}
